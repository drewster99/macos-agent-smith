import SwiftUI
import AppKit
import AgentSmithKit
import os

nonisolated private let stopLogger = Logger(subsystem: "com.agentsmith", category: "Stop")

@main
struct AgentSmithApp: App {
    @State private var shared: SharedAppState
    @State private var sessionManager: SessionManager
    @Environment(\.openWindow) private var openWindow

    init() {
        let sharedState = SharedAppState()
        _shared = State(initialValue: sharedState)
        _sessionManager = State(initialValue: SessionManager(shared: sharedState))
        // Enable native NSWindow tabbing so multiple session windows auto-tab (and can be
        // dragged out to detach).
        NSWindow.allowsAutomaticWindowTabbing = true
    }

    var body: some Scene {
        WindowGroup(id: "app-main") {
            SessionScene(shared: shared, sessionManager: sessionManager)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session") {
                    let focused = shared.focusedSessionID
                    Task {
                        let session = await sessionManager.createSession(templateSessionID: focused)
                        // Give the next SessionScene to appear a hint about which session to show.
                        pendingNewSessionIDs.append(session.id)
                        openWindow(id: "app-main")
                    }
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Rename Session\u{2026}") {
                    if let id = shared.focusedSessionID {
                        shared.renameSessionRequestID = id
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(shared.focusedSessionID == nil)
            }
            CommandMenu("Session") {
                // Every session shows up here. Clicking switches focus to its open window
                // (if any), or stashes the id and opens a fresh window so the next
                // `SessionScene.bootstrapIfNeeded` adopts it. Window-close is now a UI-only
                // operation — sessions are never deleted from this menu (or anywhere in the
                // app's current build). Per ROADMAP: deletion will return as an explicit
                // "Manage Sessions" sheet later, separate from window lifecycle.
                ForEach(sessionManager.sessions, id: \.id) { session in
                    Button(action: {
                        showOrOpenSession(id: session.id)
                    }, label: {
                        if session.id == shared.focusedSessionID {
                            Label(session.name, systemImage: "checkmark")
                        } else {
                            Text(session.name)
                        }
                    })
                }
                if sessionManager.sessions.isEmpty {
                    Text("No sessions").disabled(true)
                }
            }
            CommandGroup(after: .appInfo) {
                Button("Emergency Stop") {
                    stopLogger.notice("UI.menu EmergencyStop clicked → dispatching sessionManager.stopAll")
                    Task {
                        stopLogger.notice("UI.menu EmergencyStop Task body running")
                        await sessionManager.stopAll()
                        stopLogger.notice("UI.menu EmergencyStop Task body returned")
                    }
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(!sessionManager.isAnyRunning)
            }
            CommandGroup(after: .sidebar) {
                Button("Memory Browser") {
                    openWindow(id: "memory-browser")
                }
                .keyboardShortcut("m", modifiers: [.command, .option])

                Button("Spending Dashboard") {
                    openWindow(id: "spending-dashboard")
                }
                .keyboardShortcut("4", modifiers: .command)

                Button("Timers") {
                    if let id = shared.focusedSessionID {
                        openWindow(id: "timers", value: id)
                    } else if let first = sessionManager.sessions.first {
                        openWindow(id: "timers", value: first.id)
                    }
                }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(sessionManager.sessions.isEmpty)

                Divider()

                Toggle(
                    "Show Timer Activity in Transcript",
                    isOn: Bindable(shared).showTimerActivityInTranscript
                )
            }
        }

        WindowGroup("Agent Inspector", for: AgentInspectorTarget.self) { $target in
            if let target, let vm = sessionManager.viewModel(for: target.sessionID) {
                AgentInspectorWindow(viewModel: vm, role: target.role)
            } else {
                ContentUnavailableView(
                    "Agent Inspector Unavailable",
                    systemImage: "questionmark.circle",
                    description: Text("The session for this inspector is no longer open.")
                )
            }
        }
        .defaultSize(width: 800, height: 700)

        WindowGroup("Task Detail", for: TaskDetailTarget.self) { $target in
            if let target, let vm = sessionManager.viewModel(for: target.sessionID) {
                TaskDetailWindow(taskID: target.taskID, viewModel: vm, sessionManager: sessionManager)
                    .background(TaskDetailWindowTagger(target: target))
            } else {
                ContentUnavailableView(
                    "Task Not Found",
                    systemImage: "questionmark.circle",
                    description: Text("This task's session may have been closed.")
                )
            }
        }
        .defaultSize(width: 800, height: 700)

        Window("Memory Browser", id: "memory-browser") {
            MemoryEditorView(shared: shared)
        }
        .defaultSize(width: 900, height: 600)

        Window("Spending Dashboard", id: "spending-dashboard") {
            SpendingDashboardView(shared: shared)
        }
        .defaultSize(width: 900, height: 800)

        WindowGroup("Timers", id: "timers", for: UUID.self) { $sessionID in
            if let id = sessionID, let vm = sessionManager.viewModel(for: id) {
                TimersWindow(viewModel: vm)
            } else {
                ContentUnavailableView(
                    "Session Closed",
                    systemImage: "clock.badge.exclamationmark",
                    description: Text("Open a session and try again.")
                )
            }
        }
        .defaultSize(width: 720, height: 520)

        Settings {
            SettingsView(shared: shared, sessionManager: sessionManager)
        }
    }

    /// Brings an open window for `id` to the front if one exists, otherwise stashes the id
    /// for the next bootstrapping `SessionScene` and opens a new app-main window. Windows
    /// are tagged by `WindowKeyObserver` with a custom `NSUserInterfaceItemIdentifier`
    /// (`"agent-smith-session-<uuid>"`), namespaced to avoid colliding with SwiftUI's own
    /// auto-assigned identifiers.
    @MainActor
    private func showOrOpenSession(id: UUID) {
        let target = AgentSmithApp.windowIdentifier(for: id)
        for window in NSApp.windows where window.isVisible {
            if window.identifier?.rawValue == target {
                window.makeKeyAndOrderFront(nil)
                return
            }
        }
        pendingNewSessionIDs.append(id)
        openWindow(id: "app-main")
    }

    static func windowIdentifier(for sessionID: UUID) -> String {
        "agent-smith-session-\(sessionID.uuidString)"
    }

    /// Stable identifier for a task detail window. Stamped onto the NSWindow by
    /// `TaskDetailWindowTagger` so `showOrOpenTaskDetail` can find and front it
    /// even when SwiftUI's `openWindow(value:)` would otherwise spawn a new one
    /// or fail to raise a buried existing one.
    static func taskDetailWindowIdentifier(for target: TaskDetailTarget) -> String {
        "agent-smith-task-detail-\(target.sessionID.uuidString)-\(target.taskID.uuidString)"
    }

    /// Brings an existing task detail window for `target` to the front, or opens a
    /// new one if none exists. Mirrors `showOrOpenSession` for task detail windows.
    /// Handles minimized (Dock) and hidden windows so a buried detail window always
    /// surfaces when the user clicks its sidebar row.
    @MainActor
    static func showOrOpenTaskDetail(
        target: TaskDetailTarget,
        openWindow: OpenWindowAction
    ) {
        let id = taskDetailWindowIdentifier(for: target)
        for window in NSApp.windows where window.identifier?.rawValue == id {
            NSApp.activate(ignoringOtherApps: true)
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return
        }
        openWindow(value: target)
    }
}

/// Stamps the hosting NSWindow with a stable identifier derived from the task detail
/// target. Lets `AgentSmithApp.showOrOpenTaskDetail` find an existing window for the
/// same target via `NSApp.windows` and front it instead of opening a duplicate.
/// Mirrors the `WindowKeyObserver` pattern: the identifier is set in
/// `viewDidMoveToWindow` once the host window is actually attached, rather than
/// guessing in `updateNSView` when `view.window` may not yet be wired up.
private struct TaskDetailWindowTagger: NSViewRepresentable {
    let target: TaskDetailTarget

