import SwiftUI
import AgentSmithKit
import os

/// Manages the lifecycle of all sessions (tabs/windows) and their view models.
///
/// Session windows are keyed by `Session.id` (UUID). The manager lazily instantiates
/// `AppViewModel` instances on first access and caches them so window focus toggles
/// don't rebuild the per-session runtime state.
@Observable
@MainActor
final class SessionManager {
    private(set) var sessions: [Session] = []
    /// Session IDs whose view models have been created (and therefore have loaded state).
    private(set) var viewModels: [UUID: AppViewModel] = [:]
    /// Set to true once `loadSessions()` completes so concurrent callers can short-circuit.
    private(set) var hasLoadedSessions = false
    /// Tracks the in-flight `loadSessions()` call so concurrent windows that all bootstrap
    /// on first appear share a single run rather than each creating a duplicate "Default".
    private var loadTask: Task<Void, Never>?

    let shared: SharedAppState
    private let logger = Logger(subsystem: "com.agentsmith", category: "SessionManager")

    init(shared: SharedAppState) {
        self.shared = shared
    }

    // MARK: - Loading

    /// Loads the session list from disk. If the list is empty (a fresh install or a
    /// previously emptied install), a single "Default" session is bootstrapped. The legacy
    /// single-session-to-multi-session migration that earlier versions performed here was
    /// retired in 2026-04 — by that point all surviving installs had already migrated.
    /// Safe to call from multiple windows concurrently — the first call does the work,
    /// subsequent callers await the same Task.
    func loadSessions() async {
        if hasLoadedSessions { return }
        if let existing = loadTask {
            await existing.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performLoadSessions()
        }
        loadTask = task
        defer { loadTask = nil }
        await task.value
    }

    private func performLoadSessions() async {
        do {
            sessions = try await shared.basePersistence.loadSessionList()
        } catch {
            logger.error("Failed to load session list: \(error.localizedDescription)")
            sessions = []
        }

        if sessions.isEmpty {
            await bootstrapDefaultSession()
        }
        hasLoadedSessions = true
    }

    /// Creates a "Default" session on first launch with empty per-session state;
    /// `loadPersistedState` will apply bundled defaults when the state is empty.
    private func bootstrapDefaultSession() async {
        let defaultSession = Session(name: "Default")
        let pm = PersistenceManager(sessionID: defaultSession.id)

        do {
            try await pm.saveSessionState(SessionState())
        } catch {
            logger.error("Failed to save Default session state: \(error.localizedDescription)")
        }

        sessions = [defaultSession]
        do {
            try await shared.basePersistence.saveSessionList(sessions)
        } catch {
            logger.error("Failed to save session list: \(error.localizedDescription)")
        }
    }

    // MARK: - View models

    /// Returns the view model for the given session ID, creating it on first access.
    /// Returns nil if the session ID isn't in the list.
    ///
    /// **Do not add stored-property mutations here.** SessionManager is `@Observable`, so
    /// any mutation of one of its stored vars in this hot path would invalidate the SwiftUI
    /// body that just called this method, which would re-call this method, repeat — a
    /// runaway loop visible in logs as a `viewModel(for:)` count climbing into the hundreds
    /// of thousands. (We learned this the hard way with a debug call counter.)
    func viewModel(for id: UUID) -> AppViewModel? {
        if let cached = viewModels[id] {
            return cached
        }
        guard let session = sessions.first(where: { $0.id == id }) else {
            return nil
        }
        logger.notice("viewModel(for:) CREATING new VM session=\(id.uuidString, privacy: .public) name=\(session.name, privacy: .public)")
        let vm = AppViewModel(session: session, shared: shared)
        viewModels[id] = vm
        Task { await vm.loadPersistedState() }
        return vm
    }

    // MARK: - Mutations

