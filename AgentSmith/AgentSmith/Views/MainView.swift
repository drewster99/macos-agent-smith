import AppKit
import SwiftUI
import SwiftLLMKit
import AgentSmithKit
import UniformTypeIdentifiers
import os

nonisolated private let dropLogger = Logger(subsystem: "com.agentsmith", category: "Drop")
nonisolated private let stopLogger = Logger(subsystem: "com.agentsmith", category: "Stop")

/// The window's two columns.
private struct MainViewSplit: View {
    let viewModel: AppViewModel
    let shared: SharedAppState
    @Binding var isDropTargeted: Bool
    @Binding var selectedImageAttachment: Attachment?
    @FocusState.Binding var isLightboxFocused: Bool
    @Binding var sheets: MainViewSheetState
    let onOpenSettings: () -> Void
    let onAbortReset: () -> Void
    let onDrop: ([NSItemProvider]) -> Bool

    var body: some View {
        NavigationSplitView(sidebar: {
            MainViewSidebar(
                viewModel: viewModel,
                onCreateTask: { sheets.taskCreator = .creating() },
                onOpenSessionOrchestration: { sheets.showOrchestrationOverrides = true },
                onOpenGlobalOrchestration: {
                    shared.settingsSelectedTab = .orchestration
                    onOpenSettings()
                }
            )
        }, detail: {
            MainViewDetailColumn(
                viewModel: viewModel, shared: shared,
                isDropTargeted: $isDropTargeted,
                selectedImageAttachment: $selectedImageAttachment,
                isLightboxFocused: $isLightboxFocused,
                onAbortReset: onAbortReset, onDrop: onDrop
            )
        })
    }
}

/// What a `MainView` window is presenting over itself.
///
/// One value rather than five `@State` flags: the startup gate sequences between onboarding, the
/// welcome sheet and config validation, and that sequence is only legible when the states it moves
/// between sit together.
private struct MainViewSheetState {
    var showOnboarding = false
    var showWelcome = false
    var showValidation = false
    var showOrchestrationOverrides = false
    var taskCreator: TaskEditorPresentation?
}

/// Primary app view: sidebar with tasks, detail with channel log and input.
struct MainView: View {
    @Bindable var viewModel: AppViewModel
    @Bindable var sessionManager: SessionManager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    /// What this window is presenting over itself. One value rather than five independent flags:
    /// they are mutually exclusive in practice and the startup gate sequences between them, so
    /// keeping them together is what lets that sequencing be read in one place.
    @State private var sheets = MainViewSheetState()
    @State private var isDropTargeted = false
    /// The attachment currently shown in the full-screen image viewer.
    @State private var selectedImageAttachment: Attachment?
    @FocusState private var isLightboxFocused: Bool
    /// Window-level keyDown monitor that catches Escape regardless of which subview holds
    /// keyboard focus. Required because SwiftUI's `.onKeyPress(.escape)` only fires when
    /// the focus chain reaches the modifier — TextEditor, sidebar buttons, and lingering
    /// `@FocusState` references can all swallow Escape before it bubbles up.
    @State private var escapeKeyMonitor: Any?

    private var shared: SharedAppState { viewModel.shared }