    func makeNSView(context: Context) -> NSView {
        let view = TaggerView()
        view.target = target
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? TaggerView else { return }
        view.target = target
        view.applyIdentifierIfNeeded()
    }

    @MainActor
    private final class TaggerView: NSView {
        var target: TaskDetailTarget?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyIdentifierIfNeeded()
        }

        func applyIdentifierIfNeeded() {
            guard let window, let target else { return }
            let id = AgentSmithApp.taskDetailWindowIdentifier(for: target)
            if window.identifier?.rawValue != id {
                window.identifier = NSUserInterfaceItemIdentifier(id)
            }
        }
    }
}

/// Cross-scene handoff queue for "which session should the next fresh window adopt?".
/// Commands don't have direct access to @SceneStorage, so we stash intended sessions
/// in this FIFO queue; each SessionScene that appears with empty storage consumes the
/// head. A queue (not a single value) prevents two rapid Cmd+Ns from clobbering each
/// other's handoff. @MainActor because it's only read/written from main-actor SwiftUI code.
@MainActor private var pendingNewSessionIDs: [UUID] = []


/// Container view that resolves the per-session view model and renders MainView.
///
/// Uses `@SceneStorage` so each window "remembers" which session it's showing across
/// app restarts (macOS handles scene restoration for WindowGroups automatically).
struct SessionScene: View {
    @Bindable var shared: SharedAppState
    @Bindable var sessionManager: SessionManager
    @Environment(\.openWindow) private var openWindow