    /// Creates a new empty session, persists the list, and returns the session.
    ///
    /// If `templateSessionID` resolves to a loaded view model, the new session inherits
    /// that session's per-session settings. Otherwise, any loaded view model is used as
    /// a fallback. This means Cmd+N from a specific tab gives the user another tab
    /// pre-configured like the one they were just using, rather than whichever VM
    /// happened to be first in the dictionary's hash order.
    @discardableResult
    func createSession(name: String? = nil, templateSessionID: UUID? = nil) async -> Session {
        // Friendly adjective-noun name (collision-checked) when the caller doesn't specify one, so new
        // sessions are distinguishable at a glance instead of a stack of identical "New Session"s.
        let chosenName = name ?? SessionNameGenerator.uniqueName(avoiding: Set(sessions.map(\.name)))
        let session = Session(name: chosenName)
        sessions.append(session)
        await persistSessions()

        // Inherit settings: prefer the caller's specified template, fall back to any loaded VM.
        let template: AppViewModel? = {
            if let templateSessionID, let explicit = viewModels[templateSessionID] {
                return explicit
            }
            return viewModels.values.first
        }()
        if let template {
            let inheritedState = SessionState(
                agentAssignments: template.agentAssignments,
                agentPollIntervals: template.agentPollIntervals,
                agentMaxToolCalls: template.agentMaxToolCalls,
                agentMessageDebounceIntervals: template.agentMessageDebounceIntervals,
                toolsEnabled: template.toolsEnabled,
                autoRunNextTask: template.autoRunNextTask,
                autoRunInterruptedTasks: template.autoRunInterruptedTasks,
                orchestrationOverride: template.orchestrationOverride
            )
            let pm = PersistenceManager(sessionID: session.id)
            do {
                try await pm.saveSessionState(inheritedState)
            } catch {
                logger.error("Failed to save inherited session state for \(session.id.uuidString): \(error.localizedDescription)")
            }
        }

        return session
    }

