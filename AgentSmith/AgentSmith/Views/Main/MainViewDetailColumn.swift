import SwiftUI
import UniformTypeIdentifiers
import AgentSmithKit

/// Right-hand detail column of `MainView`: abort/review banners, channel log, divider,
/// user input. Drop-target tinting and the image lightbox are layered as overlays.
struct MainViewDetailColumn: View {
    @Bindable var viewModel: AppViewModel
    let shared: SharedAppState
    @Environment(\.openSettings) private var openSettings
    @Binding var isDropTargeted: Bool
    @Binding var selectedImageAttachment: Attachment?
    @FocusState.Binding var isLightboxFocused: Bool
    let onAbortReset: () -> Void
    let onDrop: ([NSItemProvider]) -> Bool
    
    /// Cached display preferences to avoid creating a new TimestampPreferences instance on every body pass.
    /// Updated via .onChange when any of the underlying shared preferences change.
    @State private var cachedDisplayPrefs = TimestampPreferences.default

    /// PDF-export action for a "Task Completed" banner, shared by both transcript panes.
    private var exportTaskPDFAction: (UUID, String, String?, Date) -> Void {
        { taskID, title, result, timestamp in
            Task {
                await viewModel.exportTaskCompletedBannerPDF(
                    taskID: taskID, fallbackTitle: title, fallbackResult: result, fallbackTimestamp: timestamp)
            }
        }
    }

    /// Opens Settings → MCP Servers, shared by both transcript panes.
    private var openMCPSettingsAction: () -> Void {
        {
            shared.settingsSelectedTab = .mcp
            openSettings()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if shared.taskOverlayVisible {
                TaskOverlayBar(viewModel: viewModel, shared: shared)
            }

            if viewModel.isAborted {
                AbortBanner(
                    reason: viewModel.abortReason,
                    onReset: onAbortReset
                )
            }

            if let reviewTask = viewModel.taskAwaitingReview {
                ReviewBanner(taskTitle: reviewTask.title, isHelpRequest: reviewTask.status == .awaitingHelp)
            }

            VSplitView {
                // Top: the selected task's transcript (or a "Select a task" prompt).
                TaskTranscriptTopPane(
                    viewModel: viewModel,
                    displayPrefs: cachedDisplayPrefs,
                    onExportTaskPDF: exportTaskPDFAction,
                    onOpenMCPSettings: openMCPSettingsAction,
                    selectedImageAttachment: $selectedImageAttachment
                )
                .frame(minHeight: 120, idealHeight: 240)

                // Bottom: the full session transcript, filtered by the user's per-session config
                // (its own provider — the inspector still reads the unfiltered firehose).
                BottomTranscriptPane(
                    viewModel: viewModel,
                    displayPrefs: cachedDisplayPrefs,
                    onExportTaskPDF: exportTaskPDFAction,
                    onOpenMCPSettings: openMCPSettingsAction,
                    selectedImageAttachment: $selectedImageAttachment
                )
                .frame(minHeight: 200)
            }
            // Update cached display preferences when any of the underlying shared preferences change.
            // This avoids creating a new TimestampPreferences instance on every body pass.
            .onChange(of: shared.showTimestampsOnTaskBanners) { _, newValue in
                DispatchQueue.main.async {
                    cachedDisplayPrefs.taskBanners = newValue
                }
            }
            .onChange(of: shared.showTimestampsOnToolCalls) { _, newValue in
                DispatchQueue.main.async {
                    cachedDisplayPrefs.toolCalls = newValue
                }
            }
            .onChange(of: shared.showTimestampsOnMessaging) { _, newValue in
                DispatchQueue.main.async {
                    cachedDisplayPrefs.messaging = newValue
                }
            }
            .onChange(of: shared.showTimestampsOnSystemMessages) { _, newValue in
                DispatchQueue.main.async {
                    cachedDisplayPrefs.systemMessages = newValue
                }
            }
            .onChange(of: shared.showElapsedTimeOnToolCalls) { _, newValue in
                DispatchQueue.main.async {
                    cachedDisplayPrefs.elapsedTimeOnToolCalls = newValue
                }
            }
            .onChange(of: shared.showRestartChrome) { _, newValue in
                DispatchQueue.main.async {
                    cachedDisplayPrefs.showRestartChrome = newValue
                }
            }
            // Initialize cached preferences on first appearance.
            .task {
                cachedDisplayPrefs = TimestampPreferences(
                    taskBanners: shared.showTimestampsOnTaskBanners,
                    toolCalls: shared.showTimestampsOnToolCalls,
                    messaging: shared.showTimestampsOnMessaging,
                    systemMessages: shared.showTimestampsOnSystemMessages,
                    elapsedTimeOnToolCalls: shared.showElapsedTimeOnToolCalls,
                    showRestartChrome: shared.showRestartChrome
                )
            }

            Divider()

            UserInputView(
                text: $viewModel.inputText,
                pendingAttachments: viewModel.pendingAttachments,
                isRunning: viewModel.isRunning,
                onSend: {
                    Task { await viewModel.sendMessage() }
                },
                onAttach: { urls in
                    viewModel.addAttachments(from: urls)
                },
                onRemoveAttachment: { id in
                    viewModel.removePendingAttachment(id: id)
                },
                onHistoryUp: {
                    viewModel.navigateHistory(.up)
                },
                onHistoryDown: {
                    viewModel.navigateHistory(.down)
                },
                onPaste: {
                    viewModel.pasteFromClipboard()
                }
            )
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted, perform: onDrop)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.blue, lineWidth: 3)
                    .background(AppColors.dropTargetTint)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if let attachment = selectedImageAttachment {
                ImageLightbox(attachment: attachment, onDismiss: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedImageAttachment = nil
                    }
                })
                .focusable()
                .focusEffectDisabled()
                .focused($isLightboxFocused)
                .onAppear {
                    // Project rule: defer @FocusState mutations out of lifecycle closures.
                    DispatchQueue.main.async { isLightboxFocused = true }
                }
                .onDisappear {
                    DispatchQueue.main.async { isLightboxFocused = false }
                }
                .onKeyPress(.escape) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedImageAttachment = nil
                    }
                    return .handled
                }
            }
        }
    }
}