    @SceneStorage("sessionID") private var sessionIDString: String = ""
    @State private var bootstrapped = false
    @State private var showRenameSheet = false
    @State private var renameDraft = ""

    var body: some View {
        Group {
            if !shared.hasLoadedPersistedState || !bootstrapped {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let id = resolvedID, let vm = sessionManager.viewModel(for: id) {
                MainView(viewModel: vm, sessionManager: sessionManager)
                    .navigationTitle(vm.session.name)
                    // Inject the session's attachment-bytes loader so AttachmentView /
                    // ImageLightbox / TaskAttachmentList can lazy-load bytes for
                    // session-restored attachments via @Environment(\.attachmentBytesLoader).
                    .environment(\.attachmentBytesLoader, vm.attachmentBytesLoader)
            } else {
                ContentUnavailableView {
                    Label("No Session", systemImage: "rectangle.stack.badge.plus")
                } description: {
                    Text("This window has no session bound to it yet. Open one from the Session menu, or create a new one.")
                } actions: {
                    Button("New Session") {
                        Task { await createAndAdoptSession() }
                    }
                }
            }
        }
        .overlay {
            if shared.launchSplashVisible {
                LaunchSplashView(onFinished: {
                    withAnimation(.easeIn(duration: 0.2)) {
                        shared.launchSplashVisible = false
                    }
                })
            }
        }
        .task { await bootstrapIfNeeded() }
        .background(WindowKeyObserver(sessionID: resolvedID, shared: shared))
        .onChange(of: shared.renameSessionRequestID) { _, newValue in
            guard let id = newValue, id == resolvedID,
                  let session = sessionManager.sessions.first(where: { $0.id == id }) else {
                return
            }
            // Project rule: defer @State / @Observable mutations out of .onChange.
            DispatchQueue.main.async {
                shared.renameSessionRequestID = nil
                renameDraft = session.name
                showRenameSheet = true
            }
        }
        .sheet(isPresented: $showRenameSheet) {
            RenameSessionSheet(
                name: $renameDraft,
                onCommit: {
                    let trimmed = renameDraft.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty, let id = resolvedID else {
                        showRenameSheet = false
                        return
                    }
                    Task { await sessionManager.renameSession(id: id, name: trimmed) }
                    showRenameSheet = false
                },
                onCancel: { showRenameSheet = false }
            )
        }
    }

    private var resolvedID: UUID? {
        guard let uuid = UUID(uuidString: sessionIDString) else { return nil }
        return sessionManager.sessions.contains(where: { $0.id == uuid }) ? uuid : nil
    }

    private func bootstrapIfNeeded() async {
        // Both calls are idempotent — the first window's invocation does the work;
        // concurrent windows await the same Task and then return.
        await shared.loadPersistedState()
        await sessionManager.loadSessions()

        // If the command-triggered path stashed session IDs, adopt the next one.
        if sessionIDString.isEmpty, !pendingNewSessionIDs.isEmpty {
            let pending = pendingNewSessionIDs.removeFirst()
            if sessionManager.sessions.contains(where: { $0.id == pending }) {
                sessionIDString = pending.uuidString
            }
        }

        // If no valid session ID is set for this window, pick one.
        if resolvedID == nil {
            if let first = sessionManager.sessions.first {
                sessionIDString = first.id.uuidString
            } else {
                let session = await sessionManager.createSession(name: "Default")
                sessionIDString = session.id.uuidString
            }
        }

        bootstrapped = true
    }

    private func createAndAdoptSession() async {
        let session = await sessionManager.createSession(templateSessionID: shared.focusedSessionID)
        sessionIDString = session.id.uuidString
    }
}

/// Observes the containing NSWindow's key state and publishes the session ID as
/// `shared.focusedSessionID` so menu commands can target the frontmost tab.
private struct WindowKeyObserver: NSViewRepresentable {
    let sessionID: UUID?
    let shared: SharedAppState