    /// Renames a session.
    func renameSession(id: UUID, name: String) async {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].name = name
        sessions[idx].updatedAt = Date()
        await persistSessions()
    }

    /// Deletes a session entirely. Stops + evicts its live view model (moving its active tasks to the
    /// global store — archived or soft-deleted per `archivingTasks` — first so they survive), removes it
    /// from the list, and deletes its `sessions/<id>/` directory (transcript, evidence, schedules,
    /// state). Its already-global archived/deleted tasks, global usage, and attachments are untouched.
    /// If it was the LAST session, a fresh named one is minted and RETURNED so the caller can open a
    /// window for it (the app is never left sessionless).
    /// The result of a delete attempt. `.aborted` means NOTHING changed — a task couldn't be preserved
    /// to the global store, so the session (and its on-disk data) is left fully intact; the caller
    /// surfaces the reason and must NOT close the window.
    enum SessionDeletionOutcome: Sendable {
        /// Deleted. `replacement` is non-nil only when this was the LAST session (a fresh one was minted).
        case deleted(replacement: Session?)
        case aborted(reason: String)
    }

    @discardableResult
    func deleteSession(id: UUID, archivingTasks: Bool) async -> SessionDeletionOutcome {
        if let vm = viewModels[id] {
            await vm.stopAll()
            // Gate the directory delete on EVERY task having reached the global store. archive/softDelete
            // durably persist (destination-before-source), so `allMoved == true` means the tasks are safe
            // globally and it's safe to remove the session dir. A partial move → abort, lose nothing.
            let allMoved = await vm.moveAllActiveTasksToInactive(archiving: archivingTasks)
            guard allMoved else {
                logger.error("Session delete aborted for \(id.uuidString, privacy: .public): not all active tasks could be moved to the global store")
                return .aborted(reason: "Some of this session's tasks couldn't be saved to the global store, so the session was NOT deleted (nothing was lost). Please try again.")
            }
            _ = await shared.persistInactiveTasksNow()
            // Deliberately AFTER the abort guards: an aborted delete leaves a fully functional
            // session, so its MCP subprocesses must not be torn down speculatively. stopAll()
            // never shuts MCP down (the host is reused across runtime restarts); deletion is
            // the one path where the servers would otherwise be orphaned until app quit.
            await vm.shutdownMCP()
            viewModels.removeValue(forKey: id)
        } else {
            // Closed session (no live VM): move its active tasks into the global store straight from disk.
            // A READ failure MUST abort — treating an unreadable file as "zero tasks" and then deleting
            // the directory would silently lose them.
            guard let store = try? await shared.ensureInactiveTaskStore() else {
                return .aborted(reason: "Couldn't open the global task store; the session was NOT deleted. Please try again.")
            }
            let pm = PersistenceManager(sessionID: id)
            let loaded: [AgentTask]
            do {
                loaded = try await pm.loadTasks()
            } catch {
                logger.error("Session delete aborted for closed session \(id.uuidString, privacy: .public): could not read its tasks (\(error.localizedDescription, privacy: .public))")
                return .aborted(reason: "Couldn't read this session's tasks, so it was NOT deleted (nothing was lost). Please try again.")
            }
            let disposition: AgentTask.TaskDisposition = archivingTasks ? .archived : .recentlyDeleted
            for var task in loaded where task.disposition == .active {
                task.disposition = disposition
                await store.insert(task)
            }
            guard await shared.persistInactiveTasksNow() else {
                return .aborted(reason: "Couldn't save this session's tasks to the global store, so it was NOT deleted. Please try again.")
            }
        }

        sessions.removeAll { $0.id == id }
        shared.removeSessionObservers(sessionID: id)
        await persistSessions()
        try? await PersistenceManager(sessionID: id).deleteSessionData()

        if sessions.isEmpty {
            // Never leave the app sessionless — mint a fresh named session for the caller to open.
            return .deleted(replacement: await createSession())
        }
        return .deleted(replacement: nil)
    }

    // closeSession was removed in 2026-04. Closing a window must NEVER mutate or delete the
    // underlying session — Cmd-W is now a UI-only operation and there is no destructive
    // "Close Session…" command anywhere in the app. Sessions remain on disk indefinitely
    // and can be reopened from the Session menu. A future "Manage Sessions" sheet will
    // bring deletion back as an explicit, separately-confirmed action — see ROADMAP.md.

    /// Stops agents in every session and silences all speech (emergency-stop semantics).
    func stopAll() async {
        for vm in viewModels.values {
            await vm.stopAll()
        }
        // Silence any in-flight speech now that every session has stopped.
        shared.speechController.stopAll()
    }

    /// Drains all persistence on app termination: every loaded session's per-session writers,
    /// the shared usage store, and the shared memory store. Unlike `stopAll()`, this runs the
    /// flush regardless of whether each session's runtime is running, so a normal Cmd-Q does
    /// not lose buffered channel-log, usage, or retrieval-stat writes.
    func flushAll() async {
        // Flush the global inactive-task store BEFORE the per-session task writers. A disposition
        // move writes the destination (inactive) durably before removing the source (active); if a
        // kill lands mid-flush, inactive-first preserves that ordering so a moved task can't be
        // stripped from its session file before it's durable in the global file.
        await shared.flushInactiveTasks()
        await shared.flushTemplateLibrary()
        for vm in viewModels.values {
            await vm.flushForTermination()
        }
        await shared.usageStore.flush()
        await shared.flushMemories()
    }

    /// Is any session currently running?
    var isAnyRunning: Bool {
        viewModels.values.contains(where: \.isRunning)
    }

    /// Returns the session ID that owns `taskID`, scanning every session whose view model
    /// has been loaded. Used by the prior-task link in `TaskDetailWindow` so a referenced
    /// task from another tab opens in a fresh detail window scoped to its own session.
    /// Returns nil if no loaded view model contains the task — the caller can fall back
    /// to the current session, which will surface the "Task Not Found" placeholder if it
    /// also doesn't have it.
    func resolveSessionID(forTaskID taskID: UUID) -> UUID? {
        for (sid, vm) in viewModels {
            if vm.tasks.contains(where: { $0.id == taskID }) {
                return sid
            }
        }
        return nil
    }

    private func persistSessions() async {
        do {
            try await shared.basePersistence.saveSessionList(sessions)
        } catch {
            logger.error("Failed to save session list: \(error.localizedDescription)")
        }
    }
}
