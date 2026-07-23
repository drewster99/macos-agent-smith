import SwiftUI
import AgentSmithKit
import SwiftLLMKit
import UniformTypeIdentifiers
import os

/// Bridges one session's orchestration runtime to the SwiftUI UI.
///
/// Each session (tab/window) owns its own `AppViewModel`, which owns its own
/// `OrchestrationRuntime`, `TaskStore`, channel log, and attachments. Shared app-level
/// state (LLM catalog, speech, billing, memories) lives on `SharedAppState`.
@Observable
@MainActor
final class AppViewModel {
    let session: Session
    let shared: SharedAppState

    var messages: [ChannelMessage] = []

    /// Set of `requestID`s for every resident `tool_request` message, maintained incrementally as
    /// `messages` mutates (O(1) per append) so `ChannelLogView` doesn't have to rebuild it over the
    /// whole transcript on every render. It must cover ALL resident messages — not just the render
    /// window — so a security-review / tool-output row whose parent scrolled out of the window still
    /// collapses into that parent instead of leaking as a loose row.
    private(set) var renderedToolRequestIDs: Set<String> = []

    /// The `requestID` of `message` if it is a `tool_request`, else nil.
    private func toolRequestID(of message: ChannelMessage) -> String? {
        guard case .string(let kind)? = message.metadata?["messageKind"], kind == "tool_request",
              case .string(let requestID)? = message.metadata?["requestID"] else { return nil }
        return requestID
    }

    /// Rebuilds `renderedToolRequestIDs` from scratch — used by the infrequent bulk mutations
    /// (initial load, restore-full-history, clear) where incremental maintenance doesn't apply.
    private func rebuildRenderedToolRequestIDs() {
        renderedToolRequestIDs = Set(messages.compactMap(toolRequestID(of:)))
    }

    var tasks: [AgentTask] = [] {
        didSet { rebucketTasks() }
    }
    /// Active tasks for this session's sidebar. Maintained by `rebucketTasks()` so the sidebar's
    /// body never re-filters per render. Archived + deleted are global (below), not per-session.
    private(set) var activeTaskList: [AgentTask] = []
    /// Archived tasks — global across all sessions, sourced from `SharedAppState` so every window
    /// shows the same set and updates live when any window archives or restores a task.
    var archivedTaskList: [AgentTask] { shared.archivedTasks }
    /// Deleted ("Recently Deleted") tasks — global across all sessions, sourced from `SharedAppState`.
    var recentlyDeletedTaskList: [AgentTask] { shared.deletedTasks }
    /// Active scheduled wakes (timers) for this session. Refreshed via runtime callbacks
    /// and on demand from the View → Timers window.
    var activeTimers: [ScheduledWake] = [] {
        didSet { rebuildPendingWakesByTask() }
    }
    /// Pending (`wakeAt > now`) wakes grouped by task ID, in ascending fire order.
    /// Maintained by `rebuildPendingWakesByTask()` so each task row only depends on its
    /// own slice instead of the whole `activeTimers` array.
    private(set) var pendingWakesByTaskID: [UUID: [ScheduledWake]] = [:]
    /// Append-only timer history rows displayed in the Timers history pane. Newest first.
    var timerHistory: [TimerEvent] = []
    /// Whether the user has restored the persisted history into the transcript.
    var hasRestoredHistory = false
    /// Number of messages loaded from disk at launch (available for restore).
    var persistedHistoryCount = 0
    /// The first task currently awaiting Smith's review, if any. Drives the review banner.
    var taskAwaitingReview: AgentTask? {
        tasks.first { $0.status == .awaitingReview }
    }
    /// Set when a task action (archive, delete) is blocked; drives the error alert.
    var taskActionError: String? = nil

    /// Bool projection of `taskActionError` so `.alert(isPresented:)` can bind to it
    /// without re-creating a closure-based `Binding` on every body re-render.
    var hasTaskActionError: Bool {
        get { taskActionError != nil }
        set { if !newValue { taskActionError = nil } }
    }
    /// Set to true after `loadPersistedState()` finishes for this session.
    var hasLoadedPersistedState = false
    /// Whether Smith automatically runs the next pending task after completing one.
    var autoRunNextTask: Bool = true {
        didSet {
            if autoRunNextTask != oldValue {
                logAutoRunChange(name: "autoRunNextTask", old: oldValue, new: autoRunNextTask)
            }
            persistSessionStateAsync()
            Task { await runtime?.setAutoAdvance(autoRunNextTask) }
        }
    }
    /// Whether interrupted tasks are automatically resumed on launch. Defaults ON so a
    /// relaunch picks up where it left off without a manual play.
    var autoRunInterruptedTasks: Bool = true {
        didSet {
            if autoRunInterruptedTasks != oldValue {
                logAutoRunChange(name: "autoRunInterruptedTasks", old: oldValue, new: autoRunInterruptedTasks)
            }
            persistSessionStateAsync()
        }
    }

    /// Captures every change to the auto-run toggles with a brief stack snapshot.
    /// The toggle flipping itself "from off to on" between launches has been observed
    /// without a reproducible code path; this records who changed it so the next
    /// occurrence is diagnosable from logs instead of guesswork.
    private func logAutoRunChange(name: String, old: Bool, new: Bool) {
        let stack = Thread.callStackSymbols.dropFirst().prefix(8).joined(separator: "\n  ")
        logger.notice("\(name, privacy: .public) \(old, privacy: .public) -> \(new, privacy: .public) (session=\(self.session.name, privacy: .public))\n  \(stack, privacy: .public)")
    }

    /// Recomputes the active sidebar bucket from `tasks`. Called from the `tasks` didSet so the
    /// sidebar's body never re-filters per render. `tasks` holds only this session's active tasks
    /// now — archived/deleted are global (read from `SharedAppState` via the computed lists above)
    /// — but we still filter defensively in case a stray non-active task slips in before the load
    /// split moves it out.
    private func rebucketTasks() {
        activeTaskList = tasks.filter { $0.disposition == .active }
    }

    /// Resolves a task by ID across this session's active tasks and the global archived + deleted
    /// buckets. Detail/timer views target tasks by ID and a task may now be in the global buckets
    /// (archived/deleted) rather than this session's active list.
    func anyTask(id: UUID) -> AgentTask? {
        tasks.first { $0.id == id }
            ?? shared.archivedTasks.first { $0.id == id }
            ?? shared.deletedTasks.first { $0.id == id }
    }

    func scheduledWakes(for taskID: UUID) -> [ScheduledWake] {
        pendingWakesByTaskID[taskID] ?? []
    }

    func workspaceReferences(for task: AgentTask) -> [(label: String, path: String)] {
        var rows = Self.workspaceReferences(taskID: task.id, labelPrefix: nil, root: persistenceManager.sessionWorkspaceDirectory)
        if let parentTaskID = task.parentTaskID {
            rows.append(contentsOf: Self.workspaceReferences(taskID: parentTaskID, labelPrefix: "Parent", root: persistenceManager.sessionWorkspaceDirectory))
        }
        return rows
    }

    private static func workspaceReferences(taskID: UUID, labelPrefix: String?, root: URL) -> [(label: String, path: String)] {
        let workspace = TaskWorkspace(taskID: taskID, workspaceRoot: root)
        let prefix = labelPrefix.map { $0 + " " } ?? ""
        var rows: [(label: String, path: String)] = []
        if let persistentDirectory = workspace.persistentDirectory {
            rows.append((prefix + "Folder", persistentDirectory.path))
        }
        rows.append((prefix + "Scratch", workspace.temporaryDirectory.path))
        if let evidenceDirectory = workspace.evidenceDirectory {
            rows.append((prefix + "Evidence", evidenceDirectory.path))
        }
        return rows
    }

    /// Builds `pendingWakesByTaskID` from `activeTimers`, dropping wakes whose fire time
    /// has already passed and sorting each task's wakes ascending. Each task row only
    /// reads its own slice, so an unrelated timer fire/cancel doesn't re-render every row.
    private func rebuildPendingWakesByTask() {
        let now = Date()
        var grouped: [UUID: [ScheduledWake]] = [:]
        for wake in activeTimers where wake.wakeAt > now {
            guard let taskID = wake.taskID else { continue }
            grouped[taskID, default: []].append(wake)
        }
        for key in grouped.keys {
            grouped[key]?.sort { $0.wakeAt < $1.wakeAt }
        }
        pendingWakesByTaskID = grouped
    }


    var isRunning = false
    var isAborted = false
    var abortReason = ""
    var inputText = ""
    var pendingAttachments: [Attachment] = []
    /// History of sent messages for up/down arrow recall (per-tab).
    private var messageHistory: [String] = []
    /// Current position in message history (-1 = not browsing, 0 = most recent).
    private var historyIndex = -1
    /// Stash of the in-progress text before the user started browsing history.
    private var historyStash = ""
    private static let maxMessageHistory = 100
    /// Roles of agents that are currently waiting for an LLM response.
    var processingRoles: Set<AgentRole> = []
    /// Tool names currently executing, per agent role. A multiset (counts) — a single role
    /// can have multiple parallel calls of the same tool in flight (e.g. parallel
    /// `run_applescript`), so we track counts rather than a Set so the indicator clears
    /// only when the LAST call of a given name finishes. Surfaced in the inspector status
    /// badge as "Working — <toolName>" when no LLM call is also in flight.
    var toolExecutingByRole: [AgentRole: [String: Int]] = [:]
    /// Tools available to each agent role, populated when agents come online.
    var agentToolNames: [AgentRole: [String]] = [:]
    /// Whether the Inspector panel is visible.
    var showInspector = false
    /// Dedicated observable store for inspector data, updated via push callbacks.
    let inspectorStore = AgentInspectorStore()

    /// Per-session idle poll intervals for each agent role (seconds).
    var agentPollIntervals: [AgentRole: TimeInterval] = [
        .smith: 20, .brown: 25, .securityAgent: 13
    ] {
        didSet { persistSessionStateAsync() }
    }
    /// Per-session maximum tool calls per LLM response for each agent role.
    var agentMaxToolCalls: [AgentRole: Int] = [
        .smith: 100, .brown: 100, .securityAgent: 100
    ] {
        didSet { persistSessionStateAsync() }
    }
    /// Per-session message debounce intervals for each agent role (seconds).
    var agentMessageDebounceIntervals: [AgentRole: TimeInterval] = [
        .smith: 1, .brown: 1, .securityAgent: 1
    ] {
        didSet { persistSessionStateAsync() }
    }
    /// Per-session: maps each agent role to a `ModelConfiguration.id`.
    var agentAssignments: [AgentRole: UUID] = [:] {
        didSet { persistSessionStateAsync(); scheduleProviderRefresh() }
    }
    /// Per-session: the `ModelConfiguration.id` the acceptance-validator runs on. Held
    /// separately from `agentAssignments` because the validator has no `AgentRole` case.
    /// Nil means validation falls back to the Summarizer's model (historical behavior).
    var validatorAssignment: UUID? = nil {
        didSet { persistSessionStateAsync(); scheduleProviderRefresh() }
    }
    /// Per-session tool allowlist. Missing/true = enabled. Currently no UI; data model only.
    var toolsEnabled: [String: Bool] = [:] {
        didSet { persistSessionStateAsync() }
    }

    private let logger = Logger(subsystem: "com.agentsmith", category: "AppViewModel")
    private let stopLogger = Logger(subsystem: "com.agentsmith", category: "Stop")
    /// Models already surfaced as absent from the capability catalog, so the one-time notice in
    /// `resolveInjectionCapabilities` doesn't repeat on every provider refresh.
    private var capabilityCatalogMissNoticeShown: Set<String> = []
    private var runtime: OrchestrationRuntime?
    /// Debounces provider rebuilds so a burst of Settings edits (every model field commits) results
    /// in a single `makeProvider`/keychain pass once editing settles, not one per keystroke.
    private var providerRefreshTask: Task<Void, Never>?
    /// Per-session MCP client host. Created once on first `start()` and reused across
    /// runtime restarts so its subprocesses survive task restarts; torn down when the
    /// session is closed (`shutdownMCP()`).
    private var mcpHost: MCPClientHost?
    /// Server IDs already announced as failed in this session's transcript, so a repeated
    /// status push doesn't re-post. Cleared per server when it leaves the failed state.
    private var mcpAnnouncedFailures: Set<UUID> = []
    /// Kept alive independently of `runtime` so task operations work even when agents aren't running.
    private var taskStore: TaskStore?
    private var channelStreamTask: Task<Void, Never>?
    /// Coalesces channel-log persistence. Messages are appended to an on-disk JSONL log; the
    /// debounce batches a streaming burst into one append call rather than one per message.
    private var channelLogPersistTask: Task<Void, Never>?
    private static let channelLogPersistDebounce: Duration = .milliseconds(500)
    /// Messages appended to the transcript but not yet handed to the append writer. Held
    /// independently of `messages` so trimming the resident tail (below) never drops a message
    /// before it reaches disk.
    private var pendingChannelAppends: [ChannelMessage] = []
    /// Upper bound on messages kept resident during normal operation. The full transcript lives
    /// on disk (JSONL); only this bounded tail is held in memory and rendered, so a long session
    /// can't grow the heap without bound. Trimming is suspended once the user pulls in the full
    /// history via "Restore full history" — they've explicitly opted into holding it all.
    private static let residentMessageCap = 5_000
    /// Monotonic generation tokens that serialize the application of store snapshots to the
    /// main-actor mirrors (`tasks`, `timerHistory`). Each `onChange` Task bumps the counter
    /// at body start (synchronously on the serial main actor), captures its generation, then
    /// — after the `await store.allTasks()` hop — applies only if still the latest. This makes
    /// a burst of store mutations apply last-write-wins instead of letting two racing Tasks
    /// resolve their awaits out of order and clobber newer data with older.
    private var taskApplyGeneration: UInt64 = 0
    private var timerApplyGeneration: UInt64 = 0
    let persistenceManager: PersistenceManager