/// The bottom transcript pane: a filter-config header strip over the full session transcript, rendered
/// from `bottomTranscriptProvider` (the config-filtered view). Kept separate from the inspector's
/// firehose so narrowing this pane never hides messages from the role buckets.
private struct BottomTranscriptPane: View {
    @Bindable var viewModel: AppViewModel
    let displayPrefs: TimestampPreferences
    let onExportTaskPDF: (UUID, String, String?, Date) -> Void
    let onOpenMCPSettings: () -> Void
    @Binding var selectedImageAttachment: Attachment?

    var body: some View {
        VStack(spacing: 0) {
            TranscriptFilterBar(config: $viewModel.transcriptViewConfig)
            ChannelLogView(
                messages: viewModel.bottomTranscriptProvider.messages,
                toolRequestIDs: viewModel.bottomTranscriptProvider.toolRequestIDs,
                persistedHistoryCount: viewModel.persistedHistoryCount,
                hasRestoredHistory: viewModel.hasRestoredHistory,
                onRestoreHistory: { viewModel.restoreHistory() },
                onExportTaskPDF: onExportTaskPDF,
                onOpenMCPSettings: onOpenMCPSettings,
                displayPrefs: displayPrefs,
                selectedImageAttachment: $selectedImageAttachment
            )
            .equatable()
        }
    }
}

/// The top transcript pane: the selected task's transcript (from `topTranscriptProvider`, filtered to
/// `.task(selectedTaskID)` off-main), or a "Select a task" prompt when nothing is selected. Reuses the
/// same `ChannelLogView`; the task-scoped pane suppresses the full-log "Restore" affordance.
private struct TaskTranscriptTopPane: View {
    let viewModel: AppViewModel
    let displayPrefs: TimestampPreferences
    let onExportTaskPDF: (UUID, String, String?, Date) -> Void
    let onOpenMCPSettings: () -> Void
    @Binding var selectedImageAttachment: Attachment?