    var body: some View {
        MainViewSplit(
            viewModel: viewModel, shared: shared,
            isDropTargeted: $isDropTargeted,
            selectedImageAttachment: $selectedImageAttachment,
            isLightboxFocused: $isLightboxFocused,
            sheets: $sheets,
            onOpenSettings: { openSettings() },
            onAbortReset: handleAbortReset,
            onDrop: handleDrop
        )
        // `.onKeyPress` is scoped to the view it is attached to, so it stays out here on the split
        // rather than moving into a child, which would narrow Control-L to that child's subtree.
        .onKeyPress(characters: .init(charactersIn: "l"), phases: .down) { keyPress in
            guard keyPress.modifiers == .control else { return .ignored }
            viewModel.clearLog()
            return .handled
        }
        .modifier(MainViewChrome(viewModel: viewModel, shared: shared,
                                 onStart: handleStart, onResetAndRestart: handleAbortReset,
                                 onOpenMemoryBrowser: { openWindow(id: "memory-browser") },
                                 onNewTask: { sheets.taskCreator = .creating() },
                                 onOpenOrchestrationOverrides: { sheets.showOrchestrationOverrides = true }))
        // Order is load-bearing: chrome, then the handlers that react to state, then the sheets
        // they raise. A `.sheet` ahead of an `.onChange` can stop the handler firing.
        .modifier(MainViewLifecycle(
            viewModel: viewModel, shared: shared,
            onEvaluateStartupGate: evaluateStartupGate,
            onCreateTask: { sheets.taskCreator = .creating() },
            onShowSessionOverrides: { sheets.showOrchestrationOverrides = true },
            onInstallEscapeMonitor: installEscapeMonitor,
            onRemoveEscapeMonitor: removeEscapeMonitor
        ))
        .modifier(MainViewSheets(viewModel: viewModel, shared: shared,
                                 sheets: $sheets, onOpenSettings: { openSettings() }))
    }

    /// Installs a window-local keyDown monitor for Escape so it stops the running task
    /// even when SwiftUI's focus chain has moved into a TextEditor or sidebar button. Each
    /// MainView (one per session/window) installs its own monitor and gates on
    /// `shared.focusedSessionID` so only the frontmost session reacts.
    private func installEscapeMonitor() {
        guard escapeKeyMonitor == nil else { return }
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 53 = Escape. Plain Escape only — leave Cmd/Opt/Shift/Ctrl+Esc alone.
            // Narrow the mask to the four real modifier keys; ignoring caps-lock/function/
            // numericPad bits so a Caps-Lock-on user still gets Escape-stops-task.
            let realModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
            guard event.keyCode == 53,
                  event.modifierFlags.intersection(realModifiers).isEmpty else {
                return event
            }
            // Only the frontmost window's MainView acts. Other sessions' monitors fire
            // for the same keystroke; they bail here.
            guard event.window?.isKeyWindow == true,
                  shared.focusedSessionID == viewModel.session.id else {
                return event
            }
            // Lightbox handles its own dismissal via its own onKeyPress(.escape).
            guard selectedImageAttachment == nil else { return event }
            guard viewModel.isRunning else {
                stopLogger.notice("UI.Escape pressed but viewModel.isRunning=false — ignored")
                return event
            }
            stopLogger.notice("UI.Escape pressed → pausing all running tasks")
            Task {
                stopLogger.notice("UI.Escape Task body running → calling pauseAllRunningTasks")
                await viewModel.pauseAllRunningTasks()
                stopLogger.notice("UI.Escape Task body returned from pauseAllRunningTasks")
            }
            return nil
        }
    }

    private func removeEscapeMonitor() {
        if let monitor = escapeKeyMonitor {
            NSEvent.removeMonitor(monitor)
            escapeKeyMonitor = nil
        }
    }

    /// Decides what a freshly-loaded session shows first: first-run onboarding, the nickname
    /// prompt (edge case), the configuration gate, or an auto-start. Runs once both the shared
    /// and per-session persisted state have loaded. `@State` mutations are deferred per the
    /// project rule against mutating state inside `.onChange`.
    private func evaluateStartupGate() {
        guard viewModel.hasLoadedPersistedState, shared.hasLoadedPersistedState else { return }
        if !shared.didCompleteOnboarding {
            DispatchQueue.main.async { sheets.showOnboarding = true }
        } else if shared.nickname.isEmpty {
            DispatchQueue.main.async { sheets.showWelcome = true }
        } else if !viewModel.allAgentConfigsValid {
            DispatchQueue.main.async { sheets.showValidation = true }
        } else if shared.autoStartEnabled && !viewModel.isRunning && !CapabilityEvalRunner.isRequested {
            // A capability-eval launch must not also spin up real agents: they'd make their own
            // LLM calls, spending money and interleaving with the probe's logs. Gated here rather
            // than by flipping `autoStartEnabled`, whose didSet would persist the change and
            // leave auto-start switched off for good.
            Task { await viewModel.start() }
        }
    }

    /// Starts the runtime if all agent configs are valid; otherwise routes to the
    /// configuration validation sheet. Wired into the AbortBanner reset, the toolbar's
    /// Reset & Restart, and the toolbar's Start button.
    private func handleStart() {
        if viewModel.allAgentConfigsValid {
            Task { await viewModel.start() }
        } else {
            sheets.showValidation = true
        }
    }

    /// Clears the abort flag and restarts (or surfaces validation if needed).
    private func handleAbortReset() {
        viewModel.resetAbort()
        handleStart()
    }

    /// Processes dropped items from a drag-and-drop operation.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false

        for provider in providers {
            // File URLs (covers any file type dragged from Finder)
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, error in
                    if let error {
                        dropLogger.error("failed to load file URL: \(error.localizedDescription, privacy: .public)")
                        return
                    }
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else {
                        dropLogger.error("could not decode file URL from dropped item")
                        return
                    }
                    Task { @MainActor in
                        viewModel.addAttachments(from: [url])
                    }
                }
            }
            // Raw image data (covers dragging images from browsers, etc.)
            else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                handled = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                    if let error {
                        dropLogger.error("failed to load image data: \(error.localizedDescription, privacy: .public)")
                        return
                    }
                    guard let data else {
                        dropLogger.error("image provider returned nil data")
                        return
                    }
                    // Convert to PNG for consistency
                    let pngData: Data
                    if let bitmap = NSBitmapImageRep(data: data),
                       let converted = bitmap.representation(using: .png, properties: [:]) {
                        pngData = converted
                    } else {
                        pngData = data
                    }
                    Task { @MainActor in
                        viewModel.addAttachment(
                            data: pngData,
                            filename: "Dropped Image \(AppViewModel.attachmentTimestamp()).png",
                            mimeType: "image/png"
                        )
                    }
                }
            }
        }
        return handled
    }
}