    /// Closure that resolves an attachment's bytes from the per-session attachments
    /// directory. Used by `ImageCache` so attachment views can render thumbnails for
    /// session-restored attachments where `Attachment.data` is nil. The closure is
    /// `@Sendable` and crosses task boundaries; capturing `persistenceManager` (an
    /// actor) is fine because the actor methods are themselves `@Sendable`-callable.
    var attachmentBytesLoader: @Sendable (UUID, String) async -> Data? {
        let pm = persistenceManager
        return { id, filename in await pm.loadAttachmentData(id: id, filename: filename) }
    }

    /// Set to true while `loadPersistedState` is applying values from disk so that
    /// each field's didSet doesn't fire a `persistSessionStateAsync` that races
    /// with later loads. Without this, `agentAssignments = state.agentAssignments`
    /// kicked off a Task.detached snapshotting `autoRunNextTask=true` (its default,
    /// not yet loaded). The autoRun set a moment later kicked off a second
    /// Task.detached with `autoRunNextTask=false`. The two writes raced; whichever
    /// won was what came back on the next launch — so the toggle silently flipped
    /// back to its default every few launches.
    private var isApplyingPersistedState = false

    /// Coalescing serial writers for each per-session file. Replaces the prior
    /// per-call `Task.detached` pattern, which let snapshots reach the
    /// persistence actor out-of-order — an older snapshot could overwrite a
    /// newer one on disk. Each writer drains pending work in FIFO order and
    /// `flush()` actually waits for in-flight writes to complete (the
    /// `flushPersistence()` path used to race them).
    private let channelLogAppendWriter: ChannelLogAppendWriter
    private let tasksWriter: SerialPersistenceWriter<[AgentTask]>
    private let timerEventsWriter: SerialPersistenceWriter<[TimerEvent]>
    private let scheduledWakesWriter: SerialPersistenceWriter<[ScheduledWake]>
    private let sessionStateWriter: SerialPersistenceWriter<SessionState>

    // MARK: - Cost caches

    /// Cached per-task cost totals. Entries are added lazily by `loadTaskCost(_:)`
    /// after the first fetch and live for the duration of the session — task
    /// `UsageRecord`s are append-only and a completed task's records are immutable.
    private var taskCostCache: [UUID: Double] = [:]
    /// Set of task IDs with an in-flight `loadTaskCost(_:)` fetch — used to
    /// suppress duplicate async queries when SwiftUI re-renders the same row
    /// before the first fetch returns.
    private var taskCostInFlight: Set<UUID> = []

    init(session: Session, shared: SharedAppState) {
        self.session = session
        self.shared = shared
        let pm = PersistenceManager(sessionID: session.id)
        self.persistenceManager = pm
        self.channelLogAppendWriter = ChannelLogAppendWriter { messages in
            try await pm.appendChannelMessages(messages)
        }
        self.tasksWriter = SerialPersistenceWriter(label: "tasks") { snapshot in
            try await pm.saveTasks(snapshot)
        }
        self.timerEventsWriter = SerialPersistenceWriter(label: "timerEvents") { snapshot in
            try await pm.saveTimerEvents(snapshot)
        }
        self.scheduledWakesWriter = SerialPersistenceWriter(label: "scheduledWakes") { snapshot in
            try await pm.saveScheduledWakes(snapshot)
        }
        self.sessionStateWriter = SerialPersistenceWriter(label: "sessionState") { snapshot in
            try await pm.saveSessionState(snapshot)
        }
    }

    // MARK: - Lifecycle

    /// Loads session-scoped persisted state. Call when the view model is first created.
    /// The shared app state (llmKit, memories, usage) is loaded separately by `SharedAppState.loadPersistedState()`.
    func loadPersistedState() async {
        // Suppress per-field didSet writes for the duration of the load. Multiple
        // detached writes racing each other was clobbering the autoRun toggles
        // back to their in-memory defaults on next launch. We do one explicit
        // write at the end via `persistSessionStateAsync` once every field has
        // settled at its loaded value.
        isApplyingPersistedState = true
        defer { isApplyingPersistedState = false }

        // Apply default tunings from shared (bundled defaults) so UI sliders start at something sensible.
        agentPollIntervals = shared.defaultAgentPollIntervals
        agentMaxToolCalls = shared.defaultAgentMaxToolCalls
        agentMessageDebounceIntervals = shared.defaultAgentMessageDebounceIntervals

        // Migrate per-session attachment files into the global store before loading anything that
        // references attachments (channel log, tasks). Deduped + idempotent across windows.
        await shared.ensureAttachmentsMigrated()

        // Load per-session settings (assignments, tunings, flags) if they exist.
        do {
            if let state = try await persistenceManager.loadSessionState() {
                logger.notice("loadPersistedState: session=\(self.session.name, privacy: .public) loaded autoRunNextTask=\(state.autoRunNextTask, privacy: .public) autoRunInterruptedTasks=\(state.autoRunInterruptedTasks, privacy: .public)")
                if !state.agentAssignments.isEmpty {
                    agentAssignments = state.agentAssignments
                }
                if !state.agentPollIntervals.isEmpty {
                    agentPollIntervals = state.agentPollIntervals
                }
                if !state.agentMaxToolCalls.isEmpty {
                    agentMaxToolCalls = state.agentMaxToolCalls
                }
                if !state.agentMessageDebounceIntervals.isEmpty {
                    agentMessageDebounceIntervals = state.agentMessageDebounceIntervals
                }
                toolsEnabled = state.toolsEnabled
                autoRunNextTask = state.autoRunNextTask
                autoRunInterruptedTasks = state.autoRunInterruptedTasks
                validatorAssignment = state.validatorAssignment
            } else {
                logger.notice("loadPersistedState: session=\(self.session.name, privacy: .public) no state on disk — using defaults autoRunNextTask=true autoRunInterruptedTasks=true")
                // No per-session state — fall back to the shared default assignments (from
                // bundled defaults). New sessions get this the first time they're opened.
                agentAssignments = shared.defaultAgentAssignments
            }
        } catch {
            logger.error("Failed to load session state: \(error.localizedDescription)")
            agentAssignments = shared.defaultAgentAssignments
        }

        // Prune stale assignments that reference configurations that no longer exist.
        let validConfigIDs = Set(shared.llmKit.configurations.map(\.id))
        for (role, configID) in agentAssignments {
            if !validConfigIDs.contains(configID) {
                agentAssignments[role] = nil
                logger.notice("Cleared stale assignment in session \(self.session.name, privacy: .public) for \(role.rawValue, privacy: .public) → \(configID, privacy: .public)")
            }
        }
        if let validatorConfigID = validatorAssignment, !validConfigIDs.contains(validatorConfigID) {
            validatorAssignment = nil
            logger.notice("Cleared stale validator assignment in session \(self.session.name, privacy: .public) → \(validatorConfigID, privacy: .public)")
        }

        // Auto-heal missing required-role assignments. Prefer a config whose
        // name starts with the role name (e.g. "Smith — …" for the smith role)
        // so that a catalog re-seed/prune doesn't silently bind every role to
        // whichever config happens to be first in the list. Only fall back to
        // `validConfigs.first` when no role-named config exists for that role —
        // that keeps the original "never get stuck on ‘no configuration’" goal
        // without entangling roles. Logged so a future regression is visible
        // in the runtime output.
        let validConfigs = shared.llmKit.configurations.filter(\.isValid)
        for role in AgentRole.requiredRoles where agentAssignments[role] == nil {
            let roleName = role.displayName
            let nameMatch = validConfigs.first { config in
                let lowered = config.name.lowercased()
                let prefix = roleName.lowercased()
                return lowered == prefix
                    || lowered.hasPrefix("\(prefix) —")
                    || lowered.hasPrefix("\(prefix) -")
                    || lowered.hasPrefix("\(prefix):")
                    || lowered.hasPrefix("\(prefix) ")
            }
            if let chosen = nameMatch {
                agentAssignments[role] = chosen.id
                logger.notice("Auto-assigned \(role.rawValue, privacy: .public) → \(chosen.name, privacy: .public) (\(chosen.id, privacy: .public)) [name match] in session \(self.session.name, privacy: .public)")
            } else if let fallback = validConfigs.first {
                agentAssignments[role] = fallback.id
                logger.notice("Auto-assigned \(role.rawValue, privacy: .public) → \(fallback.name, privacy: .public) (\(fallback.id, privacy: .public)) [first-valid fallback; no \(roleName, privacy: .public)-named config found] in session \(self.session.name, privacy: .public)")
            }
        }

        // Load message history for up-arrow recall (per-session).
        if let data = UserDefaults.standard.data(forKey: sessionHistoryKey),
           let history = try? JSONDecoder().decode([String].self, from: data) {
            messageHistory = history
        }

        // Load channel log.
        do {
            // Load only the most-recent tail into memory; the full transcript stays on disk.
            // Migration of a legacy channel_log.json (including the one-time file_write metadata
            // strip) happens inside the persistence layer on first access — see
            // `migrateLegacyChannelLogIfNeeded`.
            let (tail, total) = try await persistenceManager.loadChannelLogTail(limit: Self.residentMessageCap)
            messages = tail
            rebuildRenderedToolRequestIDs()
            persistedHistoryCount = total
            // If the whole transcript already fit in the tail there's nothing older to restore.
            hasRestoredHistory = tail.count >= total
        } catch {
            let msg = "Failed to load channel log: \(error)"
            logger.error("\(msg, privacy: .public)")
            shared.startupError = msg
        }

        // Load tasks with status corrections.
        do {
            // The global archived/deleted store. First call runs the one-time per-session →
            // global migration; later calls return the shared instance.
            let inactiveStore = try await shared.ensureInactiveTaskStore()

            var savedTasks: [AgentTask]
            do {
                savedTasks = try await persistenceManager.loadTasks()
            } catch let decodeError as DecodingError {
                // Corrupt tasks.json: move it aside (preserving it for manual recovery) and start
                // this session with an empty active list rather than failing the entire session
                // load over one bad element. Mirrors the inactive-store / channel-log resilience.
                // Non-decode errors (IO/permissions) still propagate to the outer catch below.
                if let moved = try? await persistenceManager.quarantineCorruptTasksFile() {
                    logger.error("tasks.json was corrupt (\(decodeError.localizedDescription, privacy: .public)); quarantined to \(moved.lastPathComponent, privacy: .public) and starting with an empty task list")
                } else {
                    logger.error("tasks.json was corrupt and could not be quarantined: \(decodeError.localizedDescription, privacy: .public)")
                }
                savedTasks = []
            }

            // Running tasks didn't survive the last quit — mark them interrupted.
            var anyStatusChanged = false
            for i in savedTasks.indices {
                if savedTasks[i].status == .running {
                    savedTasks[i].status = .interrupted
                    savedTasks[i].updatedAt = Date()
                    anyStatusChanged = true
                }
            }

            // Migration backstop: any archived/deleted tasks still in this session's file (a
            // session the one-time sweep didn't rewrite, or a crash mid-migration) move to the
            // global store. `merge` dedupes by id, so this is idempotent and never duplicates.
            let strayInactive = savedTasks.filter { $0.disposition != .active }
            if !strayInactive.isEmpty {
                await inactiveStore.merge(strayInactive)
                savedTasks.removeAll { $0.disposition != .active }
            }

            // Auto-archive stale completed tasks (older than 4h) out to the global store.
            let cutoff = Date().addingTimeInterval(-4 * 3600)
            var staleArchived: [AgentTask] = []
            savedTasks.removeAll { task in
                guard task.status == .completed, task.disposition == .active, task.updatedAt < cutoff else { return false }
                var archived = task
                archived.disposition = .archived
                staleArchived.append(archived)
                return true
            }
            if !staleArchived.isEmpty {
                await inactiveStore.merge(staleArchived)
            }

            // Cross-store reconciliation for a crash mid-move: a task can transiently exist in BOTH
            // this session's active file and the global inactive store (the disposition move writes
            // the destination durably, then the source removal lands on a separate coalesced write —
            // a crash in that gap leaves a duplicate). Resolve by newest `updatedAt`, which every
            // move stamps: a newer-or-equal global copy means the task belongs inactive → drop it
            // from the active set here; a newer active copy means an unfinished restore → drop the
            // stale global copy.
            let globalInactive = await inactiveStore.all()
            var removedStaleGlobal = false
            if !globalInactive.isEmpty {
                var inactiveByID: [UUID: AgentTask] = [:]
                for t in globalInactive { inactiveByID[t.id] = t }
                var staleGlobalIDs: [UUID] = []
                savedTasks.removeAll { active in
                    guard let g = inactiveByID[active.id] else { return false }
                    if g.updatedAt >= active.updatedAt { return true }   // inactive wins → drop active copy
                    staleGlobalIDs.append(active.id)                     // active wins → global copy is stale
                    return false
                }
                for id in staleGlobalIDs { await inactiveStore.remove(id: id) }
                removedStaleGlobal = !staleGlobalIDs.isEmpty
            }

            // Before stripping these inactive tasks from this session's file, make sure the global
            // file durably has them. If the global store can't be persisted (corrupt/failed file),
            // KEEP the per-session copies — don't strip — so nothing is lost. The status-change-only
            // case (no inactive moved) always persists.
            let movedToGlobal = !strayInactive.isEmpty || !staleArchived.isEmpty || removedStaleGlobal
            let canStripSessionFile = movedToGlobal ? await shared.persistInactiveTasksNow() : true

            // `tasks` now holds only this session's active tasks.
            tasks = savedTasks
            if canStripSessionFile && (movedToGlobal || anyStatusChanged) {
                persistTasks()
            }

            let standaloneStore = TaskStore(inactiveStore: inactiveStore)
            taskStore = standaloneStore
            await wireDurablePersistHooks(on: standaloneStore)
            await standaloneStore.restore(savedTasks)
            await standaloneStore.setOnChange { [weak self, weak standaloneStore] in
                Task { @MainActor [weak self, weak standaloneStore] in
                    guard let self, let store = standaloneStore else { return }
                    self.taskApplyGeneration &+= 1
                    let myGen = self.taskApplyGeneration
                    let allTasks = await store.allTasks()
                    guard myGen == self.taskApplyGeneration else { return }
                    self.tasks = allTasks
                    self.updateTaskOverlay()
                    self.persistTasks()
                }
            }
        } catch {
            let msg = "Failed to load tasks: \(error)"
            logger.error("\(msg, privacy: .public)")
            shared.startupError = msg
        }

        // Load timer history (timer_events.json) for the Timers history pane. Failure here
        // is non-fatal — an empty timer history just means "first run" or a corrupted file we
        // can rebuild as new events come in.
        do {
            let savedEvents = try await persistenceManager.loadTimerEvents()
            timerHistory = savedEvents.sorted { $0.timestamp > $1.timestamp }
        } catch {
            logger.error("Failed to load timer events: \(error.localizedDescription)")
        }

        // Persisted scheduled wakes are loaded fresh from disk by the runtime on every
        // `start()` call via the `loadPersistedWakes` closure wired below — both cold
        // launch AND `restartForNewTask` use the same path, so wakes survive both app
        // quit and run_task restarts. No pre-load needed here.

        hasLoadedPersistedState = true

        // Now that every field has been settled at its loaded value, do exactly one
        // write to disk. The didSet writes were suppressed via isApplyingPersistedState
        // for the duration of this function — see the flag's docstring for the race
        // it's avoiding. We re-set the flag false here (in addition to the deferred
        // reset above) explicitly to make the ordering with the explicit save obvious
        // to a future reader. The deferred reset above still fires for safety.
        isApplyingPersistedState = false
        persistSessionStateAsync()
    }

