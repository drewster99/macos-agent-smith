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
                // An explicit contract that this pane fills its column, NOT the fix — measured, the
                // pane is already full width because its header carries a Spacer, and VSplitView is
                // already greedy on both axes. The actual fix is the greedy frame inside
                // ChannelLogView: a vertical ScrollView otherwise reports its CONTENT's width
                // (measured: an 11pt ribbon at a 300pt proposal).
                .frame(maxWidth: .infinity)
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
                .frame(maxWidth: .infinity)
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
                // This pane's OWN provider, not the view model's forwards — those read the
                // primary (inspector) provider, and `hasRestoredHistory` is now per-subscriber.
                // Clearing the primary made it report "not restored", which put a "Restore full
                // history" button above a bottom pane whose content had not changed at all.
                persistedHistoryCount: viewModel.bottomTranscriptProvider.persistedHistoryCount,
                hasRestoredHistory: viewModel.bottomTranscriptProvider.hasRestoredHistory,
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

    /// The task whose transcript the pane shows: the selection itself, or — for a template with a run
    /// drilled in — that run. Its `sessionID` decides live-vs-cross-session below.
    private var effectiveTask: AgentTask? {
        guard let selected else { return nil }
        if selected.isTemplate {
            return viewModel.selectedTemplateRunID.flatMap { viewModel.anyTask(id: $0) }
        }
        return selected
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
            }
        }
        // On the GROUP, so all three branches fill the pane identically. Only the
        // ContentUnavailableView branch was greedy, so selecting a task swapped a filling view for
        // one sized to its content — the transcript's viewport ended above the pane's bottom edge
        // and the leftover strip rendered as a blank band that content clipped against, at a height
        // that did not move when scrolled.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func transcript(showBackToRuns: Bool) -> some View {
        let effective = effectiveTask
        // Resident in THIS session's live store → its messages are (or are becoming) current here, so
        // the live streaming provider is right — even for a task restored from another origin session
        // and re-running in this window. A finished drilled run is the exception: it's resident but its
        // messages have been trimmed from the bounded resident tail, so it must be read from the log.
        let residentHere = effective.map { e in viewModel.tasks.contains { $0.id == e.id } } ?? false
        let finishedDrilledRun = showBackToRuns && (effective?.status.isInProgress == false)
        VStack(spacing: 0) {
            if showBackToRuns {
                DrilledRunHeader { viewModel.selectedTemplateRunID = nil }
                Divider()
            }
            // Names the TASK, in the sidebar's chip and the transcript's own orange — the two
            // transcripts are visually identical otherwise, so this is what distinguishes them.
            TaskTranscriptHeader(task: effective)
            // Vend a read-only transcript from the origin session's log when the live provider can't be
            // trusted to have it: a task NOT resident in this session (archived/deleted or cross-session
            // and not restored), or a finished drilled run (trimmed from the tail). Otherwise the live
            // streaming provider — a resident, still-running task, including a live drilled run.
            if let effective, let origin = effective.sessionID, !residentHere || finishedDrilledRun {
                CrossSessionTranscriptView(
                    originSessionID: origin,
                    taskID: effective.id,
                    viewModel: viewModel,
                    displayPrefs: displayPrefs,
                    onExportTaskPDF: onExportTaskPDF,
                    onOpenMCPSettings: onOpenMCPSettings,
                    selectedImageAttachment: $selectedImageAttachment
                )
            } else {
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
}

/// A read-only, file-backed transcript for a task whose ORIGIN session isn't this window's — loaded
/// once from that session's channel log (no streaming updates). The file-backed counterpart to the
/// live `topTranscriptProvider`.
private struct CrossSessionTranscriptView: View {
    let originSessionID: UUID
    let taskID: UUID
    let viewModel: AppViewModel
    let displayPrefs: TimestampPreferences
    let onExportTaskPDF: (UUID, String, String?, Date) -> Void
    let onOpenMCPSettings: () -> Void
    @Binding var selectedImageAttachment: Attachment?

    /// The loaded transcript, TAGGED with the task it belongs to. Gating both the assignment (below) and
    /// the render (here) on `taskID` makes a superseded load structurally unable to display under the
    /// current selection — a slow load for task A can't paint over task B once B is selected.
    @State private var loaded: LoadedCrossSessionTranscript?

    var body: some View {
        Group {
            if let loaded, loaded.taskID == taskID {
                CrossSessionTranscriptOutcomeView(
                    outcome: loaded.outcome,
                    displayPrefs: displayPrefs,
                    onExportTaskPDF: onExportTaskPDF,
                    onOpenMCPSettings: onOpenMCPSettings,
                    selectedImageAttachment: $selectedImageAttachment
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: taskID) {
            loaded = nil
            let result = await viewModel.loadCrossSessionTaskTranscript(
                originSessionID: originSessionID, taskID: taskID)
            // Don't let a superseded (cancelled) load assign at all — the render guard above also rejects
            // a mismatched taskID, but not assigning keeps a slow, stale load from clobbering a newer one.
            guard !Task.isCancelled else { return }
            loaded = LoadedCrossSessionTranscript(
                taskID: taskID,
                outcome: result.map { .loaded(messages: $0.messages, toolRequestIDs: $0.toolRequestIDs) } ?? .failed)
        }
    }
}

/// A file-backed cross-session transcript load, tagged with the task it is for so a stale load can't
/// render, and carrying a `.failed` case so a read error isn't shown as an empty transcript.
private struct LoadedCrossSessionTranscript {
    let taskID: UUID
    let outcome: Outcome

    enum Outcome {
        case loaded(messages: [ChannelMessage], toolRequestIDs: Set<String>)
        case failed
    }
}

/// Renders a completed cross-session load: the transcript, or a "couldn't read" state. A `View` struct
/// (not a `-> some View` helper) per the project's SwiftUI rules.
private struct CrossSessionTranscriptOutcomeView: View {
    let outcome: LoadedCrossSessionTranscript.Outcome
    let displayPrefs: TimestampPreferences
    let onExportTaskPDF: (UUID, String, String?, Date) -> Void
    let onOpenMCPSettings: () -> Void
    @Binding var selectedImageAttachment: Attachment?

    var body: some View {
        switch outcome {
        case .loaded(let messages, let toolRequestIDs):
            ChannelLogView(
                messages: messages,
                toolRequestIDs: toolRequestIDs,
                persistedHistoryCount: 0,
                hasRestoredHistory: true,
                onRestoreHistory: {},
                onExportTaskPDF: onExportTaskPDF,
                onOpenMCPSettings: onOpenMCPSettings,
                displayPrefs: displayPrefs,
                selectedImageAttachment: $selectedImageAttachment
            )
            .equatable()
        case .failed:
            ContentUnavailableView(
                "Transcript unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text("This task's transcript could not be read from its session log."))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