/// Banner displayed when an agent triggers an emergency abort.
struct AbortBanner: View {
    let reason: String
    let onReset: () -> Void

    /// Extracts the headline (e.g. "ABORT triggered by Smith") from the reason string.
    private var headline: String {
        // reason format: "ABORT triggered by <name>: <detail>"
        if let colonRange = reason.range(of: ": ") {
            return String(reason[reason.startIndex..<colonRange.lowerBound]).uppercased()
        }
        return "SYSTEM ABORT"
    }

    /// The detail portion after the headline.
    private var detail: String {
        if let colonRange = reason.range(of: ": ") {
            return String(reason[colonRange.upperBound...])
        }
        return reason
    }

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.9))
            }
            Spacer()
            Button("Reset & Restart", action: onReset)
                .buttonStyle(.bordered)
                .tint(.white)
        }
        .padding(10)
        .background(.red.gradient)
    }
}

/// Small banner shown when a task is awaiting Smith's review — or, when the task is a
/// `request_help` escalation, awaiting Smith's help instead.
struct ReviewBanner: View {
    let taskTitle: String
    var isHelpRequest: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isHelpRequest ? "lifepreserver.fill" : "eye.circle.fill")
                .foregroundStyle(.orange)
            Text(isHelpRequest ? "Needs help:" : "Awaiting review:")
                .font(.caption.bold())
                .foregroundStyle(.orange)
            Text(taskTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.08))
    }
}

/// First-launch sheet asking the user for their preferred name.
private struct WelcomeSheet: View {
    @Bindable var shared: SharedAppState
    let onDismiss: () -> Void
    @State private var nameInput = ""

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "hand.wave.fill")
                .font(AppFonts.welcomeIcon)
                .foregroundStyle(.blue)

            Text("Welcome to Agent Smith")
                .font(.title2.bold())

            Text("What should I call you?")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField("Your name or nickname", text: $nameInput)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 250)
                .onSubmit { save() }

            Button("Continue") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(nameInput.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(30)
        .frame(minWidth: 350)
    }

    private func save() {
        let trimmed = nameInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        shared.nickname = trimmed
        shared.persistNickname()
        onDismiss()
    }
}