    /// Starts this session's runtime with its per-session agent assignments.
    func start() async {
        guard !isRunning else { return }
        guard !isAborted else { return }

        let missingRoles = AgentRole.requiredRoles.filter { agentAssignments[$0] == nil }
        if !missingRoles.isEmpty {
            let names = missingRoles.map(\.displayName).joined(separator: ", ")
            shared.startupError = "Cannot start — missing configuration for: \(names)"
            return
        }

        var providers: [AgentRole: any LLMProvider] = [:]
        var configurations: [AgentRole: ModelConfiguration] = [:]
        var apiTypes: [AgentRole: ProviderAPIType] = [:]
        var visionByRole: [AgentRole: Bool] = [:]
        var documentsByRole: [AgentRole: Bool] = [:]
        for role in AgentRole.allCases {
            guard let configID = agentAssignments[role] else { continue }
            do {
                providers[role] = try shared.llmKit.makeProvider(for: configID)
            } catch {
                shared.startupError = "Failed to create provider for \(role.displayName): \(error.localizedDescription)"
                return
            }
            if let modelConfig = shared.llmKit.configurations.first(where: { $0.id == configID }) {
                configurations[role] = modelConfig
                if let modelProvider = shared.llmKit.providers.first(where: { $0.id == modelConfig.providerID }) {
                    apiTypes[role] = modelProvider.apiType
                }
                let resolved = resolveInjectionCapabilities(providerID: modelConfig.providerID, modelID: modelConfig.modelID, roleLabel: role.displayName)
                visionByRole[role] = resolved.vision
                documentsByRole[role] = resolved.documents
            }
        }

        var tuning: [AgentRole: AgentTuningConfig] = [:]
        for role in AgentRole.allCases {
            tuning[role] = AgentTuningConfig(
                pollInterval: agentPollIntervals[role] ?? 5,
                maxToolCalls: agentMaxToolCalls[role] ?? 100,
                messageDebounceInterval: agentMessageDebounceIntervals[role] ?? 1
            )
        }

        // Prepare the shared semantic engine (idempotent — only pays cost on first start across all sessions).
        let engine: SemanticSearchEngine
        do {
            engine = try await shared.ensureSemanticEngine()
        } catch {
            let msg = "Failed to prepare embedding model: \(error.localizedDescription)"
            logger.error("\(msg, privacy: .public)")
            shared.startupError = msg
            return
        }

        // Ensure shared memory store is loaded (runs re-embedding migrations exactly once).
        let sharedMemoryStore: MemoryStore
        do {
            sharedMemoryStore = try await shared.ensureMemoryStore()
        } catch {
            let msg = "Failed to prepare memory store: \(error.localizedDescription)"
            logger.error("\(msg, privacy: .public)")
            shared.startupError = msg
            return
        }

        // Shared global store of archived + deleted tasks. Normally already created during
        // loadPersistedState; re-ensure here so a failed earlier load still yields a valid store.
        let sharedInactiveStore: InactiveTaskStore
        do {
            sharedInactiveStore = try await shared.ensureInactiveTaskStore()
        } catch {
            let msg = "Failed to prepare archived/deleted task store: \(error.localizedDescription)"
            logger.error("\(msg, privacy: .public)")
            shared.startupError = msg
            return
        }

        let newRuntime = OrchestrationRuntime(
            providers: providers,
            configurations: configurations,
            providerAPITypes: apiTypes,
            supportsVisionByRole: visionByRole,
            supportsDocumentsByRole: documentsByRole,
            agentTuning: tuning,
            semanticSearchEngine: engine,
            usageStore: shared.usageStore,
            autoAdvanceEnabled: autoRunNextTask,
            autoRunInterruptedTasks: autoRunInterruptedTasks,
            memoryStore: sharedMemoryStore,
            inactiveTaskStore: sharedInactiveStore
        )
        // Bridge per-session attachment persistence into the runtime so the new
        // attachment-aware tools (create_task / task_update / task_complete) can
        // resolve IDs and ingest local files.
        let pm = persistenceManager
        await newRuntime.setAttachmentPersistence(
            loader: { id, filename in await pm.loadAttachmentData(id: id, filename: filename) },
            saver: { attachment in try await pm.saveAttachment(attachment) },
            urlProvider: { id, filename in pm.attachmentURL(id: id, filename: filename) },
            syncURLProvider: { id, filename in pm.attachmentURL(id: id, filename: filename) }
        )
        // Push the current attachment-size caps from SharedAppState into the runtime so
        // the registry's per-file cap and the per-message aggregate cap match the user's
        // configured limits. Caps apply at session start; Settings UI can prompt Restart
        // if a cap is changed mid-session.
        await newRuntime.setMaxAttachmentBytesPerFile(shared.maxAttachmentBytesPerFile)
        await newRuntime.setMaxAttachmentBytesPerMessage(shared.maxAttachmentBytesPerMessage)
        // Tool-security configuration (Settings). Applied to each Brown at spawn; changes take
        // effect on the next session start (consistent with the other start-time settings).
        await newRuntime.setToolSecurity(
            preflightScoping: shared.enablePreflightScoping,
            perCallCheck: shared.enablePerToolCheck,
            globalPolicy: shared.globalToolPolicies
        )
        // Worker-pool capacity ("Max simultaneous tasks" in Settings): applied at start
        // and pushed live on change.
        await newRuntime.setWorkerCapacity(shared.maxSimultaneousTasks)
        // Apply later Settings changes to this session immediately (no restart). Re-registering on
        // each start() replaces any prior closure for this session.
        shared.registerToolSecurityObserver(session.id) { [weak self] in
            self?.pushToolSecurity()
        }
        shared.registerWorkerCapacityObserver(session.id) { [weak self] in
            guard let self else { return }
            let capacity = self.shared.maxSimultaneousTasks
            Task { await self.runtime?.setWorkerCapacity(capacity) }
        }
        // Rebuild + push this session's LLM providers when an assigned model config changes, so a
        // model swap takes effect on the next task without a session restart.
        shared.registerModelAssignmentObserver(session.id) { [weak self] in
            self?.scheduleProviderRefresh()
        }

        // Per-session MCP host: create once and reuse across runtime restarts so a task
        // restart never re-launches the configured servers. Observers push status to
        // SharedAppState for the settings UI.
        let mcpConfigs = shared.mcpServers
        if mcpHost == nil {
            let host = MCPClientHost(secretStore: shared.mcpSecretStore)
            let sharedState = shared
            await host.setObservers(
                onToolsChanged: {},
                onStatusChanged: { [weak self] statuses in
                    Task { @MainActor in
                        sharedState.reportMCPStatuses(statuses)
                        self?.announceMCPFailuresIfNeeded(statuses)
                    }
                }
            )
            await host.start(configs: mcpConfigs)
            shared.registerMCPHost(host)
            mcpHost = host
        }
        await newRuntime.setMCPHost(mcpHost)

        runtime = newRuntime
        isRunning = true

        if !tasks.isEmpty {
            let tasksToRestore = tasks
            await newRuntime.taskStore.restore(tasksToRestore)
        }

        await newRuntime.setOnAbort { [weak self] reason in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isAborted = true
                self.abortReason = reason
                self.isRunning = false
                self.processingRoles.removeAll()
                self.toolExecutingByRole.removeAll()
                self.agentToolNames.removeAll()
                self.inspectorStore.clearAll()
                self.clearCostCaches()
                self.runtime = nil
            }
        }