    /// The selected row resolved to a task/template (nil = nothing selected). A TEMPLATE with no run
    /// drilled in shows its run history; everything else shows a transcript.
    private var selected: AgentTask? {
        viewModel.selectedTaskID.flatMap { viewModel.anyTask(id: $0) }
    }

    var body: some View {
        Group {
            if let selected {
                if selected.isTemplate && viewModel.selectedTemplateRunID == nil {
                    TemplateRunHistoryPane(template: selected, viewModel: viewModel)
                } else {
                    transcript(showBackToRuns: selected.isTemplate)
                }
            } else {
                ContentUnavailableView(
                    "Select a task",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Click a task in the sidebar to see its transcript here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func transcript(showBackToRuns: Bool) -> some View {
        VStack(spacing: 0) {
            if showBackToRuns {
                DrilledRunHeader { viewModel.selectedTemplateRunID = nil }
                Divider()
            }
            ChannelLogView(
                messages: viewModel.topTranscriptProvider.messages,
                toolRequestIDs: viewModel.topTranscriptProvider.toolRequestIDs,
                persistedHistoryCount: 0,      // task-scoped pane: no full-log "Restore" affordance
                hasRestoredHistory: true,
                onRestoreHistory: {},
                onExportTaskPDF: onExportTaskPDF,
                onOpenMCPSettings: onOpenMCPSettings,
                displayPrefs: displayPrefs,
                selectedImageAttachment: $selectedImageAttachment
            )
            .equatable()
        }
    }
}

/// The top pane's run-history mode: a template's runs (its instances, newest first), each drilling into
/// that run's transcript. Runs come from `childTasks` (this session's active + the global archived),
/// so a run whose origin session is closed shows in the list; its transcript needs closed-session
/// vending (a TODO) to render.
private struct TemplateRunHistoryPane: View {
    let template: AgentTask
    let viewModel: AppViewModel

    var body: some View {
        let runs = viewModel.childTasks(of: template.id)
            .sorted { ($0.startedAt ?? $0.createdAt) > ($1.startedAt ?? $1.createdAt) }
        VStack(alignment: .leading, spacing: 0) {
            TemplateRunHistoryHeader(title: template.title, runCount: runs.count)
            Divider()
            TemplateRunList(runs: runs) { viewModel.selectedTemplateRunID = $0 }
        }
    }
}

private struct TemplateRunList: View {
    let runs: [AgentTask]
    let onSelect: (UUID) -> Void

    var body: some View {
        if runs.isEmpty {
            ContentUnavailableView(
                "No runs yet",
                systemImage: "clock.arrow.circlepath",
                description: Text("This template hasn't been run. Use its Run action to start one.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(runs, id: \.id) { run in
                        TemplateRunRow(run: run) { onSelect(run.id) }
                        Divider()
                    }
                }
            }
        }
    }
}

private struct TemplateRunHistoryHeader: View {
    let title: String
    let runCount: Int
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
            Text("Run History")
                .font(.headline)
            Text("· \(title)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Text("\(runCount) run\(runCount == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct TemplateRunRow: View {
    let run: AgentTask
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.title)
                        .font(.callout)
                        .lineLimit(1)
                    Text((run.startedAt ?? run.createdAt).formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
    }

    private var statusSymbol: String {
        switch run.status {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .running, .starting, .validating: return "play.circle.fill"
        case .paused, .interrupted, .awaitingReview, .awaitingHelp: return "pause.circle.fill"
        default: return "circle"
        }
    }

    private var statusColor: Color {
        switch run.status {
        case .completed: return .green
        case .failed: return .red
        case .running, .starting, .validating: return .blue
        default: return .secondary
        }
    }
}

private struct DrilledRunHeader: View {
    let onBack: () -> Void
    var body: some View {
        HStack {
            Button(action: onBack) {
                Label("Run History", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}
