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

            ChannelLogView(
                messages: viewModel.messages,
                toolRequestIDs: viewModel.renderedToolRequestIDs,
                persistedHistoryCount: viewModel.persistedHistoryCount,
                hasRestoredHistory: viewModel.hasRestoredHistory,
                onRestoreHistory: { viewModel.restoreHistory() },
                onExportTaskPDF: { taskID, title, result, timestamp in
                    Task {
                        await viewModel.exportTaskCompletedBannerPDF(
                            taskID: taskID,
                            fallbackTitle: title,
                            fallbackResult: result,
                            fallbackTimestamp: timestamp
                        )
                    }
                },
                onOpenMCPSettings: {
                    shared.settingsSelectedTab = .mcp
                    openSettings()
                },
                displayPrefs: cachedDisplayPrefs,
                selectedImageAttachment: $selectedImageAttachment
            )
            .equatable()
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