        await newRuntime.setOnProcessingStateChange { [weak self] role, isProcessing in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if isProcessing {
                    self.processingRoles.insert(role)
                } else {
                    self.processingRoles.remove(role)
                }
            }
        }

        await newRuntime.setOnToolExecutionStateChange { [weak self] role, toolName, started in
            Task { @MainActor [weak self] in
                guard let self else { return }
                var counts = self.toolExecutingByRole[role] ?? [:]
                if started {
                    counts[toolName, default: 0] += 1
                } else if let n = counts[toolName] {
                    if n <= 1 { counts.removeValue(forKey: toolName) } else { counts[toolName] = n - 1 }
                }
                if counts.isEmpty {
                    self.toolExecutingByRole.removeValue(forKey: role)
                } else {
                    self.toolExecutingByRole[role] = counts
                }
            }
        }

        await newRuntime.setOnAgentStarted { [weak self] role, toolNames in
            Task { @MainActor [weak self] in
                self?.agentToolNames[role] = toolNames
            }
        }

        let channel = await newRuntime.channel
        // Defensive: never leak a prior subscription. `start()` is guarded by `!isRunning` and
        // the stop path nils this out via quiesceChannelStream, so it's normally already nil —
        // but cancelling before reassigning keeps a single live stream an invariant regardless
        // of how a future restart path is wired.
        channelStreamTask?.cancel()
        channelStreamTask = Task { @MainActor [weak self] in
            for await message in channel.stream() {
                guard let self else { break }
                self.appendToTranscript(message)
                self.shared.speechController.handle(message)
            }
        }

        let liveTaskStore = await newRuntime.taskStore
        // Detach the standalone store's callback before adopting the live one. Otherwise a
        // late mutation on the now-orphaned standalone store would fire its onChange, win the
        // generation race with fresh data from the WRONG (stale) store, and clobber `tasks`.
        if let oldStore = self.taskStore, oldStore !== liveTaskStore {
            await oldStore.setOnChange { }
        }
        self.taskStore = liveTaskStore
        await wireDurablePersistHooks(on: liveTaskStore)
        await liveTaskStore.setOnChange { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.taskApplyGeneration &+= 1
                let myGen = self.taskApplyGeneration
                let allTasks = await liveTaskStore.allTasks()
                guard myGen == self.taskApplyGeneration else { return }
                self.tasks = allTasks
                self.updateTaskOverlay()
                self.persistTasks()
            }
        }

        await liveTaskStore.archiveStaleCompleted()

        await newRuntime.setOnTurnRecorded { [weak self] role, turn in
            Task { @MainActor [weak self] in
                self?.inspectorStore.appendTurn(turn, for: role)
            }
        }

        await newRuntime.setOnContextChanged { [weak self] role, messages in
            Task { @MainActor [weak self] in
                self?.inspectorStore.updateLiveContext(messages, for: role)
            }
        }

        await newRuntime.setOnEvaluationRecorded { [weak self] record in
            Task { @MainActor [weak self] in
                self?.inspectorStore.appendEvaluation(record)
            }
        }

        await newRuntime.setOnLearnedModelOutputLimit { [weak self] providerID, modelID, limit in
            Task { @MainActor [weak self] in
                self?.shared.learnModelOutputLimit(providerID: providerID, modelID: modelID, limit: limit)
            }
        }

        // Restore prior timer history into the runtime's event log so subsequent appends
        // join an existing series rather than start fresh on each launch.
        let priorEvents = timerHistory
        let eventLog = await newRuntime.timerEventLog
        if !priorEvents.isEmpty {
            await eventLog.restore(priorEvents)
        }
        await eventLog.setOnChange { [weak self, weak eventLog] in
            Task { @MainActor [weak self, weak eventLog] in
                guard let self, let log = eventLog else { return }
                self.timerApplyGeneration &+= 1
                let myGen = self.timerApplyGeneration
                let snapshot = await log.allEvents()
                guard myGen == self.timerApplyGeneration else { return }
                self.timerHistory = snapshot
                self.persistTimerEvents(snapshot)
            }
        }

        // Surface timer events into the channel as system messages when the user has the
        // Debug → Show Timer Activity toggle enabled, and snapshot the wake list to disk
        // on every lifecycle event so reminders survive an app quit. We snapshot here
        // (rather than only on `.scheduled`) because cancellations and fires also mutate
        // the in-memory list (cancellation removes a wake; recurrence-fire replaces one
        // wake with the next-occurrence wake).
        //
        // The closure delegates to `handleTimerEvent` on MainActor so both side effects
        // run sequentially in one async context. The prior implementation wrapped each
        // side effect in its own inner `Task { @MainActor in ... }`, so the channel
        // post and the wake snapshot raced — the on-disk wake snapshot could land
        // before the transcript message hit the channel, scrambling visible order.
        await newRuntime.setOnTimerEventForChannel { [weak self] event in
            await self?.handleTimerEvent(event)
        }

        // Live resolver for the scheduled-wakes-interrupt policy — consulted on every
        // auto-run wake fire so toggling the setting takes effect immediately without
        // restarting the runtime. The closure captures the @Observable shared state and
        // reads its current value each invocation.
        let sharedState = shared
        await newRuntime.setScheduledWakesInterruptResolver {
            await MainActor.run { sharedState.scheduledWakesInterruptRunning }
        }

        // Wire the disk-replay loader. The runtime calls this from inside `start()` —
        // every restart path (cold launch AND `restartForNewTask`) — so wakes survive both
        // app quit and run_task restarts. The snapshot is loaded fresh from disk each time
        // rather than cached, so it always reflects the latest persisted state.
        let persistence = persistenceManager
        let logger = self.logger
        await newRuntime.setPendingScheduledRunQueuePersistence(
            load: {
                do {
                    return try await persistence.loadPendingScheduledRunQueue()
                } catch {
                    logger.error("Failed to load pending scheduled-run queue: \(error.localizedDescription)")
                    return []
                }
            },
            persist: { taskIDs in
                do {
                    try await persistence.savePendingScheduledRunQueue(taskIDs)
                } catch {
                    logger.error("Failed to persist pending scheduled-run queue: \(error.localizedDescription)")
                }
            }
        )

        // Acceptance validation: built-in definitions ship IN the app (always current;
        // duplicate under a new name to customize). Migrate any registry written by the
        // old seed-to-disk mechanism, then point the runtime at the user directory.
        // Definitions hot-load per validation round.
        let evaluatorsDirectory = persistence.evaluatorsDirectory
        EvaluatorDefaults.migrateLegacySeededBuiltIns(in: evaluatorsDirectory)
        await newRuntime.setEvaluatorConfiguration(directory: evaluatorsDirectory)

        // Root for per-task persistent evidence directories (worker/validator evidence artifacts
        // live under <session>/tasks/<taskID>/evidence, out of the user's project tree).
        await newRuntime.setTaskWorkspaceRoot(persistence.sessionWorkspaceDirectory)

        // Dedicated validator-slot model (from onboarding / Settings). When unset — or if its
        // provider fails to build — the runtime falls back to the Summarizer's model, which is
        // where acceptance validation has always run.
        await pushValidatorModel(to: newRuntime)

        // Per-session persistence for the pending-user-message buffer (messages typed while
        // Smith was stopped / starting). Wired before the runtime starts so enqueues persist
        // and a fresh runtime reseeds undelivered messages after a crash.
        await newRuntime.setPendingUserMessagePersistence(
            load: {
                do {
                    return try await persistence.loadPendingUserMessages()
                } catch {
                    logger.error("Failed to load pending user messages: \(error.localizedDescription)")
                    return []
                }
            },
            persist: { messages in
                do {
                    try await persistence.savePendingUserMessages(messages)
                } catch {
                    logger.error("Failed to persist pending user messages: \(error.localizedDescription)")
                }
            }
        )

        // Lets the runtime recover a user message that reached the transcript but not the pending
        // buffer (send-during-restart race). A small tail is enough — recovery only inspects the
        // last conversational message.
        await newRuntime.setRecentChannelMessagesLoader {
            do {
                return try await persistence.loadChannelLogTail(limit: 32).messages
            } catch {
                logger.error("Failed to load channel-log tail for message recovery: \(error.localizedDescription)")
                return []
            }
        }

        await newRuntime.setLoadPersistedWakes {
            do {
                return try await persistence.loadScheduledWakes()
            } catch {
                logger.error("Failed to load scheduled wakes for replay: \(error.localizedDescription)")
                return []
            }
        }

        await newRuntime.start()

        // After Smith starts the active-timers list may already contain restored wakes for
        // .scheduled tasks — refresh once so the View → Timers panel shows them.
        await refreshActiveTimers()
    }

    /// Re-reads the currently-active wakes from Smith. Cheap; the agent stores the list
    /// in-memory and there are typically only a handful at any time.
    func refreshActiveTimers() async {
        guard let runtime else {
            activeTimers = []
            return
        }
        // Nil = no live Smith (mid-restart) — keep the last known list rather than
        // flashing the timers panel empty for the teardown window.
        if let wakes = await runtime.currentScheduledWakes() {
            activeTimers = wakes
        }
    }

    /// Cancels a scheduled timer by id. Returns true if anything was cancelled.
    @discardableResult
    func cancelTimer(id: UUID) async -> Bool {
        guard let runtime else { return false }
        let cancelled = await runtime.cancelScheduledWake(id: id)
        if cancelled { await refreshActiveTimers() }
        return cancelled
    }

    /// Renders a single transcript line for a timer event when the Debug toggle is on.
    /// Surfaces a clock icon, a smart time (date elided when today, "Tomorrow" when relevant),
    /// and a friendly action summary parsed from the imperative — `run_task: "Title"` rather
    /// than the verbose `Call \`run_task\` on <UUID> to start the task "Title".` form.
    private static func transcriptLine(for event: TimerEvent) -> String {
        let action = friendlyAction(from: event.instructions) ?? event.instructions
        switch event.kind {
        case .scheduled:
            let timeStr = event.scheduledFireAt.map(formatScheduledTime) ?? "(no time)"
            let recur = event.recurrenceDescription.map { " (\($0))" } ?? ""
            return "⏰ scheduled \(timeStr)\(recur) — \(action)"
        case .fired:
            let timeStr = event.scheduledFireAt.map(formatScheduledTime) ?? "(no time)"
            let coalesced = event.coalescedCount.map { " (+\($0 - 1) more)" } ?? ""
            return "⏰ fired \(timeStr)\(coalesced) — \(action)"
        case .cancelled:
            let label: String
            switch event.cancellationCause {
            case .replaced:        label = "rescheduled"
            case .taskTerminated:  label = "cancelled (task ended)"
            case .agentTerminated: label = "cancelled (agent ended)"
            case .userRequest, .none: label = "cancelled"
            }
            return "⏰ \(label) — \(action)"
        }
    }

    /// Parses the controlled `TaskActionKind.imperativeText` shape into `verb: "title"`.
    /// Returns `nil` for any imperative that doesn't match that shape (e.g. legacy
    /// `schedule_reminder` payloads still in persisted state), where the caller should
    /// fall back to the raw text.
    private static func friendlyAction(from imperative: String) -> String? {
        let verb = imperative.firstMatch(of: /`([a-z_]+)`/).map { String($0.output.1) }
        let title = imperative.firstMatch(of: /"([^"]+)"/).map { String($0.output.1) }
        guard let verb, let title else { return nil }
        return "\(verb): \"\(title)\""
    }

    /// Formats `date` as a short user-facing wake time. Drops the date when it's today,
    /// uses "Tomorrow" for the next day, and falls back to a short month/day label otherwise.
    private static func formatScheduledTime(_ date: Date) -> String {
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale.current
        timeFormatter.timeZone = TimeZone.current
        timeFormatter.dateFormat = "h:mm a"
        let timeStr = timeFormatter.string(from: date)

        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return timeStr
        }
        if calendar.isDateInTomorrow(date) {
            return "Tomorrow \(timeStr)"
        }
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale.current
        dateFormatter.timeZone = TimeZone.current
        dateFormatter.dateFormat = "MMM d, h:mm a"
        return dateFormatter.string(from: date)
    }

    private func persistTimerEvents(_ events: [TimerEvent]) {
        let writer = timerEventsWriter
        Task { await writer.enqueue(events) }
    }

    /// Handles one timer-lifecycle event: post a transcript line if the user has
    /// the Debug toggle on, then snapshot the wakes list to disk. Both side
    /// effects run sequentially on MainActor so the visible order matches the
    /// on-disk order (transcript line first, snapshot second).
    private func handleTimerEvent(_ event: TimerEvent) async {
        if shared.showTimerActivityInTranscript, let runtime {
            let line = Self.transcriptLine(for: event)
            var meta: [String: AnyCodable] = [
                "messageKind": .string("timer_activity"),
                "timerEventID": .string(event.id.uuidString),
                "timerEventKind": .string(event.kind.rawValue)
            ]
            if let taskID = event.taskID {
                meta["timerTaskID"] = .string(taskID.uuidString)
            }
            let channel = await runtime.channel
            await channel.post(ChannelMessage(
                sender: .system,
                content: line,
                metadata: meta
            ))
        }
        await snapshotAndPersistWakes()
    }

    /// Snapshots the runtime's current wake list and writes it to disk. Also refreshes the
    /// `activeTimers` published property so the View → Timers panel updates immediately.
    /// Called from the `onTimerEventForChannel` callback on every schedule/fire/cancel.
    private func snapshotAndPersistWakes() async {
        guard let runtime else { return }
        // Nil = no live Smith. A timer event racing a restart's teardown used to read the
        // wake list as [] here and TRUNCATE the on-disk file — permanently killing
        // recurring series before the replay filter ever saw them. Never persist a
        // snapshot taken while no Smith exists.
        guard let wakes = await runtime.currentScheduledWakes() else { return }
        activeTimers = wakes
        await scheduledWakesWriter.enqueue(wakes)
    }

    /// Sends user input (with any pending attachments) to Smith.
    func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingAttachments.isEmpty else { return }

        if pendingAttachments.isEmpty, text.lowercased() == "/clear" {
            inputText = ""
            await clearConversation()
            return
        }
        if pendingAttachments.isEmpty, text.lowercased() == "/compact" {
            inputText = ""
            await compactConversation()
            return
        }

        guard let runtime else { return }

        let attachments = pendingAttachments
        inputText = ""
        pendingAttachments = []

        if !text.isEmpty {
            if messageHistory.last != text {
                messageHistory.append(text)
            }
            if messageHistory.count > Self.maxMessageHistory {
                messageHistory.removeFirst(messageHistory.count - Self.maxMessageHistory)
            }
            historyIndex = -1
            historyStash = ""
            persistMessageHistory()
        }

        // Persist attachment bytes to disk BEFORE handing the message to the runtime. The
        // runtime enqueues a persisted pending-user-message that references these bytes by id
        // and lazy-loads them from disk at delivery; if the save were still in flight (or the
        // app were killed) the drain could resolve nothing. Saved concurrently, then awaited.
        if !attachments.isEmpty {
            await withTaskGroup(of: Void.self) { group in
                for attachment in attachments {
                    group.addTask { [persistenceManager, logger] in
                        do {
                            try await persistenceManager.saveAttachment(attachment)
                        } catch {
                            logger.error("Failed to save attachment \(attachment.filename): \(error)")
                        }
                    }
                }
            }
        }

        await runtime.sendUserMessage(text, attachments: attachments)
    }

    enum HistoryDirection { case up, down }

    @discardableResult
    func navigateHistory(_ direction: HistoryDirection) -> Bool {
        guard !messageHistory.isEmpty else { return false }
        switch direction {
        case .up:
            if historyIndex == -1 {
                historyStash = inputText
                historyIndex = messageHistory.count - 1
            } else if historyIndex > 0 {
                historyIndex -= 1
            } else {
                return false
            }
            inputText = messageHistory[historyIndex]
            return true
        case .down:
            guard historyIndex >= 0 else { return false }
            if historyIndex < messageHistory.count - 1 {
                historyIndex += 1
                inputText = messageHistory[historyIndex]
            } else {
                historyIndex = -1
                inputText = historyStash
                historyStash = ""
            }
            return true
        }
    }

    func sendDirectMessage(to role: AgentRole, text: String) async {
        guard let runtime else { return }
        await runtime.sendDirectMessage(to: role, text: text)
    }

    func updateSystemPrompt(for role: AgentRole, prompt: String) async {
        guard let runtime else { return }
        await runtime.updateSystemPrompt(for: role, prompt: prompt)
    }

    // MARK: - Task actions

    func archiveTask(id: UUID) async {
        guard let taskStore else { return }
        if let task = tasks.first(where: { $0.id == id }), !task.status.isInProgress {
            await runtime?.terminateTaskAgents(taskID: id)
        }
        let succeeded = await taskStore.archive(id: id)
        if !succeeded {
            taskActionError = "This task is in progress and cannot be archived."
        }
    }

    /// Tells Smith — via a user-directed channel message, the same path `retryTask` uses — that
    /// the user changed a task's state from the app UI. Without this, Smith's conversational
    /// context keeps treating a paused/stopped/deleted task as still in progress (it can't see
    /// deleted tasks via its tools, so its only knowledge is what it was last told), and it
    /// refuses to start new work. Capture the title BEFORE the mutation so a soft-deleted task
    /// (already gone from `tasks`) still names itself.
    private func notifySmithTaskStateChanged(taskID: UUID, title: String, message: String) async {
        await runtime?.sendDirectMessage(
            to: .smith,
            text: "[System notice — user action in the app] \(message) Task: \"\(title)\" (ID: \(taskID.uuidString)). No reply to the user is needed unless they ask about it."
        )
    }

    func deleteTask(id: UUID) async {
        guard let taskStore else { return }
        let task = tasks.first { $0.id == id }
        let title = task?.title ?? "(unknown)"
        if let task, !task.status.isInProgress {
            await runtime?.terminateTaskAgents(taskID: id)
        }
        let succeeded = await taskStore.softDelete(id: id)
        if succeeded {
            await notifySmithTaskStateChanged(taskID: id, title: title, message: "The user deleted this task. It is no longer active — do not work on it, wait for it, or treat it as in progress.")
        } else {
            taskActionError = "This task is in progress and cannot be deleted."
        }
    }

    func unarchiveTask(id: UUID) async {
        await taskStore?.unarchive(id: id)
    }

    func undeleteTask(id: UUID) async {
        await taskStore?.undelete(id: id)
    }

    func permanentlyDeleteTask(id: UUID) async {
        guard let taskStore else { return }
        // No Smith notification here: a permanently-deleted task was already soft-deleted (Smith
        // was notified then), so it's already out of Smith's working set.
        let succeeded = await taskStore.permanentlyDelete(id: id)
        if succeeded {
            // The task is gone for good — purge its summary from the semantic corpus so it can
            // never resurface in search (recently-deleted only *hides* the summary; this erases it).
            await shared.purgeTaskSummary(id: id)
        } else {
            taskActionError = "This task is in progress and cannot be permanently deleted."
        }
    }

    func updateTaskDescription(id: UUID, description: String) async {
        guard let taskStore else { return }
        let succeeded = await taskStore.updateDescription(id: id, description: description)
        if !succeeded {
            taskActionError = "This task can't be edited while it's running or awaiting review."
        }
    }

    func createManualTask(
        title: String,
        description: String,
        isTemplate: Bool,
        templateInputDefinitions: [TemplateInputDefinition],
        templateInstanceTitleTemplate: String?,
        acceptanceCriteria: [AcceptanceCriterion],
        steps: [TaskStep]
    ) async -> Bool {
        guard let taskStore else { return false }
        if isTemplate, let problem = TemplateInputValidation.validateDefinitions(templateInputDefinitions) {
            taskActionError = problem
            return false
        }
        if isTemplate,
           let titleTemplate = templateInstanceTitleTemplate?.trimmingCharacters(in: .whitespacesAndNewlines),
           !titleTemplate.isEmpty,
           let problem = TemplateStringRenderer.validate(titleTemplate, allowedNames: Set(templateInputDefinitions.map(\.name))) {
            taskActionError = problem
            return false
        }
        let task = await taskStore.addTask(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            isTemplate: isTemplate,
            templateInputDefinitions: isTemplate ? templateInputDefinitions : []
        )
        if isTemplate, let problem = await taskStore.setTemplateInstanceTitleTemplate(id: task.id, titleTemplate: templateInstanceTitleTemplate) {
            // The title template was validated above, so this is unreachable in practice — but a
            // half-built task left behind here would be a criteria-less, step-less orphan the user
            // never asked for, and the editor stays open so they'd likely create a second one.
            // Roll the creation back rather than leave that behind.
            _ = await taskStore.softDelete(id: task.id)
            taskActionError = problem
            return false
        }
        if !acceptanceCriteria.isEmpty {
            await taskStore.setAcceptanceCriteria(id: task.id, criteria: acceptanceCriteria)
        }
        if !steps.isEmpty {
            await taskStore.setSteps(id: task.id, steps: steps)
        }
        return true
    }

    func updateTaskDefinition(
        id: UUID,
        title: String,
        description: String,
        isTemplate: Bool,
        templateInputDefinitions: [TemplateInputDefinition],
        templateInstanceTitleTemplate: String?
    ) async -> Bool {
        guard let taskStore else { return false }
        if let problem = await taskStore.updateDefinition(
            id: id,
            title: title,
            description: description,
            isTemplate: isTemplate,
            templateInputDefinitions: templateInputDefinitions,
            templateInstanceTitleTemplate: templateInstanceTitleTemplate
        ) {
            taskActionError = problem
            return false
        }
        return true
    }

    /// Replaces a task's acceptance criteria from the task-detail editor. Gated to
    /// states where no worker or validator is actively consuming the contract; the
    /// store drops sticky verdicts for criteria that actually changed.
    @discardableResult
    func setTaskAcceptanceCriteria(id: UUID, criteria: [AcceptanceCriterion]) async -> Bool {
        guard let taskStore else { return false }
        guard let task = await taskStore.task(id: id), task.status.isValidationContractEditable else {
            taskActionError = "Acceptance criteria can't be edited while the task is running, validating, or completed."
            return false
        }
        await taskStore.setAcceptanceCriteria(id: id, criteria: criteria)
        return true
    }

    /// Replaces a task's step list from the task-detail editor (same gating). The user
    /// holds full authority over the plan — unlike the worker, edits here may delete
    /// steps outright rather than tombstoning them.
    @discardableResult
    func setTaskSteps(id: UUID, steps: [TaskStep]) async -> Bool {
        guard let taskStore else { return false }
        guard let task = await taskStore.task(id: id), task.status.isValidationContractEditable else {
            taskActionError = "Steps can't be edited while the task is running, validating, or completed."
            return false
        }
        await taskStore.setSteps(id: id, steps: steps)
        return true
    }

    func pauseTask(id: UUID) async {
        let slug = id.uuidString.prefix(8)
        let entry = Date()
        let title = tasks.first { $0.id == id }?.title ?? "(unknown)"
        stopLogger.notice("VM.pauseTask entry task=\(slug, privacy: .public)")
        await runtime?.terminateTaskAgents(taskID: id)
        let afterTerm = Date()
        stopLogger.notice("VM.pauseTask after terminateTaskAgents task=\(slug, privacy: .public) elapsedMs=\(Int(afterTerm.timeIntervalSince(entry) * 1000), privacy: .public)")
        // CAS: only pause a task that's actually working — if it finished (completed, escalated,
        // failed) in the click/iteration window, don't clobber that terminal status with .paused.
        guard await taskStore?.updateStatus(id: id, to: .paused, ifCurrentlyIn: [.running, .validating]) == true else {
            stopLogger.notice("VM.pauseTask task=\(slug, privacy: .public) not in a pausable state — skipped")
            return
        }
        await notifySmithTaskStateChanged(taskID: id, title: title, message: "The user paused this task. Brown has been stopped and is no longer working on it. Do not wait for it or treat it as in progress; the user may resume it later.")
        stopLogger.notice("VM.pauseTask exit task=\(slug, privacy: .public) totalMs=\(Int(Date().timeIntervalSince(entry) * 1000), privacy: .public)")
    }

    func stopTask(id: UUID) async {
        let slug = id.uuidString.prefix(8)
        let entry = Date()
        let title = tasks.first { $0.id == id }?.title ?? "(unknown)"
        stopLogger.notice("VM.stopTask entry task=\(slug, privacy: .public)")
        await runtime?.terminateTaskAgents(taskID: id)
        let afterTerm = Date()
        stopLogger.notice("VM.stopTask after terminateTaskAgents task=\(slug, privacy: .public) elapsedMs=\(Int(afterTerm.timeIntervalSince(entry) * 1000), privacy: .public)")
        // CAS: only interrupt a task that's actually working — don't clobber a terminal status
        // if it finished in the click window.
        guard await taskStore?.updateStatus(id: id, to: .interrupted, ifCurrentlyIn: [.running, .validating]) == true else {
            stopLogger.notice("VM.stopTask task=\(slug, privacy: .public) not in a stoppable state — skipped")
            return
        }
        await notifySmithTaskStateChanged(taskID: id, title: title, message: "The user stopped this task. Brown has been stopped and is no longer working on it. Do not wait for it or treat it as in progress.")
        stopLogger.notice("VM.stopTask exit task=\(slug, privacy: .public) totalMs=\(Int(Date().timeIntervalSince(entry) * 1000), privacy: .public)")
    }

    func retryTask(_ task: AgentTask) async {
        await taskStore?.softDelete(id: task.id)
        await sendDirectMessage(
            to: .smith,
            text: "Please retry this failed task:\nTitle: \(task.title)\nDescription: \(task.description)\nID: \(task.id.uuidString)"
        )
    }

    /// Pushes the current global tool-security settings to this session's runtime. Called on a
    /// Settings change (via the registered observer) so changes take effect without a session restart.
    private func pushToolSecurity() {
        let pre = shared.enablePreflightScoping
        let per = shared.enablePerToolCheck
        let pol = shared.globalToolPolicies
        Task { await runtime?.setToolSecurity(preflightScoping: pre, perCallCheck: per, globalPolicy: pol) }
    }

    /// Debounced trigger for a provider rebuild. A single model-field edit fires `updateAgentConfig`
    /// repeatedly (every field commits), so coalesce the burst into one rebuild ~400ms after editing
    /// settles — avoiding a `makeProvider`/keychain pass per keystroke. No-op when not running.
    private func scheduleProviderRefresh() {
        guard isRunning else { return }
        providerRefreshTask?.cancel()
        providerRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.pushUpdatedProviders()
        }
    }

    /// Rebuilds this session's per-role LLM providers from the current model assignments and pushes
    /// them to the live runtime, so a model swap in Settings takes effect on the next task (Brown and
    /// Security Agent re-read the providers at spawn; Smith/summarizer on the next runtime restart) without a
    /// session restart. A per-role build failure is logged and skipped — the runtime keeps that role's
    /// existing provider — so one misconfigured model can't break the others.
    /// Resolves a model's image/document injection capability from the catalog. When the model is
    /// ABSENT from the catalog we can't know: vision fails OPEN (images have no text fallback) and
    /// documents fail CLOSED (a wrong PDF block is a hard API 400; the agent reads the extracted
    /// text instead). That guess is never silent — the first time a given model is missing we log a
    /// warning AND surface a system line in the transcript pointing at the Capabilities editor, so a
    /// wrong assumption about our own data is visible rather than hidden.
    private func resolveInjectionCapabilities(providerID: String, modelID: String, roleLabel: String) -> (vision: Bool, documents: Bool) {
        let capabilities = shared.llmKit.modelInfo(providerID: providerID, modelID: modelID)?.capabilities
        if capabilities == nil {
            let key = "\(providerID)/\(modelID)"
            if capabilityCatalogMissNoticeShown.insert(key).inserted {
                let notice = "Model “\(modelID)” (\(roleLabel)) isn’t in the capability catalog — assuming vision=on, PDF=off. If that’s wrong, set it explicitly in the Capabilities editor."
                logger.warning("\(notice, privacy: .public)")
                appendLocalSystemMessage(notice)
            }
        }
        return (capabilities?.vision ?? true, capabilities?.pdfInput ?? false)
    }

    private func pushUpdatedProviders() async {
        guard isRunning, let runtime else { return }
        var providers: [AgentRole: any LLMProvider] = [:]
        var configurations: [AgentRole: ModelConfiguration] = [:]
        var apiTypes: [AgentRole: ProviderAPIType] = [:]
        var visionByRole: [AgentRole: Bool] = [:]
        var documentsByRole: [AgentRole: Bool] = [:]
        for role in AgentRole.allCases {
            guard let configID = agentAssignments[role] else { continue }
            do {
                providers[role] = try shared.llmKit.makeProvider(for: configID)
            } catch {
                logger.error("Provider refresh: failed to rebuild \(role.displayName, privacy: .public) provider: \(error.localizedDescription, privacy: .public)")
                continue
            }
            if let modelConfig = shared.llmKit.configurations.first(where: { $0.id == configID }) {
                configurations[role] = modelConfig
                if let modelProvider = shared.llmKit.providers.first(where: { $0.id == modelConfig.providerID }) {
                    apiTypes[role] = modelProvider.apiType
                }
                let resolved = resolveInjectionCapabilities(providerID: modelConfig.providerID, modelID: modelConfig.modelID, roleLabel: role.displayName)
                visionByRole[role] = resolved.vision
                documentsByRole[role] = resolved.documents
            }
        }
        await pushValidatorModel(to: runtime)
        guard !providers.isEmpty else { return }
        await runtime.setProviders(providers: providers, configurations: configurations, apiTypes: apiTypes, supportsVisionByRole: visionByRole, supportsDocumentsByRole: documentsByRole)
        logger.info("Refreshed LLM providers for roles: \(providers.keys.map(\.displayName).sorted().joined(separator: ", "), privacy: .public)")
    }

    /// Builds this session's dedicated validator-slot model from `validatorAssignment` and pushes
    /// it to the runtime, or clears the slot (falling back to the Summarizer's model) when no
    /// dedicated validator is assigned or its provider can't be built. Used at start and on a
    /// live model-assignment change.
    private func pushValidatorModel(to runtime: OrchestrationRuntime) async {
        guard let validatorConfigID = validatorAssignment,
              let validatorConfig = shared.llmKit.configurations.first(where: { $0.id == validatorConfigID }) else {
            await runtime.setValidatorModel(provider: nil, configuration: nil, apiType: nil)
            return
        }
        do {
            let provider = try shared.llmKit.makeProvider(for: validatorConfigID)
            let apiType = shared.llmKit.providers.first(where: { $0.id == validatorConfig.providerID })?.apiType
            let resolved = resolveInjectionCapabilities(providerID: validatorConfig.providerID, modelID: validatorConfig.modelID, roleLabel: "Validator")
            await runtime.setValidatorModel(provider: provider, configuration: validatorConfig, apiType: apiType, supportsVision: resolved.vision, supportsDocuments: resolved.documents)
        } catch {
            logger.error("Failed to build validator provider (\(error.localizedDescription, privacy: .public)); validation falls back to the Summarizer model")
            await runtime.setValidatorModel(provider: nil, configuration: nil, apiType: nil)
        }
    }

    /// Sets (or clears, with `enabled == nil`) a per-task user tool override from the task-detail UI.
    /// Routes through the live runtime so a running worker picks it up next turn; persists on the task
    /// either way. The override survives re-evaluation (the registry re-applies it after each scope).
    func setTaskToolOverride(taskID: UUID, tool: String, enabled: Bool?) {
        Task {
            if let runtime {
                await runtime.setTaskToolOverride(taskID: taskID, tool: tool, enabled: enabled)
            } else {
                await taskStore?.setUserToolOverride(id: taskID, tool: tool, enabled: enabled)
            }
        }
    }

    /// Bulk variant of `setTaskToolOverride` — applies one `enabled` value across many tools in a
    /// single write. Backs the per-MCP-server Auto/On/Off shortcut in the task-detail Tools editor.
    func setTaskToolOverrides(taskID: UUID, tools: [String], enabled: Bool?) {
        guard !tools.isEmpty else { return }
        Task {
            if let runtime {
                await runtime.setTaskToolOverrides(taskID: taskID, tools: tools, enabled: enabled)
            } else {
                await taskStore?.setUserToolOverrides(id: taskID, tools: tools, enabled: enabled)
            }
        }
    }

    /// "Run Again" from a completed task's context menu. Creates a brand-new, independent
    /// task rather than reopening the original — the completed task is preserved as-is. The
    /// message is phrased to override Smith's usual reuse bias (it would otherwise treat
    /// "run again" as a `run_task` on the existing id).
    func runTaskAgain(_ task: AgentTask) async {
        await sendDirectMessage(
            to: .smith,
            text: """
            The user chose "Run Again" on a completed task and wants a fresh, separate copy run from scratch. Call `create_task` with the title and description below. Do NOT reopen, reuse, or call `run_task` on any existing task — this must be a brand-new task.
            Title: \(task.title)
            Description: \(task.description)
            """
        )
    }

    // MARK: - Task overlay bar

    /// One column in the top-of-window task overlay bar. Order is append-only — a
    /// column's position never changes while it's visible (Drew's spec); removal only
    /// happens via dismiss, tear-off, or the first-completed eviction when a NEW task
    /// needs a slot.
    struct TaskOverlayEntry: Identifiable, Equatable {
        let id: UUID
        /// When every active step reached completed/skipped — starts the 5-second dwell
        /// before the column switches from the todo list to live acceptance criteria.
        var allStepsDoneAt: Date?
        /// Whether the column currently shows acceptance criteria instead of steps.
        var showsCriteria: Bool
    }

    var taskOverlayEntries: [TaskOverlayEntry] = []
    private var taskOverlayDismissedIDs: Set<UUID> = []
    /// Monotonic token so a scheduled dwell re-check that outlived a newer overlay
    /// update can't apply stale state.
    private var taskOverlayDwellGeneration = 0

    /// Recomputes the overlay from the current `tasks`. Called on every task-store
    /// change; cheap (pure array/set work over the active task list).
    func updateTaskOverlay() {
        // Only ACTIVE-disposition tasks belong in the bar — a task the user trashes or
        // archives mid-flight must drop its column, not haunt it (its record stays in
        // `tasks` with a non-active disposition, so presence alone isn't enough).
        let activeTasks = tasks.filter { $0.disposition == .active }
        let byID = Dictionary(activeTasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let inFlightStatuses: Set<AgentTask.Status> = [.starting, .running, .validating, .awaitingReview]

        // Drop entries whose task vanished (deleted/archived elsewhere).
        taskOverlayEntries.removeAll { byID[$0.id] == nil }

        // Append newly in-flight tasks (creation order), never re-adding dismissed ones.
        let present = Set(taskOverlayEntries.map(\.id))
        let barCapacity = max(1, shared.taskOverlayColumns)
        let newcomers = activeTasks
            .filter { inFlightStatuses.contains($0.status) && !present.contains($0.id) && !taskOverlayDismissedIDs.contains($0.id) }
            .sorted { $0.createdAt < $1.createdAt }
        for task in newcomers {
            // Bar full → evict the FIRST terminal column to free a slot. If nothing in
            // the bar is terminal, the newcomer simply lands in the junk drawer.
            if taskOverlayEntries.count >= barCapacity {
                let barSlice = taskOverlayEntries.prefix(barCapacity)
                if let evict = barSlice.first(where: { byID[$0.id]?.status.isTerminal ?? true }) {
                    taskOverlayEntries.removeAll { $0.id == evict.id }
                }
            }
            taskOverlayEntries.append(TaskOverlayEntry(id: task.id, allStepsDoneAt: nil, showsCriteria: false))
        }

        // Dwell + criteria handoff per entry.
        taskOverlayDwellGeneration &+= 1
        var needsDwellRecheck = false
        let now = Date()
        for index in taskOverlayEntries.indices {
            guard let task = byID[taskOverlayEntries[index].id] else { continue }
            let activeSteps = task.steps.filter(\.isActive)
            let allDone = !activeSteps.isEmpty && activeSteps.allSatisfy { $0.status == .completed || $0.status == .skipped }

            if task.status.isTerminal || activeSteps.isEmpty {
                // Failed/completed columns and step-less tasks show criteria directly.
                taskOverlayEntries[index].showsCriteria = true
            } else if allDone {
                if taskOverlayEntries[index].allStepsDoneAt == nil {
                    taskOverlayEntries[index].allStepsDoneAt = now
                }
                if let doneAt = taskOverlayEntries[index].allStepsDoneAt, now.timeIntervalSince(doneAt) >= 5 {
                    taskOverlayEntries[index].showsCriteria = true
                } else {
                    needsDwellRecheck = true
                }
            } else {
                // Steps churned back to unfinished — return to the todo view.
                taskOverlayEntries[index].allStepsDoneAt = nil
                taskOverlayEntries[index].showsCriteria = false
            }
        }
        if needsDwellRecheck {
            let generation = taskOverlayDwellGeneration
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5.1))
                guard let self, self.taskOverlayDwellGeneration == generation else { return }
                self.updateTaskOverlay()
            }
        }
    }

    /// Removes a column from the bar (the task itself is untouched). Sticky for the
    /// session — the task won't re-add itself.
    func dismissTaskOverlayEntry(taskID: UUID) {
        taskOverlayDismissedIDs.insert(taskID)
        taskOverlayEntries.removeAll { $0.id == taskID }
    }

    /// Tear-off: the caller opens the floating panel window; the bar column is removed
    /// (and won't re-add, same as dismiss).
    func tearOffTaskOverlayEntry(taskID: UUID) {
        dismissTaskOverlayEntry(taskID: taskID)
    }

    /// Manually starts (or resumes) a pending / paused / interrupted task without waiting for
    /// Smith to pick it up — drives the same `run_task` path the orchestrator uses. Refuses
    /// when every worker slot is taken, mirroring the `run_task` tool's capacity gate.
    func startTask(_ task: AgentTask, templateInputValues: [String: String] = [:]) async {
        guard task.status.isRunnable else {
            taskActionError = "This task can't be run right now (status: \(task.status.rawValue))."
            return
        }
        let slotHolders = tasks.filter {
            $0.id != task.id &&
            ($0.status == .starting || $0.status == .running || $0.status == .validating || $0.status == .awaitingReview)
        }
        let capacity = await runtime?.workerSlots().capacity ?? 1
        if slotHolders.count >= capacity {
            let names = slotHolders.prefix(3).map { "“\($0.title)”" }.joined(separator: ", ")
            taskActionError = "All \(capacity) task slot(s) are busy (\(names)). Wait for one to finish — or raise “Max simultaneous tasks” in Settings."
            return
        }
        await runtime?.restartForNewTask(taskID: task.id, templateInputValues: templateInputValues)
    }

    func updatePollInterval(for role: AgentRole, interval: TimeInterval) async {
        agentPollIntervals[role] = interval
        guard let runtime else { return }
        await runtime.updatePollInterval(for: role, interval: interval)
    }

    func updateMaxToolCalls(for role: AgentRole, count: Int) async {
        agentMaxToolCalls[role] = count
        guard let runtime else { return }
        await runtime.updateMaxToolCalls(for: role, count: count)
    }

    /// Escape-key action: PAUSE every actively-working task in this session — both `.running`
    /// (Brown executing) and `.validating` (a validator judging its result). The worker/parked
    /// Brown is cycled out and the task goes `.paused`; the user can resume later. Escape is a
    /// "hold on" gesture, not an emergency session shutdown — that's Stop, which marks tasks
    /// interrupted so a restart resumes them. Pause leaves them `.paused`, off the auto-resume
    /// path. `.awaitingReview` is deliberately excluded — nothing is running there to pause.
    func pauseAllRunningTasks() async {
        let activeIDs = tasks.filter { $0.status == .running || $0.status == .validating }.map(\.id)
        stopLogger.notice("VM.pauseAllRunningTasks entry — \(activeIDs.count, privacy: .public) active task(s)")
        guard !activeIDs.isEmpty else { return }
        for id in activeIDs {
            await pauseTask(id: id)
        }
        stopLogger.notice("VM.pauseAllRunningTasks exit")
    }

    /// Stops this session only. For app-wide Emergency Stop, SessionManager iterates all sessions.
    ///
    /// Does NOT call `shared.speechController.stopAll()` because the SpeechController is
    /// shared across sessions — stopping it would silence speech in other running tabs.
    /// Any in-progress utterance from this session's agents will finish naturally; no new
    /// utterances get queued after this point because the runtime has stopped.
    func stopAll() async {
        let entry = Date()
        stopLogger.notice("VM.stopAll entry session=\(self.session.name, privacy: .public)")
        guard let runtime else {
            stopLogger.notice("VM.stopAll no runtime — early return session=\(self.session.name, privacy: .public)")
            return
        }
        await runtime.stopAll()
        stopLogger.notice("VM.stopAll runtime.stopAll returned session=\(self.session.name, privacy: .public) elapsedMs=\(Int(Date().timeIntervalSince(entry) * 1000), privacy: .public)")
        isRunning = false
        processingRoles.removeAll()
        toolExecutingByRole.removeAll()
        agentToolNames.removeAll()
        inspectorStore.clearAll()
        clearCostCaches()
        // The channel stream is cancelled + awaited inside flushPersistence() below
        // (quiesceChannelStream), so any messages still buffered in the channel are drained
        // and persisted before we tear down rather than dropped here.
        self.runtime = nil

        if let store = taskStore {
            let liveTasks = await store.allTasks()
            for task in liveTasks where task.status == .running {
                await store.updateStatus(id: task.id, status: .interrupted)
            }
        }

        // Flush persistence synchronously here so callers can rely on no pending writes
        // racing whatever they do next (e.g. quitting the app, reading the session's files
        // for diagnostics). The hot-path persists during message streaming still use
        // detached tasks for performance; this is the quiescent, stop-of-world flush.
        await flushPersistence()
        await shared.usageStore.flush()
    }

    /// Drains every per-file writer so the on-disk state reflects in-memory
    /// state before `stopAll` returns. Each writer enforces FIFO write order
    /// internally; `flush()` waits until every previously-enqueued snapshot
    /// has hit disk. Also enqueues one final snapshot per file so the
    /// post-stop state (e.g., running tasks flipped to interrupted above) is
    /// captured in the final write.
    /// Drains all per-session writers to disk on app termination, regardless of whether the
    /// runtime is running. `stopAll()` early-returns when `runtime == nil`, so on a normal
    /// Cmd-Q the per-session flush would otherwise never run; this entry point lets the
    /// app-termination hook force the same drain unconditionally.
    public func flushForTermination() async {
        await flushPersistence()
        await shutdownMCP()
    }

    /// Posts a one-time system message to this session's transcript when a configured MCP
    /// server transitions into the failed state, so a load failure is visible without
    /// opening Settings. Re-arms if the server later recovers and fails again.
    private func announceMCPFailuresIfNeeded(_ statuses: [UUID: MCPServerStatus]) {
        guard let runtime else { return }
        for (id, status) in statuses {
            if status.state == .failed {
                guard !mcpAnnouncedFailures.contains(id) else { continue }
                mcpAnnouncedFailures.insert(id)
                let name = shared.mcpServers.first(where: { $0.id == id })?.name ?? "An MCP server"
                let reason = (status.error?.split(separator: "\n").first).map { " — \($0)" } ?? ""
                let content = "⚠️ MCP server “\(name)” failed to load\(reason). Open Settings → MCP Servers for the full error."
                Task {
                    let channel = await runtime.channel
                    await channel.post(ChannelMessage(
                        sender: .system,
                        content: content,
                        metadata: ["messageKind": .string("mcp_status"), "isWarning": .bool(true)]
                    ))
                }
            } else {
                mcpAnnouncedFailures.remove(id)
            }
        }
    }

    /// Terminates this session's MCP server subprocesses. Called on app termination;
    /// individual server disables are handled live via `SharedAppState.updateMCPServers`.
    func shutdownMCP() async {
        guard let host = mcpHost else { return }
        await host.shutdown()
        mcpHost = nil
    }

    /// Stops channel-log production and waits for the stream loop to fully exit, so that no
    /// message can be appended to `pendingChannelAppends` after this returns. Required before a
    /// final drain: `AppViewModel` is reentrant at every `await`, so a still-live stream could
    /// otherwise land a message in the pending buffer during `flushPersistence`'s later awaits
    /// and never get it drained before the app terminates. `MessageChannel.stream()` is an
    /// `AsyncStream`, so cancellation ends the `for await` and the task completes.
    private func quiesceChannelStream() async {
        guard let task = channelStreamTask else { return }
        task.cancel()
        await task.value
        channelStreamTask = nil
    }

    private func flushPersistence() async {
        // Quiesce message production first, then cancel the debounce so it can't fire a
        // redundant append after this authoritative flush; draining below hands any
        // un-persisted messages to the writer directly.
        await quiesceChannelStream()
        channelLogPersistTask?.cancel()
        channelLogPersistTask = nil
        await drainPendingChannelAppends()
        await tasksWriter.enqueue(tasks)
        let finalState = SessionState(
            agentAssignments: agentAssignments,
            agentPollIntervals: agentPollIntervals,
            agentMaxToolCalls: agentMaxToolCalls,
            agentMessageDebounceIntervals: agentMessageDebounceIntervals,
            toolsEnabled: toolsEnabled,
            autoRunNextTask: autoRunNextTask,
            autoRunInterruptedTasks: autoRunInterruptedTasks,
            validatorAssignment: validatorAssignment
        )
        logger.notice("flushPersistence: session=\(self.session.name, privacy: .public) writing autoRunNextTask=\(finalState.autoRunNextTask, privacy: .public) autoRunInterruptedTasks=\(finalState.autoRunInterruptedTasks, privacy: .public)")
        await sessionStateWriter.enqueue(finalState)
        if await channelLogAppendWriter.flush() == false {
            logger.error("flushPersistence: channel-log flush did NOT reach disk (disk full / permissions) — the trailing transcript batch was retained in memory only and is lost on exit.")
        }
        await tasksWriter.flush()
        await sessionStateWriter.flush()
        await timerEventsWriter.flush()
        await scheduledWakesWriter.flush()
    }

    func resetAbort() {
        isAborted = false
        abortReason = ""
    }

    /// Clears the visible channel transcript only — Ctrl-L. The on-disk JSONL log is untouched,
    /// so `restoreHistory()` (or a relaunch) can bring the lines back.
    ///
    /// Deliberately does NOT touch `inspectorStore` or the cost caches: those hold the
    /// running agents' turn records, live context, and security evaluations. Clearing them
    /// here tore down live state the user never asked to discard and left every agent card
    /// reading "Not active" while its agent was still running.
    func clearLog() {
        messages.removeAll()
        renderedToolRequestIDs.removeAll()
        // The full transcript is still on disk; re-offer the restore affordance.
        hasRestoredHistory = false
    }

    /// `/clear` and the toolbar trashcan: resets SMITH'S LLM CONTEXT (with a fresh
    /// task-state re-briefing) and starts a fresh screen. Distinct from Ctrl-L, which is
    /// display-only. Brown is untouched — clearing a worker mid-task would break the task.
    func clearConversation() async {
        clearLog()
        guard let runtime else {
            appendLocalSystemMessage("Screen cleared. System is not running, so there was no agent context to clear.")
            return
        }
        let result = await runtime.clearSmithContext()
        // Local append, NOT a channel post: agents must not receive this notice. Smith
        // learns about the clear from its orientation turn, and Brown mid-task has no
        // business hearing that Smith's context changed.
        appendLocalSystemMessage(result)
    }

    /// `/compact`: summarizes Smith's conversation and splices its context down to
    /// system prompt + summary + recent turns. The screen is left untouched.
    func compactConversation() async {
        guard let runtime else {
            appendLocalSystemMessage("System is not running — there is no agent context to compact.")
            return
        }
        let result = await runtime.compactSmithContext()
        // Local append for the same reason as clearConversation.
        appendLocalSystemMessage(result)
    }

    /// Surfaces a system line in the transcript when there's no runtime (and therefore no
    /// channel) to post through. Mirrors the channel-stream append path so the message
    /// also survives in the persisted history.
    private func appendLocalSystemMessage(_ content: String) {
        appendToTranscript(ChannelMessage(sender: .system, content: content))
    }

    /// Appends a message to the in-memory transcript and queues it for the on-disk JSONL log.
    /// Trims the resident tail back to `residentMessageCap` unless the user has pulled in the
    /// full history (then they've opted into holding everything until the next relaunch).
    private func appendToTranscript(_ message: ChannelMessage) {
        messages.append(message)
        if let rid = toolRequestID(of: message) { renderedToolRequestIDs.insert(rid) }
        persistedHistoryCount += 1
        if !hasRestoredHistory && messages.count > Self.residentMessageCap {
            let removeCount = messages.count - Self.residentMessageCap
            for trimmed in messages.prefix(removeCount) {
                if let rid = toolRequestID(of: trimmed) { renderedToolRequestIDs.remove(rid) }
            }
            messages.removeFirst(removeCount)
        }
        pendingChannelAppends.append(message)
        persistMessages()
    }

    /// Loads the full transcript from disk into memory. Trimming stays suspended afterward
    /// (`hasRestoredHistory`), so the whole history remains visible for the rest of the session.
    func restoreHistory() {
        guard !hasRestoredHistory else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let full = try await self.persistenceManager.loadFullChannelLog()
                // Read `messages` AFTER the await: messages that streamed in during the load are
                // now resident. `full` is the authoritative ordered history; any resident message
                // not yet on disk (a not-yet-flushed live append) is appended after it, deduped
                // by id so a message that flushed mid-load isn't duplicated.
                let fullIDs = Set(full.map(\.id))
                let liveTail = self.messages.filter { !fullIDs.contains($0.id) }
                self.messages = full + liveTail
                self.rebuildRenderedToolRequestIDs()
                self.persistedHistoryCount = self.messages.count
                self.hasRestoredHistory = true
            } catch {
                self.logger.error("Failed to restore full channel history: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Attachments

    func addAttachments(from urls: [URL]) {
        for url in urls {
            let didAccessScope = url.startAccessingSecurityScopedResource()
            defer {
                if didAccessScope { url.stopAccessingSecurityScopedResource() }
            }
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                logger.error("Failed to read attachment \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
            let mimeType = Self.mimeType(for: url)
            let attachment = Attachment(
                filename: url.lastPathComponent,
                mimeType: mimeType,
                byteCount: data.count,
                data: data
            )
            pendingAttachments.append(attachment)
        }
    }

    func removePendingAttachment(id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    func addAttachment(data: Data, filename: String, mimeType: String) {
        let attachment = Attachment(
            filename: filename,
            mimeType: mimeType,
            byteCount: data.count,
            data: data
        )
        pendingAttachments.append(attachment)
    }

    func pasteFromClipboard() -> Bool {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], !urls.isEmpty {
            addAttachments(from: urls)
            return true
        }
        if let tiffData = pasteboard.data(forType: .tiff),
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            addAttachment(
                data: pngData,
                filename: "Pasted Image \(Self.attachmentTimestamp()).png",
                mimeType: "image/png"
            )
            return true
        }
        return false
    }

    static func attachmentTimestamp() -> String {
        attachmentTimestampFormatter.string(from: Date())
    }

    private static let attachmentTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmmss"
        return f
    }()

    // MARK: - Configuration helpers (per-session)

    /// Resolves each agent role to its assigned ModelConfiguration, for inspector display.
    var resolvedAgentConfigs: [AgentRole: ModelConfiguration] {
        var result: [AgentRole: ModelConfiguration] = [:]
        for (role, configID) in agentAssignments {
            if let config = shared.llmKit.configurations.first(where: { $0.id == configID }) {
                result[role] = config
            }
        }
        return result
    }

    /// Whether all required agent roles in this session have valid assigned configurations.
    var allAgentConfigsValid: Bool {
        AgentRole.requiredRoles.allSatisfy { role in
            guard let configID = agentAssignments[role],
                  let config = shared.llmKit.configurations.first(where: { $0.id == configID }),
                  config.isValid else { return false }
            return true
        }
    }

    /// Clears any assignment in this session that references the deleted config ID.
    func clearAssignment(forConfigID id: UUID) {
        for (role, configID) in agentAssignments where configID == id {
            agentAssignments[role] = nil
        }
    }

    /// Returns a `ModelConfiguration` dedicated to this role within this session.
    ///
    /// Creates or clones as needed so edits to the returned config don't affect this session's
    /// other roles. Edits *may* affect roles in other sessions that point at the same config —
    /// the config catalog is global and sessions can intentionally share configs. Users wanting
    /// full isolation can duplicate the config via Settings → Configurations.
    @discardableResult
    func ensureDedicatedConfig(for role: AgentRole) -> ModelConfiguration {
        if let existingID = agentAssignments[role],
           let existing = shared.llmKit.configurations.first(where: { $0.id == existingID }) {
            let sharedWithinSession = agentAssignments.filter { $0.value == existingID && $0.key != role }
            if sharedWithinSession.isEmpty {
                return existing
            }
            var clone = existing
            clone.id = UUID()
            clone.name = "\(role.displayName) — \(existing.modelID)"
            shared.llmKit.addConfiguration(clone)
            agentAssignments[role] = clone.id
            return clone
        }

        let starter: ModelConfiguration
        if let firstProvider = shared.llmKit.providers.first {
            starter = ModelConfiguration(
                id: UUID(),
                name: "\(role.displayName) — \(firstProvider.name)",
                providerID: firstProvider.id,
                modelID: "",
                temperature: 0.7,
                maxOutputTokens: 4096,
                maxContextTokens: 128_000
            )
        } else {
            starter = ModelConfiguration(
                id: UUID(),
                name: "\(role.displayName)",
                providerID: "",
                modelID: ""
            )
        }
        shared.llmKit.addConfiguration(starter)
        agentAssignments[role] = starter.id
        return starter
    }

    // MARK: - Private

    private var sessionHistoryKey: String {
        "messageHistory.\(session.id.uuidString)"
    }

    private func persistMessageHistory() {
        do {
            let data = try JSONEncoder().encode(messageHistory)
            UserDefaults.standard.set(data, forKey: sessionHistoryKey)
        } catch {
            logger.error("Failed to encode message history: \(error)")
        }
    }

    private func persistMessages() {
        // Debounce: cancel any pending drain and schedule a fresh one. During a streaming burst
        // this batches many appends into one append-writer call once the stream goes quiet. The
        // authoritative final drain happens in flushPersistence(), which also cancels this task.
        channelLogPersistTask?.cancel()
        channelLogPersistTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.channelLogPersistDebounce)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            await self.drainPendingChannelAppends()
        }
    }

    /// Hands accumulated appends to the JSONL append writer in FIFO order. The read-and-clear
    /// runs synchronously on the main actor, so it can't interleave with another drain; awaiting
    /// the enqueue (rather than spawning a detached task) preserves batch ordering and lets
    /// `flushPersistence` guarantee everything is written before quit.
    private func drainPendingChannelAppends() async {
        guard !pendingChannelAppends.isEmpty else { return }
        let batch = pendingChannelAppends
        pendingChannelAppends = []
        await channelLogAppendWriter.enqueue(batch)
    }

    private func persistTasks() {
        let tasksToSave = tasks
        let writer = tasksWriter
        Task { await writer.enqueue(tasksToSave) }
    }

    /// Durably writes the given active-task snapshot to this session's `tasks.json` right now,
    /// returning whether it succeeded. Injected into `TaskStore` as its durable-active hook so a
    /// restore lands the task on disk before it's removed from the global inactive store.
    private func persistActiveTasksNow(_ snapshot: [AgentTask]) async -> Bool {
        do {
            try await persistenceManager.saveTasks(snapshot)
            return true
        } catch {
            logger.error("Failed to durably persist tasks.json: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Wires the crash-safe durable-move hooks onto a session `TaskStore`. Kept in one place so the
    /// initial standalone store and the live runtime store are wired identically.
    private func wireDurablePersistHooks(on store: TaskStore) async {
        await store.setDurablePersistHooks(
            inactive: { [weak self] in await self?.shared.persistInactiveTasksNow() ?? false },
            active: { [weak self] snapshot in await self?.persistActiveTasksNow(snapshot) ?? false }
        )
    }

    private func persistSessionStateAsync(callerFile: String = #fileID, callerLine: Int = #line, callerFunction: String = #function) {
        // Suppress all writes while loadPersistedState is applying values from
        // disk. The serializer would also coalesce these into one final write,
        // but skipping the enqueues entirely avoids dirtying the writer's
        // pending slot with intermediate snapshots that we know aren't real
        // user intent.
        guard !isApplyingPersistedState else {
            logger.debug("persistSessionStateAsync SUPPRESSED (applyingPersistedState) caller=\(callerFunction, privacy: .public)@\(callerFile, privacy: .public):\(callerLine, privacy: .public)")
            return
        }

        let state = SessionState(
            agentAssignments: agentAssignments,
            agentPollIntervals: agentPollIntervals,
            agentMaxToolCalls: agentMaxToolCalls,
            agentMessageDebounceIntervals: agentMessageDebounceIntervals,
            toolsEnabled: toolsEnabled,
            autoRunNextTask: autoRunNextTask,
            autoRunInterruptedTasks: autoRunInterruptedTasks,
            validatorAssignment: validatorAssignment
        )
        logger.notice("persistSessionStateAsync: session=\(self.session.name, privacy: .public) writing autoRunNextTask=\(state.autoRunNextTask, privacy: .public) autoRunInterruptedTasks=\(state.autoRunInterruptedTasks, privacy: .public) caller=\(callerFunction, privacy: .public)@\(callerFile, privacy: .public):\(callerLine, privacy: .public)")
        let writer = sessionStateWriter
        Task { await writer.enqueue(state) }
    }

    private static func mimeType(for url: URL) -> String {
        if let utType = UTType(filenameExtension: url.pathExtension) {
            return utType.preferredMIMEType ?? "application/octet-stream"
        }
        return "application/octet-stream"
    }

    // MARK: - Agent liveness

    /// Whether the runtime has an agent for `role` in this run — the signal behind the
    /// inspector's "Not active" badge and the grey/coloured role dot.
    ///
    /// Derived from runtime-owned state (registered tool names, recorded LLM turns, live
    /// conversation context) rather than the channel transcript. A card must keep reading
    /// Idle/Thinking after the user clears the transcript, and an agent that has been
    /// spawned but hasn't posted to the channel yet is still active.
    func hasAgentActivity(_ role: AgentRole) -> Bool {
        if !(agentToolNames[role] ?? []).isEmpty { return true }
        if !(inspectorStore.turnsByRole[role] ?? []).isEmpty { return true }
        return !inspectorStore.contextMessages(for: role).isEmpty
    }

    // MARK: - Cost helpers

    /// Estimated cost in USD for `role` over the **current session** (since the
    /// last `OrchestrationRuntime.start()`). Walks `inspectorStore.turnsByRole[role]`
    /// summing per-turn costs via the shared pricing snapshot. Memoized by turn
    /// count — subsequent reads return the cached value until a new turn arrives,
    /// so this is safe to call from a SwiftUI `body`.
    func sessionCost(for role: AgentRole) -> Double {
        // Caching by `turnsByRole[role].count` is unsafe — `AgentInspectorStore`
        // caps the array at 100 turns and drops the oldest when over, so a count
        // that stays at 100 hides changing contents. SwiftUI already gates the
        // surrounding card's body re-eval on `turnsByRole[role]` actually changing,
        // so a 100-iteration walk per change is cheap and always correct.
        let turns = inspectorStore.turnsByRole[role] ?? []
        let lookup = shared.pricingLookup
        var total: Double = 0
        for turn in turns {
            guard let usage = turn.usage else { continue }
            guard let pricing = lookup(turn.providerID, turn.modelID) else { continue }
            let rates = pricing.effectiveRates(totalInputTokens: usage.inputTokens)
            let uncachedInput = max(0, usage.inputTokens - usage.cacheReadTokens - usage.cacheWriteTokens)
            total += Double(uncachedInput) * (rates.input ?? 0)
            total += Double(usage.outputTokens) * (rates.output ?? 0)
            total += Double(usage.cacheReadTokens) * (rates.cacheRead ?? 0)
            total += Double(usage.cacheWriteTokens) * (rates.cacheWrite ?? 0)
        }
        return total
    }

    /// Returns the cached per-task cost if one is present, or `nil` if not yet fetched.
    /// SwiftUI rows call this synchronously to render their chip; if `nil`, they
    /// schedule `loadTaskCost(_:)` once to populate the cache.
    func cachedTaskCost(_ taskID: UUID) -> Double? {
        taskCostCache[taskID]
    }

    /// Loads and caches the total estimated cost for a single task by aggregating
    /// its `UsageRecord`s from the shared `UsageStore`. Safe to call multiple
    /// times for the same ID — concurrent calls collapse to a single fetch.
    ///
    /// Pass `force: true` to evict the existing cache entry before refetching.
    /// Use that on the `.running → .completed` transition so the detail view
    /// doesn't get stuck on a partial cost computed mid-run.
    func loadTaskCost(_ taskID: UUID, force: Bool = false) async {
        if force {
            taskCostCache.removeValue(forKey: taskID)
        } else if taskCostCache[taskID] != nil {
            return
        }
        if taskCostInFlight.contains(taskID) { return }
        taskCostInFlight.insert(taskID)
        let records = await shared.usageStore.records(for: taskID)
        taskCostCache[taskID] = estimatedCost(from: records)
        taskCostInFlight.remove(taskID)
    }

    /// Estimates the total cost of a set of usage records using current pricing.
    /// Shared by `loadTaskCost(_:force:)` and the PDF exporter so the two never diverge,
    /// and so the exporter can compute directly from a fresh fetch (bypassing the
    /// in-flight-guarded cache, which can early-return before it's populated).
    func estimatedCost(from records: [UsageRecord]) -> Double {
        let lookup = shared.pricingLookup
        var total: Double = 0
        for r in records {
            guard let pricing = lookup(r.providerID, r.modelID) else { continue }
            let rates = pricing.effectiveRates(totalInputTokens: r.inputTokens)
            let uncachedInput = max(0, r.inputTokens - r.cacheReadTokens - r.cacheWriteTokens)
            total += Double(uncachedInput) * (rates.input ?? 0)
            total += Double(r.outputTokens) * (rates.output ?? 0)
            total += Double(r.cacheReadTokens) * (rates.cacheRead ?? 0)
            total += Double(r.cacheWriteTokens) * (rates.cacheWrite ?? 0)
        }
        return total
    }

    /// Returns cached total token counts (input / output / cacheRead / cacheWrite)
    /// for a task — used by the task detail view alongside cost. Same caching
    /// model as `cachedTaskCost(_:)`: populated by `loadTaskTokens(_:)`.
    struct TaskTokenTotals: Equatable {
        var input: Int = 0
        var output: Int = 0
        var cacheRead: Int = 0
        var cacheWrite: Int = 0

        /// Grand total across all four buckets — used to decide whether the task has any
        /// recorded token activity worth displaying.
        var total: Int { input + output + cacheRead + cacheWrite }

        /// Compact "12,345 in   6,789 out   1,234 cached" line. Cache-write is folded into
        /// "cached" since only Anthropic reports it separately and the distinction is rarely
        /// meaningful at the task summary level. Shared by the detail view and the PDF.
        func formattedLine() -> String {
            let cached = cacheRead + cacheWrite
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            let nIn = formatter.string(from: NSNumber(value: input)) ?? "\(input)"
            let nOut = formatter.string(from: NSNumber(value: output)) ?? "\(output)"
            let nCached = formatter.string(from: NSNumber(value: cached)) ?? "\(cached)"
            if cached > 0 {
                return "\(nIn) in   \(nOut) out   \(nCached) cached"
            }
            return "\(nIn) in   \(nOut) out"
        }
    }
    private var taskTokenCache: [UUID: TaskTokenTotals] = [:]

    /// Sums token counts across a set of usage records. Shared by `loadTaskTokens(_:force:)`
    /// and the PDF exporter (see `estimatedCost(from:)` for the rationale).
    func tokenTotals(from records: [UsageRecord]) -> TaskTokenTotals {
        var totals = TaskTokenTotals()
        for r in records {
            totals.input += r.inputTokens
            totals.output += r.outputTokens
            totals.cacheRead += r.cacheReadTokens
            totals.cacheWrite += r.cacheWriteTokens
        }
        return totals
    }

    func cachedTaskTokens(_ taskID: UUID) -> TaskTokenTotals? {
        taskTokenCache[taskID]
    }

    /// Same caching model as `loadTaskCost(_:force:)`. Pass `force: true` to
    /// drop a stale partial computed while the task was still running.
    func loadTaskTokens(_ taskID: UUID, force: Bool = false) async {
        if force {
            taskTokenCache.removeValue(forKey: taskID)
        } else if taskTokenCache[taskID] != nil {
            return
        }
        let records = await shared.usageStore.records(for: taskID)
        taskTokenCache[taskID] = tokenTotals(from: records)
    }

    /// Clears the per-task cost / token caches. Called from the same reset paths
    /// that clear `inspectorStore` (session stop, abort, clear-log) so a subsequent
    /// open of the same task ID refetches from the (possibly cleared) `UsageStore`.
    func clearCostCaches() {
        taskCostCache.removeAll(keepingCapacity: true)
        taskCostInFlight.removeAll(keepingCapacity: true)
        taskTokenCache.removeAll(keepingCapacity: true)
    }
}
