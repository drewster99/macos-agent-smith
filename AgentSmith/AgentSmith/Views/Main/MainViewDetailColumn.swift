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

    var body: some View {
        if viewModel.selectedTaskID == nil {
            ContentUnavailableView(
                "Select a task",
                systemImage: "list.bullet.rectangle",
                description: Text("Click a task in the sidebar to see its transcript here.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