    func makeNSView(context: Context) -> NSView {
        let view = KeyTrackingView()
        view.sessionID = sessionID
        view.shared = shared
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? KeyTrackingView else { return }
        view.sessionID = sessionID
        view.shared = shared
        // Stamp the session id onto the window's identifier so the Session menu's
        // `showOrOpenSession` can find this window later and bring it to front. We use a
        // namespaced identifier (`agent-smith-session-<uuid>`) so we don't collide with
        // SwiftUI's auto-assigned identifiers (which look like "app-main-1").
        if let window = view.window, let id = sessionID {
            let target = AgentSmithApp.windowIdentifier(for: id)
            if window.identifier?.rawValue != target {
                window.identifier = NSUserInterfaceItemIdentifier(target)
            }
        }
        // If this view is currently inside the key window and the effective focused ID
        // differs, republish it. Guarded equality avoids spamming @Observable notifications
        // (which would invalidate any view reading `focusedSessionID`) on every update pass.
        if let window = view.window, window.isKeyWindow, let id = sessionID,
           shared.focusedSessionID != id {
            shared.focusedSessionID = id
        }
    }

    @MainActor
    private final class KeyTrackingView: NSView {
        var sessionID: UUID?
        weak var shared: SharedAppState?
        private var keyObserver: NSObjectProtocol?
        private var resignObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
            keyObserver = nil
            resignObserver = nil
            guard let window else { return }
            keyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let id = self.sessionID else { return }
                    self.shared?.focusedSessionID = id
                }
            }
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Clear only if the focused ID still points at us; another window
                    // may already have claimed focus via didBecomeKeyNotification.
                    if self.shared?.focusedSessionID == self.sessionID {
                        self.shared?.focusedSessionID = nil
                    }
                }
            }
            if window.isKeyWindow, let id = sessionID {
                shared?.focusedSessionID = id
            }
        }

        isolated deinit {
            if let keyObserver {
                NotificationCenter.default.removeObserver(keyObserver)
            }
            if let resignObserver {
                NotificationCenter.default.removeObserver(resignObserver)
            }
        }
    }
}

/// Small sheet used by Rename Session.
private struct RenameSessionSheet: View {
    @Binding var name: String
    let onCommit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Session")
                .font(.title2.bold())
            TextField("Session name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 280)
                .onSubmit(onCommit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: onCommit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 320)
    }
}

/// Identifies an Agent Inspector window instance by session + role.
struct AgentInspectorTarget: Codable, Hashable, Sendable {
    let sessionID: UUID
    let role: AgentRole
}

/// Identifies a Task Detail window instance by session + task ID.
struct TaskDetailTarget: Codable, Hashable, Sendable {
    let sessionID: UUID
    let taskID: UUID
}
