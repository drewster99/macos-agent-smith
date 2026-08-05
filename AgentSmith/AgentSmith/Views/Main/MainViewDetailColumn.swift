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
                // maxHeight on the SPLIT AXIS too. Without it the child sizes to its content and
                // the split has no reason to stretch it: measured at 172pt of content sitting in a
                // 225pt allocation, with the remaining 53pt showing the bare VSplitView through —
                // an `element_at` probe there hit the split group itself, so neither child was
                // drawn in it. That strip is the blank band, and it is why the pane's own header
                // ended up above the visible area.
                //
                // Same rule as ModelMetadataInspectorWindow's split, which gives its flexible child
                // `maxWidth: .infinity` on ITS split axis for the same reason. `idealHeight` still
                // sets where the divider rests before the user drags it.
                .frame(minHeight: 120, idealHeight: 240, maxHeight: .infinity)

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
                .frame(minHeight: 200, maxHeight: .infinity)
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
        TemplateRunList(template: template, runs: runs, viewModel: viewModel) {
            viewModel.selectedTemplateRunID = $0
        }
    }
}

private struct TemplateRunList: View {
    let template: AgentTask
    let runs: [AgentTask]
    let viewModel: AppViewModel
    let onSelect: (UUID) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                TemplateOverviewHeader(template: template, runs: runs, viewModel: viewModel)
                Divider()
                RunHistoryLabel(runCount: runs.count)
                if runs.isEmpty {
                    Text("This template hasn't been run. Use its Run action to start one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                } else {
                    ForEach(runs, id: \.id) { run in
                        TemplateRunRow(run: run, viewModel: viewModel) { onSelect(run.id) }
                            // Indented under the Run History label, so the header reads as being
                            // ABOUT the list rather than the first item of it.
                            .padding(.leading, 12)
                        Divider().padding(.leading, 12)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// What the template IS, above the list of what it did: name, when it was created, and the totals
/// across every run.
///
/// The created date used to sit in the sidebar's template row with no label, where it read as "last
/// run" and wasn't. Stated here, next to the totals it belongs with, it answers the question it was
/// always trying to answer.
private struct TemplateOverviewHeader: View {
    let template: AgentTask
    let runs: [AgentTask]
    let viewModel: AppViewModel

    var body: some View {
        let summary = TaskFamilySummary(runs: runs, viewModel: viewModel)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.doc")
                    .foregroundStyle(.secondary)
                Text(template.title)
                    .font(.headline)
                    .lineLimit(2)
                Spacer()
            }
            Text("Created \(template.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let summary {
                HStack(spacing: 10) {
                    Text("\(summary.runCount) run\(summary.runCount == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                    // Same buckets the sidebar shows — one arithmetic, so the two can't disagree.
                    ForEach(summary.buckets) { bucket in
                        Text("\(bucket.count) \(bucket.label)")
                            .foregroundStyle(bucket.color)
                    }
                    Spacer()
                    Text(String(format: "$%.2f", summary.totalCost))
                        .foregroundStyle(.orange)
                        .monospacedDigit()
                    Text(formattedElapsed(summary.totalElapsed))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RunHistoryLabel: View {
    let runCount: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
            Text("Run History")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text("\(runCount) run\(runCount == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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


/// One run: the same facts the sidebar's run row shows, plus the two things you can only get here —
/// what it produced, and the files it produced them into.
private struct TemplateRunRow: View {
    let run: AgentTask
    let viewModel: AppViewModel
    let onSelect: () -> Void

    @State private var showsResult = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Button around the SUMMARY LINE only, not the whole row: the result disclosure and the
            // attachment chips are buttons themselves, and nesting them inside a row-wide button
            // makes the inner controls unreachable.
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    if let outcome = run.outcome {
                    TaskOutcomeChip(outcome: outcome)
                } else {
                    TaskStatusChip(status: run.status)
                }
                Text(run.title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if !run.resultAttachments.isEmpty {
                    Label("\(run.resultAttachments.count)", systemImage: "paperclip")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }
                if let cost = viewModel.cachedTaskCost(run.id), cost > 0 {
                    Text(String(format: "$%.2f", cost))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.orange)
                }
                Text(formattedElapsed(elapsed))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text((run.startedAt ?? run.createdAt).formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if resultText != nil || !run.resultAttachments.isEmpty {
                RunResultDisclosure(run: run, isExpanded: $showsResult,
                                    resultText: resultText, isFailure: isFailure,
                                    viewModel: viewModel)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contextMenu {
            Button("Open Details") {
                AgentSmithApp.showOrOpenTaskDetail(
                    target: TaskDetailTarget(sessionID: viewModel.session.id, taskID: run.id),
                    openWindow: openWindow)
            }
            Button("Open Transcript", action: onSelect)
        }
    }

    private var elapsed: TimeInterval {
        guard let started = run.startedAt else { return 0 }
        return (run.completedAt ?? Date()).timeIntervalSince(started)
    }

    /// Outcome-aware. A clean run has a result worth reading; a run that did NOT finish happily has
    /// reasons, and those are what you came to the row for — showing an empty result field there
    /// would answer the wrong question.
    private var resultText: String? {
        if isFailure {
            let rejections = (run.validation?.criterionRejections ?? []).map(\.rejectionText)
            if !rejections.isEmpty { return rejections.joined(separator: "\n\n") }
        }
        if let result = run.result, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return result
        }
        return nil
    }

    private var isFailure: Bool {
        run.status == .failed || run.outcome.map { TaskOutcomeBadge.color(for: $0) == .red } == true
    }
}

/// The expandable result block and its attachments.
private struct RunResultDisclosure: View {
    let run: AgentTask
    @Binding var isExpanded: Bool
    let resultText: String?
    let isFailure: Bool
    let viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let resultText {
                Text(isExpanded ? resultText : String(resultText.prefix(140)))
                    .font(.caption)
                    .foregroundStyle(isFailure ? AppColors.verdictRejected : .secondary)
                    .lineLimit(isExpanded ? nil : 2)
                    .textSelection(.enabled)
                if resultText.count > 140 {
                    Button(isExpanded ? "less" : "more") { isExpanded.toggle() }
                        .buttonStyle(.plain)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            if !run.resultAttachments.isEmpty {
                // QuickLook on click is the cheap look; ⌘-click reveals, for when you want the file
                // itself rather than a peek at it.
                FlowingAttachmentChips(attachments: run.resultAttachments, viewModel: viewModel)
            }
        }
        .padding(.leading, 2)
    }
}

private struct FlowingAttachmentChips: View {
    let attachments: [Attachment]
    let viewModel: AppViewModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(attachments) { attachment in
                Button {
                    open(attachment, reveal: NSEvent.modifierFlags.contains(.command))
                } label: {
                    Label(attachment.filename, systemImage: "paperclip")
                        .font(.caption2)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(AppColors.secondaryBackground))
                }
                .buttonStyle(.plain)
                .help("Click to preview · ⌘-click to reveal in Finder")
            }
        }
    }

    private func open(_ attachment: Attachment, reveal: Bool) {
        let url = viewModel.persistenceManager.attachmentURL(id: attachment.id,
                                                             filename: attachment.filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if reveal {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Compact duration, shared by the header totals and the rows.
private func formattedElapsed(_ interval: TimeInterval) -> String {
    let total = Int(interval.rounded())
    let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
    if hours > 0 { return "\(hours)h \(minutes)m" }
    if minutes > 0 { return "\(minutes)m \(seconds)s" }
    return "\(seconds)s"
}