/// The window's inspector, toolbar and title.
private struct MainViewChrome: ViewModifier {
    @Bindable var viewModel: AppViewModel
    let shared: SharedAppState
    let onStart: () -> Void
    let onResetAndRestart: () -> Void
    let onOpenMemoryBrowser: () -> Void
    let onNewTask: () -> Void
    let onOpenOrchestrationOverrides: () -> Void

    func body(content: Content) -> some View {
        content
            .inspector(isPresented: $viewModel.showInspector) {
                InspectorView(viewModel: viewModel)
            }
            .toolbar {
                MainViewToolbar(
                    viewModel: viewModel, shared: shared,
                    onStart: onStart, onResetAndRestart: onResetAndRestart,
                    onOpenMemoryBrowser: onOpenMemoryBrowser, onNewTask: onNewTask,
                    onOpenOrchestrationOverrides: onOpenOrchestrationOverrides
                )
            }
            .navigationTitle(viewModel.session.name)
    }
}

/// The window's reactions to state it does not own: the startup gate, the cross-window request
/// IDs other sessions raise, and the Escape monitor's lifetime.
private struct MainViewLifecycle: ViewModifier {
    let viewModel: AppViewModel
    let shared: SharedAppState
    let onEvaluateStartupGate: () -> Void
    let onCreateTask: () -> Void
    let onShowSessionOverrides: () -> Void
    let onInstallEscapeMonitor: () -> Void
    let onRemoveEscapeMonitor: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: viewModel.hasLoadedPersistedState) { _, _ in onEvaluateStartupGate() }
            .onChange(of: shared.hasLoadedPersistedState) { _, _ in onEvaluateStartupGate() }
            .onChange(of: shared.createTaskRequestID) { _, newValue in
                guard newValue == viewModel.session.id else { return }
                // Project rule: defer @State / @Observable mutations out of `.onChange`.
                DispatchQueue.main.async {
                    shared.createTaskRequestID = nil
                    onCreateTask()
                }
            }
            .onChange(of: shared.sessionOverridesRequestID) { _, newValue in
                guard newValue == viewModel.session.id else { return }
                DispatchQueue.main.async {
                    shared.sessionOverridesRequestID = nil
                    onShowSessionOverrides()
                }
            }
            // Project rule: defer @State mutations out of lifecycle closures.
            .onAppear { DispatchQueue.main.async { onInstallEscapeMonitor() } }
            .onDisappear { DispatchQueue.main.async { onRemoveEscapeMonitor() } }
    }
}

/// Everything this window presents over itself, in the order it can present them.
private struct MainViewSheets: ViewModifier {
    let viewModel: AppViewModel
    let shared: SharedAppState
    @Binding var sheets: MainViewSheetState
    let onOpenSettings: () -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $sheets.showOnboarding) {
                OnboardingView(
                    viewModel: viewModel, shared: shared,
                    onComplete: {
                        sheets.showOnboarding = false
                        Task { await viewModel.start() }
                    },
                    onManualSetup: {
                        sheets.showOnboarding = false
                        onOpenSettings()
                    }
                )
                // First-run setup must be finished or explicitly skipped ("Configure everything
                // manually") — not casually dismissed, which would leave the app unconfigured.
                .interactiveDismissDisabled()
            }
            .sheet(isPresented: $sheets.showWelcome, onDismiss: {
                if !viewModel.allAgentConfigsValid { sheets.showValidation = true }
            }) {
                WelcomeSheet(shared: shared, onDismiss: { sheets.showWelcome = false })
            }
            .sheet(isPresented: $sheets.showValidation) {
                ConfigValidationView(
                    viewModel: viewModel,
                    onStart: {
                        sheets.showValidation = false
                        Task { await viewModel.start() }
                    },
                    onDismiss: { sheets.showValidation = false }
                )
            }
            .sheet(item: $sheets.taskCreator) { presentation in
                TaskEditorSheet(mode: presentation.mode, viewModel: viewModel) {
                    sheets.taskCreator = nil
                }
            }
            .sheet(isPresented: $sheets.showOrchestrationOverrides) {
                SessionOrchestrationOverridesView(viewModel: viewModel) {
                    sheets.showOrchestrationOverrides = false
                }
            }
    }
}
