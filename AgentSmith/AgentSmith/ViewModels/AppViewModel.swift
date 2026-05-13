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

    /// Derived channel-log lookups, rebuilt from `messages` on every channel-log mutation
    /// (append, restore, clear). `ChannelLogView` reads these instead of re-scanning the
    /// whole `messages` array inside `body`. See `rebuildChannelLogIndexes()`.
    /// Set of requestIDs that have a corresponding `tool_request` message.
    private(set) var toolRequestIDs: Set<String> = []
    /// requestID → security-review message (last writer wins).
    private(set) var securityReviewByRequestID: [String: ChannelMessage] = [:]
    /// requestID → tool-output message (last writer wins).
    private(set) var toolOutputByRequestID: [String: ChannelMessage] = [:]
    /// taskIDs whose paired `timer_activity` "scheduled" row should be suppressed because a
    /// `task_created` / `task_action_scheduled` banner already carries the schedule chip.
    private(set) var taskIDsWithSchedulingBanner: Set<String> = []

    var tasks: [AgentTask] = [] {
        didSet { rebucketTasks() }
    }
    /// Pre-bucketed view of `tasks` for the sidebar. Maintained by `rebucketTasks()`
    /// so the sidebar's body never re-runs three filters per render.
    private(set) var activeTaskList: [AgentTask] = []
    private(set) var archivedTaskList: [AgentTask] = []
    private(set) var recentlyDeletedTaskList: [AgentTask] = []
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
    /// Whether interrupted tasks are automatically resumed on launch.
    var autoRunInterruptedTasks: Bool = false {
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

    /// Splits `tasks` into the three sidebar buckets in a single pass. Called from
    /// the `tasks` didSet so the sidebar's body never re-runs three filters per render.
    private func rebucketTasks() {
        var active: [AgentTask] = []
        var archived: [AgentTask] = []
        var deleted: [AgentTask] = []
        active.reserveCapacity(tasks.count)
        for task in tasks {
            switch task.disposition {
            case .active: active.append(task)
            case .archived: archived.append(task)
            case .recentlyDeleted: deleted.append(task)
            }
        }
        activeTaskList = active
        archivedTaskList = archived
        recentlyDeletedTaskList = deleted
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

    /// Rebuilds the derived channel-log lookups from `messages` in a single pass. Iterating
    /// in array order means the *newest* message wins for the last-writer-wins dictionaries
    /// (relevant after `restoreHistory()` prepends older messages). Call after any mutation
    /// of `messages`.
    private func rebuildChannelLogIndexes() {
        func metaString(_ message: ChannelMessage, _ key: String) -> String? {
            if case .string(let value) = message.metadata?[key] { return value }
            return nil
        }
        var requestIDs = Set<String>()
        var reviews: [String: ChannelMessage] = [:]
        var outputs: [String: ChannelMessage] = [:]
        var bannerTasks = Set<String>()
        for message in messages {
            let kind = metaString(message, "messageKind")
            let requestID = metaString(message, "requestID")
            if kind == "tool_request", let requestID { requestIDs.insert(requestID) }
            if message.metadata?["securityDisposition"] != nil, let requestID { reviews[requestID] = message }
            if kind == "tool_output", let requestID { outputs[requestID] = message }
            if kind == "task_created" || kind == "task_action_scheduled", let taskID = metaString(message, "taskID") {
                bannerTasks.insert(taskID)
            }
        }
        toolRequestIDs = requestIDs
        securityReviewByRequestID = reviews
        toolOutputByRequestID = outputs
        taskIDsWithSchedulingBanner = bannerTasks
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
        .smith: 20, .brown: 25, .jones: 13
    ] {
        didSet { persistSessionStateAsync() }
    }
    /// Per-session maximum tool calls per LLM response for each agent role.
    var agentMaxToolCalls: [AgentRole: Int] = [
        .smith: 100, .brown: 100, .jones: 100
    ] {
        didSet { persistSessionStateAsync() }
    }
    /// Per-session message debounce intervals for each agent role (seconds).
    var agentMessageDebounceIntervals: [AgentRole: TimeInterval] = [
        .smith: 1, .brown: 1, .jones: 1
    ] {
        didSet { persistSessionStateAsync() }
    }
    /// Per-session: maps each agent role to a `ModelConfiguration.id`.
    var agentAssignments: [AgentRole: UUID] = [:] {
        didSet { persistSessionStateAsync() }
    }
    /// Per-session tool allowlist. Missing/true = enabled. Currently no UI; data model only.
    var toolsEnabled: [String: Bool] = [:] {
        didSet { persistSessionStateAsync() }
    }

    private let logger = Logger(subsystem: "com.agentsmith", category: "AppViewModel")
    private let stopLogger = Logger(subsystem: "com.agentsmith", category: "Stop")
    private var runtime: OrchestrationRuntime?
    /// Kept alive independently of `runtime` so task operations work even when agents aren't running.
    private var taskStore: TaskStore?
    private var channelStreamTask: Task<Void, Never>?
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

    /// Full message history — a superset of `messages`. Never cleared; always written to disk.
    private var allPersistedMessages: [ChannelMessage] = []

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
    private let channelLogWriter: SerialPersistenceWriter<[ChannelMessage]>
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
        self.channelLogWriter = SerialPersistenceWriter(label: "channelLog") { snapshot in
            try await pm.saveChannelLog(snapshot)
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
            } else {
                logger.notice("loadPersistedState: session=\(self.session.name, privacy: .public) no state on disk — using defaults autoRunNextTask=true autoRunInterruptedTasks=false")
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
            var savedMessages = try await persistenceManager.loadChannelLog()
            // One-time migration: strip file_write diff metadata. See previous implementation
            // for rationale — this was a data-format cleanup that's idempotent on rerun.
            var strippedCount = 0
            for i in savedMessages.indices {
                guard var md = savedMessages[i].metadata else { continue }
                var changed = false
                if md.removeValue(forKey: "fileWriteOldContent") != nil { changed = true }
                if md.removeValue(forKey: "fileWriteContent") != nil { changed = true }
                if changed {
                    savedMessages[i].metadata = md
                    strippedCount += 1
                }
            }
            if strippedCount > 0 {
                logger.notice("Stripped stale file_write diff metadata from \(strippedCount, privacy: .public) message(s) in session \(self.session.name, privacy: .public); re-saving channel log.")
                do {
                    try await persistenceManager.saveChannelLog(savedMessages)
                } catch {
                    logger.error("Failed to re-save channel log after migration: \(error)")
                }
            }
            allPersistedMessages = savedMessages
            persistedHistoryCount = savedMessages.count
        } catch {
            let msg = "Failed to load channel log: \(error)"
            logger.error("\(msg, privacy: .public)")
            shared.startupError = msg
        }

        // Load tasks with status corrections.
        do {
            var savedTasks = try await persistenceManager.loadTasks()
            var anyStatusChanged = false
            for i in savedTasks.indices {
                if savedTasks[i].status == .running {
                    savedTasks[i].status = .interrupted
                    savedTasks[i].updatedAt = Date()
                    anyStatusChanged = true
                }
            }
            let cutoff = Date().addingTimeInterval(-4 * 3600)
            var anyArchived = false
            for i in savedTasks.indices {
                if savedTasks[i].status == .completed,
                   savedTasks[i].disposition == .active,
                   savedTasks[i].updatedAt < cutoff {
                    savedTasks[i].disposition = .archived
                    anyArchived = true
                }
            }
            tasks = savedTasks
            if anyArchived || anyStatusChanged { persistTasks() }

            let standaloneStore = TaskStore()
            taskStore = standaloneStore
            await standaloneStore.restore(savedTasks)
            await standaloneStore.setOnChange { [weak self, weak standaloneStore] in
                Task { @MainActor [weak self, weak standaloneStore] in
                    guard let self, let store = standaloneStore else { return }
                    let allTasks = await store.allTasks()
                    self.tasks = allTasks
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

        let newRuntime = OrchestrationRuntime(
            providers: providers,
            configurations: configurations,
            providerAPITypes: apiTypes,
            agentTuning: tuning,
            semanticSearchEngine: engine,
            usageStore: shared.usageStore,
            autoAdvanceEnabled: autoRunNextTask,
            autoRunInterruptedTasks: autoRunInterruptedTasks,
            memoryStore: sharedMemoryStore
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
        channelStreamTask = Task { @MainActor [weak self] in
            for await message in channel.stream() {
                guard let self else { break }
                self.messages.append(message)
                self.rebuildChannelLogIndexes()
                self.allPersistedMessages.append(message)
                self.shared.speechController.handle(message)
                self.persistMessages()
            }
        }

        let liveTaskStore = await newRuntime.taskStore
        self.taskStore = liveTaskStore
        await liveTaskStore.setOnChange { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let allTasks = await liveTaskStore.allTasks()
                self.tasks = allTasks
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
                let snapshot = await log.allEvents()
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
        activeTimers = await runtime.currentScheduledWakes()
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
        let wakes = await runtime.currentScheduledWakes()
        activeTimers = wakes
        await scheduledWakesWriter.enqueue(wakes)
    }

    /// Sends user input (with any pending attachments) to Smith.
    func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingAttachments.isEmpty else { return }

        if pendingAttachments.isEmpty, text.lowercased() == "/clear" {
            inputText = ""
            clearLog()
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

        for attachment in attachments {
            Task.detached { [persistenceManager, logger] in
                do {
                    try await persistenceManager.saveAttachment(attachment)
                } catch {
                    logger.error("Failed to save attachment \(attachment.filename): \(error)")
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
        let succeeded = await taskStore.archive(id: id)
        if !succeeded {
            taskActionError = "This task is in progress and cannot be archived."
        }
    }

    func deleteTask(id: UUID) async {
        guard let taskStore else { return }
        let succeeded = await taskStore.softDelete(id: id)
        if !succeeded {
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
        let succeeded = await taskStore.permanentlyDelete(id: id)
        if !succeeded {
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

    func pauseTask(id: UUID) async {
        let slug = id.uuidString.prefix(8)
        let entry = Date()
        stopLogger.notice("VM.pauseTask entry task=\(slug, privacy: .public)")
        await runtime?.terminateTaskAgents(taskID: id)
        let afterTerm = Date()
        stopLogger.notice("VM.pauseTask after terminateTaskAgents task=\(slug, privacy: .public) elapsedMs=\(Int(afterTerm.timeIntervalSince(entry) * 1000), privacy: .public)")
        await taskStore?.pause(id: id)
        stopLogger.notice("VM.pauseTask exit task=\(slug, privacy: .public) totalMs=\(Int(Date().timeIntervalSince(entry) * 1000), privacy: .public)")
    }

    func stopTask(id: UUID) async {
        let slug = id.uuidString.prefix(8)
        let entry = Date()
        stopLogger.notice("VM.stopTask entry task=\(slug, privacy: .public)")
        await runtime?.terminateTaskAgents(taskID: id)
        let afterTerm = Date()
        stopLogger.notice("VM.stopTask after terminateTaskAgents task=\(slug, privacy: .public) elapsedMs=\(Int(afterTerm.timeIntervalSince(entry) * 1000), privacy: .public)")
        await taskStore?.stop(id: id)
        stopLogger.notice("VM.stopTask exit task=\(slug, privacy: .public) totalMs=\(Int(Date().timeIntervalSince(entry) * 1000), privacy: .public)")
    }

    func retryTask(_ task: AgentTask) async {
        await taskStore?.softDelete(id: task.id)
        await sendDirectMessage(
            to: .smith,
            text: "Please retry this failed task:\nTitle: \(task.title)\nDescription: \(task.description)\nID: \(task.id.uuidString)"
        )
    }

    func runTaskAgain(_ task: AgentTask) async {
        await taskStore?.archive(id: task.id)
        await sendDirectMessage(
            to: .smith,
            text: "Please run this task again:\nTitle: \(task.title)\nDescription: \(task.description)\nID: \(task.id.uuidString)"
        )
    }

    /// Manually starts (or resumes) a pending / paused / interrupted task without waiting for
    /// Smith to pick it up — drives the same `run_task` path the orchestrator uses. Refuses
    /// when another task is mid-run or awaiting review, mirroring the `run_task` tool's guardrails.
    func startTask(_ task: AgentTask) async {
        guard task.status.isRunnable else {
            taskActionError = "This task can't be run right now (status: \(task.status.rawValue))."
            return
        }
        if let blocker = tasks.first(where: { $0.id != task.id && ($0.status == .running || $0.status == .awaitingReview) }) {
            taskActionError = blocker.status == .running
                ? "Task “\(blocker.title)” is still running. Stop it before starting another task."
                : "Task “\(blocker.title)” is awaiting review. Resolve it before starting another task."
            return
        }
        await runtime?.restartForNewTask(taskID: task.id)
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

    func stopCurrentTask() async {
        stopLogger.notice("VM.stopCurrentTask entry")
        guard let runningTask = tasks.first(where: { $0.status == .running }) else {
            stopLogger.notice("VM.stopCurrentTask no running task — early return")
            return
        }
        stopLogger.notice("VM.stopCurrentTask found running task=\(runningTask.id.uuidString.prefix(8), privacy: .public)")
        await stopTask(id: runningTask.id)
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
        channelStreamTask?.cancel()
        channelStreamTask = nil
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
    private func flushPersistence() async {
        await channelLogWriter.enqueue(allPersistedMessages)
        await tasksWriter.enqueue(tasks)
        let finalState = SessionState(
            agentAssignments: agentAssignments,
            agentPollIntervals: agentPollIntervals,
            agentMaxToolCalls: agentMaxToolCalls,
            agentMessageDebounceIntervals: agentMessageDebounceIntervals,
            toolsEnabled: toolsEnabled,
            autoRunNextTask: autoRunNextTask,
            autoRunInterruptedTasks: autoRunInterruptedTasks
        )
        logger.notice("flushPersistence: session=\(self.session.name, privacy: .public) writing autoRunNextTask=\(finalState.autoRunNextTask, privacy: .public) autoRunInterruptedTasks=\(finalState.autoRunInterruptedTasks, privacy: .public)")
        await sessionStateWriter.enqueue(finalState)
        await channelLogWriter.flush()
        await tasksWriter.flush()
        await sessionStateWriter.flush()
        await timerEventsWriter.flush()
        await scheduledWakesWriter.flush()
    }

    func resetAbort() {
        isAborted = false
        abortReason = ""
    }

    func clearLog() {
        messages.removeAll()
        rebuildChannelLogIndexes()
        inspectorStore.clearAll()
        clearCostCaches()
    }

    func restoreHistory() {
        let currentIDs = Set(messages.map(\.id))
        let restoredHistory = allPersistedMessages.filter { !currentIDs.contains($0.id) }
        messages = restoredHistory + messages
        rebuildChannelLogIndexes()
        hasRestoredHistory = true
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
        let snapshot = allPersistedMessages
        let writer = channelLogWriter
        Task { await writer.enqueue(snapshot) }
    }

    private func persistTasks() {
        let tasksToSave = tasks
        let writer = tasksWriter
        Task { await writer.enqueue(tasksToSave) }
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
            autoRunInterruptedTasks: autoRunInterruptedTasks
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
    func loadTaskCost(_ taskID: UUID) async {
        if taskCostCache[taskID] != nil { return }
        if taskCostInFlight.contains(taskID) { return }
        taskCostInFlight.insert(taskID)
        let records = await shared.usageStore.records(for: taskID)
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
        taskCostCache[taskID] = total
        taskCostInFlight.remove(taskID)
    }

    /// Returns cached total token counts (input / output / cacheRead / cacheWrite)
    /// for a task — used by the task detail view alongside cost. Same caching
    /// model as `cachedTaskCost(_:)`: populated by `loadTaskTokens(_:)`.
    struct TaskTokenTotals: Equatable {
        var input: Int = 0
        var output: Int = 0
        var cacheRead: Int = 0
        var cacheWrite: Int = 0
    }
    private var taskTokenCache: [UUID: TaskTokenTotals] = [:]

    func cachedTaskTokens(_ taskID: UUID) -> TaskTokenTotals? {
        taskTokenCache[taskID]
    }

    func loadTaskTokens(_ taskID: UUID) async {
        if taskTokenCache[taskID] != nil { return }
        let records = await shared.usageStore.records(for: taskID)
        var totals = TaskTokenTotals()
        for r in records {
            totals.input += r.inputTokens
            totals.output += r.outputTokens
            totals.cacheRead += r.cacheReadTokens
            totals.cacheWrite += r.cacheWriteTokens
        }
        taskTokenCache[taskID] = totals
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
