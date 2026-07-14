import Foundation
import SemanticSearch
import Synchronization
import os

private let stopLogger = Logger(subsystem: "com.agentsmith", category: "Stop")

/// Cached date formatters for status/digest lines. `DateFormatter` is expensive to
/// construct, so we build these once instead of per status fire. Safe to share: each is
/// configured at init and never mutated afterward, so concurrent `string(from:)` is fine.
private enum RuntimeDateFormatters {
    static let timestamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

/// Thread-safe set for tracking files read during an agent session.
/// Used by FileEditTool to verify a file was read before editing.
///
/// Backed by Swift's `Mutex` (Synchronization). Replaces the prior `NSLock`
/// implementation per the L4 rule "Avoid NSLock; Mutex / serial DispatchQueue
/// are generally better."
final class FileReadTracker: Sendable {
    private let paths = Mutex<Set<String>>([])

    func record(_ path: String) {
        paths.withLock { _ = $0.insert(path) }
    }

    func contains(_ path: String) -> Bool {
        paths.withLock { $0.contains(path) }
    }
}

/// Top-level runtime that owns all agents, the channel, and the task store.
public actor OrchestrationRuntime {
    public let channel: MessageChannel
    public let taskStore: TaskStore
    public let memoryStore: MemoryStore

    /// Fixed UUID representing the human user for private Smith→User messages
    /// (`00000000-0000-0000-0000-000000000001`).
    public static let userID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))

    /// Single owner of agent-lifecycle state: handles, generations, epochs. Every piece of
    /// "which agents exist" data lives here and ONLY here — see `AgentSupervisor` for why
    /// it is a runtime-confined value rather than a separate actor. The properties below
    /// (`smith`, `smithID`) are read-only views over it; storing copies alongside it is
    /// how registries drift apart and zombies are born. Workers (Brown) are a POOL —
    /// look them up per task (`liveWorkerHandle(for:)`) or as `handles(role: .brown)`,
    /// never through a "the Brown" convenience.
    var supervisor = AgentSupervisor()

    private var smith: AgentActor? { supervisor.firstHandle(role: .smith)?.agent }
    private var smithID: UUID? { supervisor.firstHandle(role: .smith)?.id }
    /// Global tool-security configuration (user Settings); applied to each Brown at spawn.
    /// `preflightScopingEnabled` gates the Security Agent pre-flight scoping pass; `perCallCheckEnabled`
    /// gates the per-tool-call Security Agent evaluation; `globalToolPolicy` is the per-tool Always/Never map.
    private var preflightScopingEnabled = true
    private var perCallCheckEnabled = true
    private var globalToolPolicy: [String: ToolPolicy] = [:]

    /// Set synchronously at the top of `start()` (before its first `await`) and cleared via
    /// `defer`. `smith` isn't assigned until ~190 lines and several suspension points into
    /// `start()`, so `guard smith == nil` alone lets a second concurrently-admitted `start()`
    /// (e.g. a direct cold-launch racing a queued restart) slip through and build a duplicate
    /// Smith / monitoring timer / power assertion, orphaning the first. This flag closes that
    /// window within actor isolation.
    private var startInProgress = false

    /// Archived snapshots of terminated agents, keyed by role for latest-wins semantics.
    private var terminatedAgentArchive: [AgentRole: AgentArchiveEntry] = [:]

    /// Preserved evaluation records from terminated Browns, for inspector display.
    /// (Live evaluators ride on the supervisor's `AgentHandle`s.)
    private var archivedEvaluationRecords: [UUID: [EvaluationRecord]] = [:]

    /// Summarizer for generating task summaries after completion/failure.
    private var taskSummarizer: TaskSummarizer?

    var llmProviders: [AgentRole: any LLMProvider]
    var llmConfigs: [AgentRole: ModelConfiguration]
    var providerAPITypes: [AgentRole: ProviderAPIType]
    private var agentTuning: [AgentRole: AgentTuningConfig]
    /// Whether Smith should automatically run the next pending task after completing one.
    /// Mutable so the user can toggle it at runtime via `setAutoAdvance(_:)`.
    public private(set) var autoAdvanceEnabled: Bool
    /// Whether interrupted tasks should be auto-resumed on launch.
    private let autoRunInterruptedTasks: Bool
    /// Persistent token usage tracking across all agents.
    public let usageStore: UsageStore
    /// Append-only log of timer lifecycle events. Populated from `AgentActor`'s timer
    /// callbacks; surfaced in the View → Timers history pane.
    public let timerEventLog: TimerEventLog
    private var monitoringTimer: MonitoringTimer?
    private var powerManager: PowerAssertionManager?

    /// Identifier for the current contiguous run of the runtime — the supervisor's
    /// current generation. Minted by `beginGeneration()` in `start()`, cleared by
    /// `endGeneration()` in `stopAll()`. Stamped on every UsageRecord and ChannelMessage
    /// produced during the run so queries can group by session without having to join
    /// timestamps to a separate session log.
    public var currentSessionID: UUID? { supervisor.currentGeneration?.sessionID }

    /// Set by Security Agent abort — prevents restart until user clears it.
    private(set) var aborted = false
    /// Raised by the public `stopAll()` OUTSIDE the queue (mirroring `aborted`) so an
    /// in-flight lifecycle transition bails at its next barrier instead of running to
    /// completion, then consumed by the `performStopAll` that answers it. Without this, a
    /// user Stop was head-of-line blocked behind a start stuck in a slow scoping call
    /// (flagged independently by all three reviews).
    var stopRequested = false
    /// Callback to notify the app layer when abort is triggered.
    private var onAbort: (@Sendable (String) -> Void)?
    /// Callback to notify the app layer when an agent starts or stops an LLM call.
    private var onProcessingStateChange: (@Sendable (AgentRole, Bool) -> Void)?
    /// Callback to notify the app layer when an agent starts or stops executing a tool.
    /// Distinct from `onProcessingStateChange` (LLM call) — fires for the tool-execution
    /// span, which can be much longer (e.g. a slow AppleScript) and otherwise leaves the
    /// UI showing the agent as "Idle" while it's actually blocked waiting on a tool to
    /// return. The `String` parameter is the tool's name; `Bool` is `true` on start.
    private var onToolExecutionStateChange: (@Sendable (AgentRole, String, Bool) -> Void)?
    /// Callback fired when an agent comes online, passing its role and configured tool names.
    private var onAgentStarted: (@Sendable (AgentRole, [String]) -> Void)?
    /// Callback fired when an agent records a new LLM turn, for incremental UI updates.
    private var onTurnRecorded: (@Sendable (AgentRole, LLMTurnRecord) -> Void)?
    /// Fired when an agent learns a model's true maximum output-token limit from a backend
    /// rejection. Args: `(providerID, modelID, limit)`. The app layer persists the limit as
    /// a catalog override so future provider builds clamp to it.
    private var onLearnedModelOutputLimit: (@Sendable (String, String, Int) -> Void)?
    /// Callback fired when a security evaluation is recorded, for incremental UI updates.
    private var onEvaluationRecorded: (@Sendable (EvaluationRecord) -> Void)?
    /// Callback fired when an agent's conversation history changes, for live inspector updates.
    private var onContextChanged: (@Sendable (AgentRole, [LLMMessage]) -> Void)?
    /// Optional hook the app layer wires to surface timer events as system messages in the
    /// channel transcript when the user has the Debug → Show Timer Activity toggle on. Async
    /// because the app layer may need to hop to MainActor to read the user-defaults flag.
    private var onTimerEventForChannel: (@Sendable (TimerEvent) async -> Void)?

    /// Loads the persisted scheduled-wake snapshot from disk. Set by the app layer at
    /// runtime construction; called inside `start(resumingTaskID:)` so the new Smith
    /// inherits every wake (whether keyed to a `.scheduled` task or to an arbitrary
    /// `schedule_task_action` against an in-flight `.pending` task) on every restart —
    /// not just on cold launch. Without this, `restartForNewTask` silently drops every
    /// wake in the previous Smith's in-memory list.
    private var loadPersistedWakes: (@Sendable () async -> [ScheduledWake])?

    /// Resolver that returns the live "scheduled wakes interrupt running task" policy.
    /// Set by the app layer; the closure reads `SharedAppState.scheduledWakesInterruptRunning`
    /// on each invocation so toggling the setting takes effect immediately for in-flight
    /// runtimes. When unset, defaults to false (let the running task finish first).
    private var scheduledWakesInterruptResolver: (@Sendable () async -> Bool)?

    /// Tasks queued to run as soon as the current in-flight task finishes (or is
    /// paused/interrupted), in FIFO order. Populated by `dispatchAutoRunWake` when a
    /// wake fires while something is already running. Drained by
    /// `drainPendingScheduledRunQueue`, called from the task-termination hook. This
    /// queue runs INDEPENDENTLY of `autoAdvanceEnabled` — scheduled wakes are a
    /// promise to the user, not a deferred suggestion.
    ///
    /// Persisted per-session via `persistPendingScheduledRunQueue`; reseeded on every
    /// `start()` from `loadPendingScheduledRunQueue`. Survives app quit and crashes so
    /// a deferred scheduled task isn't lost when the user closes the window mid-run.
    private var pendingScheduledRunQueue: [UUID] = []

    /// Loads the persisted pending-scheduled-run queue from disk. Set by the app layer
    /// at runtime construction; consulted inside `start()` so a fresh runtime inherits
    /// any deferred scheduled tasks from the previous session lifetime.
    private var loadPendingScheduledRunQueue: (@Sendable () async -> [UUID])?

    /// Persists the pending-scheduled-run queue on every mutation. Wired by the app
    /// layer to `PersistenceManager.savePendingScheduledRunQueue`. Fire-and-forget;
    /// failures log to the app's logger but do not block the runtime.
    private var persistPendingScheduledRunQueue: (@Sendable ([UUID]) async -> Void)?

    /// Inbound user messages captured while Smith could not accept them (agents stopped, or
    /// mid-startup during the "Preparing task — starting MCP servers…" window), in FIFO order.
    /// Delivered by `drainPendingUserMessages()` once Smith is running. Persisted per-session
    /// so a message typed during a slow startup survives an app quit or crash. See
    /// `PendingUserMessage`. Without this buffer, such messages were silently dropped at
    /// `AgentActor`'s `guard isRunning` while Smith was subscribed-but-not-running.
    private var pendingUserMessages: [PendingUserMessage] = []

    /// Reentrancy guard for `drainPendingUserMessages()` so concurrent kicks don't
    /// double-deliver. Deliberately NOT held across `await start()` — doing so would
    /// self-strand the inline drain that runs at the end of `start()`.
    private var isDrainingUserMessages = false

    /// `channelMessageID`s of pending user messages that have been delivered to (accepted by)
    /// the CURRENT Smith but not yet incorporated into its conversation. Prevents the drain
    /// re-delivering them while they sit in Smith's volatile pending queue. Cleared on
    /// `stopAll` so the next Smith re-delivers anything still buffered (i.e. accepted but never
    /// incorporated before teardown). A message leaves `pendingUserMessages` only on the
    /// incorporation callback — so a teardown or crash before incorporation redelivers it
    /// rather than losing it.
    private var deliveredUserMessageChannelIDs: Set<UUID> = []

    /// Soft cap above which we log (never drop) an unusually large pending buffer — e.g. a user
    /// hammering send during a long startup hang. Kept generous; the goal is observability, not
    /// data loss.
    private static let pendingUserMessageSoftCap = 100

    /// Loads the persisted pending-user-message buffer from disk. Consulted at the end of
    /// `start()` so a fresh runtime (crash recovery / cold launch) inherits undelivered
    /// messages from the previous lifetime.
    private var loadPendingUserMessages: (@Sendable () async -> [PendingUserMessage])?

    /// Persists the pending-user-message buffer on every mutation. Fire-and-forget; failures
    /// log via the app's logger but never block the runtime.
    private var persistPendingUserMessages: (@Sendable ([PendingUserMessage]) async -> Void)?

    /// Per-session attachment registry. Set by the app layer once the runtime is
    /// constructed (the registry needs the per-session `PersistenceManager`, which the
    /// runtime itself doesn't carry). When unset, attachment-aware tools degrade to
    /// "no attachments resolved" — they still post text-only versions of the tool action.
    private var attachmentRegistry: AttachmentRegistry?

    /// Per-session MCP client host, supplying Brown's dynamic (server-provided) tools.
    /// Owned by the app layer (`AppViewModel`) so its subprocesses survive runtime
    /// restarts (`restartForNewTask`); the runtime only borrows it to feed Brown's
    /// per-turn tool list. `nil` when no MCP servers are configured.
    private var mcpHost: MCPClientHost?

    /// Per-message aggregate attachment cap (bytes). Tools that resolve `attachment_ids`
    /// or `attachment_paths` enforce this against the sum of `byteCount` for the
    /// resolved set, rejecting before the channel post if exceeded. Defaults to a
    /// generous 50 MB; the app layer overrides via `setMaxAttachmentBytesPerMessage(_:)`
    /// from `SharedAppState.maxAttachmentBytesPerMessage`.
    private var maxAttachmentBytesPerMessage: Int = 50 * 1024 * 1024

    /// Synchronous URL resolver matching the registry's async `urlFor(_:)`. Stored so
    /// `makeToolContext` can pass a sync closure into `ToolContext.attachmentURLProvider`,
    /// which is consumed by `AgentActor.drainPendingMessages` (sync path) when building
    /// `file://` markdown links from incoming channel-message attachments.
    private var attachmentURLProviderClosure: (@Sendable (UUID, String) -> URL?)?

    /// FIFO queue used to serialize `restartForNewTask` requests. Without this,
    /// two near-concurrent restart calls would each fire their own
    /// `Task.detached` and interleave their `stopAll() + start()` chains —
    /// `start()`'s `guard smith == nil else { return }` then silently dropped
    /// the second restart's taskID. The queue lets the second restart wait for
    /// the first to fully complete before its own work begins.
    /// Serializes EVERY lifecycle transition — start, stopAll, restart, tool-driven
    /// spawn/terminate — into strict FIFO order. This is the single decision-maker that
    /// makes interleaved lifecycle flows (the root enabler of the 2026-07-08 zombie
    /// incident) structurally impossible: a transition runs start-to-finish, suspension
    /// points and all, before the next begins.
    ///
    /// RULES: public entry points enqueue via `run`/`schedule` and do nothing else;
    /// implementations (`performStart`, `performStopAll`, `performSpawnBrown`,
    /// `performTerminateAgent`) call EACH OTHER directly and must never enqueue —
    /// an enqueue from inside a queue item deadlocks against its own chain.
    /// `abort()` sets its flag synchronously OUTSIDE the queue so an in-flight
    /// transition bails at its next `aborted` check rather than running to completion.
    private let lifecycleQueue = SerialChainedTaskQueue()

    /// Circuit breaker for the pre-flight tool-scoping pass. Lives on the RUNTIME (not the
    /// per-spawn `SecurityEvaluator`) deliberately: `spawnBrown` builds a fresh evaluator
    /// every spawn, so any breaker state kept there resets to zero on each restart and can
    /// never trip. During the 2026-07-08 outage that reset let scoping hammer a dead
    /// backend across 30+ restart generations. The runtime object survives
    /// `restartForNewTask`, so this streak actually accumulates.
    private var scopingFailureStreak = 0
    private var lastScopingFailureAt: Date?
    /// Consecutive scoping failures before the breaker opens.
    private static let scopingBreakerThreshold = 3
    /// How long the breaker stays open after the latest failure before allowing a retry.
    private static let scopingBreakerCooldown: TimeInterval = 120

    /// True while the scoping breaker is open (threshold reached and cooldown not yet
    /// elapsed). Checked by `spawnBrown` before attempting a scoping pass, and by BOTH
    /// queue drains: a spawn failure marks its task `.failed`, which fires the
    /// task-terminated hook, which drains the queues and would otherwise start the next
    /// pending task into the same dead backend — failing the entire queue task-by-task
    /// in seconds. With the drains gated, the queue simply waits out the cooldown.
    /// Opens the breaker immediately for spawn failures that retrying cannot fix
    /// (missing provider configuration). Without this, the terminated-hook auto-advance
    /// cascaded every pending task to .failed through the door the breaker didn't watch
    /// (fresh-Opus review finding). `setProviders` — the only way configuration changes —
    /// closes it again.
    private func openSpawnBreakerForInfrastructureFailure() {
        scopingFailureStreak = max(scopingFailureStreak + 1, Self.scopingBreakerThreshold)
        lastScopingFailureAt = Date()
    }

    private var isScopingBreakerOpen: Bool {
        guard scopingFailureStreak >= Self.scopingBreakerThreshold,
              let lastFailure = lastScopingFailureAt else { return false }
        return Date().timeIntervalSince(lastFailure) < Self.scopingBreakerCooldown
    }

    /// One-shot re-drain armed whenever the open breaker skips a queue drain. The drains
    /// otherwise run only from task-termination hooks and `start()` — on a fully idle
    /// system, work deferred during an outage would wait for an unrelated lifecycle event
    /// that may never come. Fires just after the cooldown expires; if the breaker has
    /// re-opened by then (new failures), the skipped drain re-arms it, giving a bounded
    /// once-per-cooldown retry cadence rather than a storm.
    private var breakerRedrainArmed = false

    // MARK: - Validation configuration (Phase: acceptance validation)

    /// Where the user-owned evaluator registry lives. Set by the app layer at startup
    /// (after seeding shipped defaults). Nil = validation unconfigured → escalates
    /// visibly, never silently passes.
    var evaluatorsDirectory: URL?
    /// Dedicated validator-slot model, once the app configures one. Definitions using
    /// `.validator` fail visibly until then (no fallback chains).
    var validatorProvider: (any LLMProvider)?
    var validatorConfiguration: ModelConfiguration?
    /// Convergence rule for the worker↔validator loop: this many CONSECUTIVE rejection
    /// rounds that settle NOTHING new fail the task. The name is deliberately literal —
    /// this is not a total-round cap. Absolute round count is unbounded as long as rounds
    /// keep making progress (any criterion newly accepted or waived resets the counter).
    var maxConsecutiveValidationRoundsWithoutProgress = 5
    /// Per-report criterion parallelism cap.
    var validationParallelism = 5
    /// Per-task reentrancy guard for validation runs.
    var tasksBeingValidated: Set<UUID> = []
    /// The in-flight validation Task per task, so a pause/stop can cancel it — the
    /// EvaluationRunner's LLM loop checks `Task.isCancelled` and bails, so the validator
    /// stops promptly instead of burning tokens against a task the user just halted.
    var validationTasks: [UUID: Task<Void, Never>] = [:]

    /// App-layer wiring for the validation system.
    public func setEvaluatorConfiguration(directory: URL) {
        evaluatorsDirectory = directory
    }

    // MARK: - Worker pool configuration

    /// How many workers (Browns, each 1:1 with a task) may run concurrently. Starting a
    /// task beyond capacity never evicts anyone: run_task/the play button refuse,
    /// create_task queues, and a start that races past the tool-level checks is pended
    /// by the race-free gate in `performStartTaskWithLiveSmith`.
    private(set) var maxConcurrentWorkers = 4

    /// The user-configurable ceiling for `setWorkerCapacity`.
    public static let maxWorkerCapacity = 10

    /// Sets the worker-pool capacity (clamped to 1...maxWorkerCapacity).
    public func setWorkerCapacity(_ capacity: Int) {
        maxConcurrentWorkers = min(max(1, capacity), Self.maxWorkerCapacity)
    }

    /// Live worker count vs. capacity — the slot arithmetic tools and UI gate on.
    public func workerSlots() -> (live: Int, capacity: Int) {
        (supervisor.handles(role: .brown).count, maxConcurrentWorkers)
    }

    /// Reentrancy guard shared by both task-queue drains (mirroring
    /// `isDrainingUserMessages`): the drains suspend at `taskStore.allTasks()` before
    /// mutating their queues, so two concurrent termination hooks could both observe
    /// "not busy" and double-dequeue — starting a task only for the second drain's
    /// restart to immediately tear it down (fresh-Opus review finding).
    private var isDrainingTaskQueues = false

    /// Tasks that were `.interrupted` when THIS session came up (Stop, app-quit, orphan
    /// recovery) and are waiting to auto-resume, oldest-first. The cold-launch path fills
    /// it and resumes up to capacity immediately; `drainPendingTaskQueue` resumes the rest
    /// as slots free. An ID is removed the moment its resume is initiated — so a task the
    /// user Stops MID-session (which also lands `.interrupted`) is never on this queue and
    /// stays stopped until the next launch. Governed by `autoRunInterruptedTasks`.
    private var launchResumeQueue: [UUID] = []

    private func armBreakerRedrainIfNeeded() {
        // `lastScopingFailureAt` is always set when the breaker is open (the only callers
        // are the breaker-gate guards), so nil here means nothing to wait out.
        guard !breakerRedrainArmed, let lastFailure = lastScopingFailureAt else { return }
        breakerRedrainArmed = true
        let remaining = max(1, Self.scopingBreakerCooldown - Date().timeIntervalSince(lastFailure)) + 1
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            await self?.breakerRedrainFired()
        }
    }

    private func breakerRedrainFired() async {
        breakerRedrainArmed = false
        // A wall-clock timer must never resurrect a runtime the user deliberately
        // stopped: no generation means no session is supposed to be running, so the
        // queued work simply waits for the next user-driven start (fresh-Opus review
        // finding — before this guard, the timer restarted the whole cast two minutes
        // after a Stop All).
        guard supervisor.currentGeneration != nil else { return }
        let kicked = await drainPendingScheduledRunQueue()
        if !kicked {
            await drainPendingTaskQueue()
        }
    }

    public func setOnTimerEventForChannel(_ handler: @escaping @Sendable (TimerEvent) async -> Void) {
        onTimerEventForChannel = handler
    }

    /// Wires the disk-replay loader. Called once by the app layer after constructing the
    /// runtime; the closure is invoked on every `start()` to seed the new Smith with
    /// surviving wakes.
    public func setLoadPersistedWakes(_ handler: @escaping @Sendable () async -> [ScheduledWake]) {
        loadPersistedWakes = handler
    }

    /// Wires the live policy resolver. The closure is consulted on every auto-run wake
    /// fire, so toggling `SharedAppState.scheduledWakesInterruptRunning` takes effect
    /// immediately without restarting the runtime.
    public func setScheduledWakesInterruptResolver(_ resolver: @escaping @Sendable () async -> Bool) {
        scheduledWakesInterruptResolver = resolver
    }

    /// Wires the per-session persistence for the pending-scheduled-run queue. The runtime
    /// calls `load` once inside `start()` to seed the queue, and calls `persist` after
    /// every enqueue / dequeue. Both closures should target the session-scoped
    /// `PersistenceManager(sessionID:)` so the queue lives next to the channel log,
    /// scheduled wakes, and other per-session state.
    public func setPendingScheduledRunQueuePersistence(
        load: @escaping @Sendable () async -> [UUID],
        persist: @escaping @Sendable ([UUID]) async -> Void
    ) {
        loadPendingScheduledRunQueue = load
        persistPendingScheduledRunQueue = persist
    }

    /// Wires the per-session persistence for the pending-user-message buffer. Mirrors
    /// `setPendingScheduledRunQueuePersistence`. Both closures should target the session-scoped
    /// `PersistenceManager(sessionID:)`. Must be wired before the first `sendUserMessage` /
    /// `start()` so enqueues persist and a fresh runtime can reseed.
    public func setPendingUserMessagePersistence(
        load: @escaping @Sendable () async -> [PendingUserMessage],
        persist: @escaping @Sendable ([PendingUserMessage]) async -> Void
    ) {
        loadPendingUserMessages = load
        persistPendingUserMessages = persist
    }

    // MARK: - Smith context management (/clear and /compact)

    /// Resets Smith's LLM context to its system prompt plus a fresh task-state
    /// orientation — the user-facing `/clear` / toolbar trashcan. Distinct from the
    /// display-only screen clear (Ctrl-L): this changes what the MODEL knows, not what
    /// the user sees. Brown is deliberately untouched — clearing a worker mid-task would
    /// break the task. Returns a user-facing result line for the transcript.
    public func clearSmithContext() async -> String {
        guard let smith = supervisor.firstHandle(role: .smith)?.agent else {
            return "System is not running — there is no agent context to clear."
        }
        let orientation = await composeContextResetOrientation()
        await smith.resetConversationHistory(orientation: orientation)
        return "Smith's context has been cleared. Current task state was re-briefed."
    }

    /// How many of Smith's most recent turns `/compact` preserves verbatim.
    private static let compactionRecentTurnsKept = 6

    /// Message count above which a task termination triggers automatic compaction of the
    /// long-lived Smith's context. Task boundaries are the natural compaction point (the
    /// terminated task's play-by-play just became historical), and the Summarizer's
    /// output preserves the judgment. Manual `/compact` works at any size.
    private static let smithAutoCompactMessageThreshold = 50

    /// Task-boundary automatic compaction for the long-lived Smith (Phase 2). Runs from
    /// the task-terminated hook; a no-op below the threshold, during abort/stop, or with
    /// no live Smith. The notice is posted with the `context_management` kind so both
    /// agent filters drop it — context maintenance is user-visible but agent-invisible.
    func autoCompactSmithIfNeeded() async {
        guard !aborted, !stopRequested else { return }
        guard let smithAgent = supervisor.firstHandle(role: .smith)?.agent else { return }
        let messageCount = await smithAgent.contextSnapshot().count
        guard messageCount > Self.smithAutoCompactMessageThreshold else { return }
        let result = await compactSmithContext()
        stopLogger.notice("Auto-compact after task termination: \(result, privacy: .public)")
        await channel.post(ChannelMessage(
            sender: .system,
            content: "Automatic context maintenance: \(result)",
            metadata: ["messageKind": .string("context_management")]
        ))
    }

    /// Summarizes Smith's conversation and splices the history down to
    /// `[system prompt] + [summary] + recent turns` — the user-facing `/compact`.
    /// Uses the Summarizer's provider when configured (a compaction summary is exactly
    /// its job, and it's typically a cheaper model), falling back to Smith's own.
    /// Returns a user-facing result line for the transcript.
    public func compactSmithContext() async -> String {
        guard let smith = supervisor.firstHandle(role: .smith)?.agent else {
            return "System is not running — there is no agent context to compact."
        }
        let snapshot = await smith.contextSnapshot()
        guard snapshot.count > Self.compactionRecentTurnsKept + 3 else {
            return "Smith's context is only \(snapshot.count) message(s) — nothing to compact."
        }
        let summarizerRole: AgentRole = llmProviders[.summarizer] != nil ? .summarizer : .smith
        guard let provider = llmProviders[summarizerRole], let config = llmConfigs[summarizerRole] else {
            return "No provider is available to summarize Smith's context."
        }

        let transcript = Self.renderTranscriptForCompaction(snapshot)
        let messages: [LLMMessage] = [
            .system("""
                You summarize an AI orchestrator's working conversation so it can continue with a \
                smaller context. Preserve, with specifics (task titles and IDs verbatim): \
                (1) the user's requests, stated preferences, and any permissions they granted; \
                (2) tasks created, run, reviewed, and their outcomes; \
                (3) unresolved questions, commitments, or anything awaiting follow-up. \
                Omit tool-call mechanics and routine acknowledgments. Under 400 words.
                """),
            .user(transcript)
        ]

        let response: LLMResponse
        let callStart = Date()
        do {
            response = try await provider.send(
                messages: messages,
                tools: [],
                overrides: LLMCallOverrides(maxOutputTokens: 2000)
            )
        } catch {
            return "Compaction failed — the summary call errored: \(error.localizedDescription). Smith's context is unchanged."
        }
        await UsageRecorder.record(
            response: response,
            context: LLMCallContext(
                agentRole: summarizerRole,
                taskID: nil,
                modelID: config.model,
                providerType: providerAPITypes[summarizerRole]?.rawValue ?? "",
                providerID: config.providerID,
                configuration: config,
                sessionID: currentSessionID
            ),
            latencyMs: Int(Date().timeIntervalSince(callStart) * 1000),
            to: usageStore
        )

        guard let summary = response.text?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty else {
            return "Compaction failed — the summary came back empty. Smith's context is unchanged."
        }
        guard let counts = await smith.compactConversationHistory(
            summaryText: summary,
            keepingRecentTurns: Self.compactionRecentTurnsKept
        ) else {
            return "Smith's context is already compact — nothing was changed."
        }
        return "Smith's context compacted: \(counts.before) → \(counts.after) messages."
    }

    /// A short re-briefing injected after `/clear` so Smith isn't amnesiac about live
    /// work: active tasks by status, plus ground rules for treating the next message
    /// fresh. Rebuilt from the task store — the source of truth — not from anything the
    /// cleared context contained.
    private func composeContextResetOrientation() async -> String {
        let activeTasks = await taskStore.allTasks().filter { $0.disposition == .active }
        var lines: [String] = [
            "[The user cleared your conversation context. Nothing before this message is visible to you.]"
        ]
        let interesting = activeTasks.filter { $0.status != .completed && $0.status != .failed }
        if interesting.isEmpty {
            lines.append("There are no active tasks right now.")
        } else {
            lines.append("Current task state:")
            for task in interesting.prefix(15) {
                lines.append("- \(task.title) (id: \(task.id.uuidString), status: \(task.status.rawValue))")
            }
        }
        lines.append("""
            Treat the user's next message as a fresh request. Do not re-announce or re-summarize \
            these tasks unless asked; use list_tasks / get_task_details if you need more detail.
            """)
        return lines.joined(separator: "\n")
    }

    /// Renders Smith's history as plain text for the compaction summarizer. Tool calls
    /// collapse to `[tool: name]` lines; the system prompt is skipped (static, re-added
    /// by the splice). Capped from the END so a huge history can't blow the summarizer's
    /// own window.
    static func renderTranscriptForCompaction(_ messages: [LLMMessage], characterCap: Int = 120_000) -> String {
        var lines: [String] = []
        for message in messages where message.role != .system {
            let speaker: String
            switch message.role {
            case .user, .developer: speaker = "USER/SYSTEM"
            case .assistant: speaker = "SMITH"
            case .tool: speaker = "TOOL RESULT"
            case .system: continue
            }
            switch message.content {
            case .text(let text):
                lines.append("\(speaker): \(text)")
            case .mixed(let text, let calls):
                if !text.isEmpty { lines.append("\(speaker): \(text)") }
                for call in calls { lines.append("\(speaker): [tool: \(call.name)]") }
            case .toolCalls(let calls):
                for call in calls { lines.append("\(speaker): [tool: \(call.name)]") }
            case .toolResult(_, let content):
                lines.append("\(speaker): \(String(content.prefix(300)))")
            }
        }
        var transcript = lines.joined(separator: "\n")
        if transcript.count > characterCap {
            transcript = "[…earlier conversation truncated…]\n" + String(transcript.suffix(characterCap))
        }
        return transcript
    }

    /// Nil when no Smith is live — "no Smith" must be distinguishable from "no wakes":
    /// persisting `[]` during a restart's teardown window truncated the wake file and
    /// killed recurring series before the replay filter ever saw them (fresh-Opus review
    /// finding).
    public func currentScheduledWakes() async -> [ScheduledWake]? {
        guard let smith else { return nil }
        return await smith.listScheduledWakes()
    }

    public func cancelScheduledWake(id: UUID) async -> Bool {
        await smith?.cancelWake(id: id) ?? false
    }

    /// Replays a previously-persisted set of wakes onto Smith's actor. Called by the app
    /// layer at cold-launch *before* `start()` so any wake that elapsed while the app was
    /// quit fires on the next loop iteration. Replacing rather than merging is intentional:
    /// after this call the actor's wake list IS the persisted snapshot.
    public func restoreScheduledWakes(_ wakes: [ScheduledWake]) async {
        await smith?.restoreScheduledWakes(wakes)
    }

    /// Routes an auto-run wake fire deterministically based on `scheduledWakesInterrupt`.
    ///
    /// **No task in flight** → `restartForNewTask` immediately, regardless of policy.
    ///
    /// **Task in flight, interrupt = true** → pause the running task, queue it for
    /// resume AFTER the scheduled task, then drive `restartForNewTask` for the
    /// scheduled task. When the scheduled task completes (`onTaskTerminated` →
    /// `drainPendingScheduledRunQueue`), the paused task auto-resumes.
    ///
    /// **Task in flight, interrupt = false** → enqueue the scheduled task. It runs as
    /// soon as the current task finishes (via `drainPendingScheduledRunQueue`).
    ///
    /// Both queue-driven paths run INDEPENDENTLY of `autoAdvanceEnabled` — a scheduled
    /// wake is a commitment to the user, not a deferred suggestion.
    private func dispatchAutoRunWake(taskID: UUID) async {
        let activeTasks = await taskStore.allTasks().filter { $0.disposition == .active }
        let inFlight = activeTasks.first {
            $0.status == .running || $0.status == .awaitingReview || $0.status == .validating
        }

        // A free worker slot means the scheduled task can start right now, no interrupt
        // arbitration needed — other in-flight tasks keep running beside it.
        guard supervisor.handles(role: .brown).count >= maxConcurrentWorkers, let blocker = inFlight else {
            restartForNewTask(taskID: taskID)
            return
        }

        guard let scheduledTask = await taskStore.task(id: taskID) else { return }
        let interrupt = await scheduledWakesInterruptResolver?() ?? false

        if interrupt {
            // Pause the running task so its Brown context is saved, queue it for resume,
            // then start the scheduled task. When the scheduled task completes the
            // termination hook drains the queue and resumes the paused task.
            await taskStore.updateStatus(id: blocker.id, status: .paused)
            pendingScheduledRunQueue.append(blocker.id)
            await persistPendingScheduledRunQueue?(pendingScheduledRunQueue)
            await channel.post(ChannelMessage(
                sender: .system,
                content: "Pausing '\(blocker.title)' to run scheduled task '\(scheduledTask.title)'. Will resume '\(blocker.title)' when the scheduled task finishes.",
                metadata: [
                    "messageKind": .string("scheduled_run_interrupting"),
                    "scheduledTaskID": .string(taskID.uuidString),
                    "scheduledTaskTitle": .string(scheduledTask.title),
                    "blockingTaskID": .string(blocker.id.uuidString),
                    "blockingTaskTitle": .string(blocker.title)
                ]
            ))
            restartForNewTask(taskID: taskID)
        } else {
            pendingScheduledRunQueue.append(taskID)
            await persistPendingScheduledRunQueue?(pendingScheduledRunQueue)
            await channel.post(ChannelMessage(
                sender: .system,
                content: "Scheduled task '\(scheduledTask.title)' fired while '\(blocker.title)' is \(blocker.status.rawValue). Queued — will run after the current task finishes.",
                metadata: [
                    "messageKind": .string("scheduled_run_deferred"),
                    "scheduledTaskID": .string(taskID.uuidString),
                    "scheduledTaskTitle": .string(scheduledTask.title),
                    "blockingTaskID": .string(blocker.id.uuidString),
                    "blockingTaskTitle": .string(blocker.title),
                    "blockingTaskStatus": .string(blocker.status.rawValue)
                ]
            ))
        }
    }

    /// Drains the head of `pendingScheduledRunQueue` if no task is currently in flight.
    /// Self-checking — safe to call any time the runtime suspects state may have shifted
    /// (typically from `onTaskTerminated`). Skips queue entries whose tasks are no longer
    /// runnable (e.g. cancelled by the user mid-queue) so a single bad entry can't stall
    /// the rest of the queue.
    /// Returns `true` if a `restartForNewTask` was scheduled, so callers can skip
    /// follow-on drains (like the pending-task auto-advance) that would race the same slot.
    @discardableResult
    private func drainPendingScheduledRunQueue() async -> Bool {
        guard !pendingScheduledRunQueue.isEmpty else { return false }
        guard !isDrainingTaskQueues else { return false }
        isDrainingTaskQueues = true
        defer { isDrainingTaskQueues = false }
        // Breaker gate: starting a task while the scoping backend is known-dead would just
        // fail it. Entries stay queued; a one-shot re-drain is armed for when the
        // cooldown expires so an otherwise-idle system still resumes the queue.
        guard !isScopingBreakerOpen else {
            stopLogger.notice("drainPendingScheduledRunQueue skipped — scoping breaker open")
            armBreakerRedrainIfNeeded()
            return false
        }
        guard supervisor.handles(role: .brown).count < maxConcurrentWorkers else { return false }

        while let next = pendingScheduledRunQueue.first {
            pendingScheduledRunQueue.removeFirst()
            await persistPendingScheduledRunQueue?(pendingScheduledRunQueue)
            guard let task = await taskStore.task(id: next), task.status.isRunnable else {
                continue
            }
            restartForNewTask(taskID: next)
            return true
        }
        return false
    }

    /// Starts pending tasks (oldest first) while worker slots are free. This is the
    /// auto-advance step that runs after a task terminates (review_work accept/reject,
    /// task_failed, manual update_task, etc.) and at cold boot — pairs with Smith's
    /// prompt directive to STOP after `review_work(accepted: true)` and let the runtime
    /// advance the queue.
    ///
    /// Gated on `autoAdvanceEnabled`. Skips when:
    ///   - auto-advance is off (user disabled "Auto-run next task")
    ///   - every worker slot is occupied
    ///   - the scheduled-run queue (`pendingScheduledRunQueue`) just kicked off a restart
    ///     in this same drain pass — the caller is responsible for skipping us in that case
    ///
    /// `.scheduled` is deliberately excluded (those wait for their fire time) and so is
    /// `.paused` (a deliberate user halt requires a deliberate resume). `.interrupted` is
    /// drained ONLY via `launchResumeQueue` — the batch captured at cold launch — so an
    /// interrupt from a mid-session Stop is never auto-resumed here; it waits for the next
    /// launch. Governed by `autoRunInterruptedTasks`.
    private func drainPendingTaskQueue() async {
        // Two queues share the pool: the launch-scoped interrupted-resume queue
        // (autoRunInterruptedTasks) and pending auto-advance (autoAdvanceEnabled). Run if
        // either could place work.
        guard autoAdvanceEnabled || (autoRunInterruptedTasks && !launchResumeQueue.isEmpty) else { return }
        guard !isDrainingTaskQueues else { return }
        isDrainingTaskQueues = true
        defer { isDrainingTaskQueues = false }
        // Breaker gate: without this, one spawn-failed task (marked .failed → terminated
        // hook → this drain) would auto-advance into the next pending task, fail it
        // against the same dead backend, and cascade the entire queue to .failed. A
        // one-shot re-drain is armed so recovery doesn't wait for an unrelated event.
        guard !isScopingBreakerOpen else {
            stopLogger.notice("drainPendingTaskQueue skipped — scoping breaker open")
            armBreakerRedrainIfNeeded()
            return
        }
        // Fill free slots, oldest pending first. The restarts are enqueued (not awaited),
        // so the live worker count doesn't move within this pass — bound the fan-out by
        // the free-slot count instead. A modest overshoot from a racing start elsewhere
        // is safe: performStartTaskWithLiveSmith's serialized gate re-pends the loser.
        let freeSlots = maxConcurrentWorkers - supervisor.handles(role: .brown).count
        guard freeSlots > 0 else { return }
        let activeTasks = await taskStore.allTasks().filter { $0.disposition == .active }
        let byID = Dictionary(activeTasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Prune the resume queue to IDs still present AND still interrupted (a task that
        // completed, was manually run, or was archived drops off).
        launchResumeQueue = launchResumeQueue.filter { byID[$0]?.status == .interrupted }

        // Launch-interrupted work (in-flight when the session came up) resumes before pending
        // (never-started) work; each oldest-first. `restartForNewTask` resumes an interrupted
        // task WITH its prior context (the briefing draws on task.updates), so nothing is lost.
        var runnable: [AgentTask] = []
        if autoRunInterruptedTasks {
            runnable += launchResumeQueue.compactMap { byID[$0] }
        }
        if autoAdvanceEnabled {
            // Templates are `.pending` launchers, not queued work — they start only on an
            // EXPLICIT action (run_task, the play button, a scheduled/recurring wake), never
            // by auto-advance. Without this exclusion the drain would clone-and-run every
            // template the moment a slot freed.
            runnable += activeTasks
                .filter { $0.status == .pending && !$0.isTemplate }
                .sorted { $0.createdAt < $1.createdAt }
        }
        let toStart = Array(runnable.prefix(freeSlots))
        // Drop resumed IDs from the queue immediately, so a later mid-session Stop of the same
        // task can't put it back on the auto-resume path.
        let startedIDs = Set(toStart.map(\.id))
        launchResumeQueue.removeAll { startedIDs.contains($0) }
        for task in toStart {
            restartForNewTask(taskID: task.id)
        }
    }

    /// Builds the user-role message that seeds Brown's conversation history at task spawn.
    /// Used by both the run_task path and the autoRunInterruptedTasks cold-launch path.
    ///
    /// Output is markdown:
    /// - `task.title` and `task.description` verbatim.
    /// - Description / per-update / result attachments rendered as
    ///   `[filename](file:///abs/path) mime · size · id=<UUID>` markdown links so Brown can
    ///   `file_read` non-image content and quote the `id=<UUID>` into downstream tool calls.
    /// - Optional Prior Progress (from `task.updates`) and Last Working State (from
    ///   `task.lastBrownContext`).
    ///
    /// Async because the attachment-line builder resolves a stable `file://` URL via the
    /// per-session registry; markdown-link syntax was chosen over an ad-hoc text marker
    /// because it tends to round-trip through summarizer prompts more reliably.
    ///
    /// Replaces the prior "post a Smith → Brown channel message" approach, which
    /// duplicated the New Task banner's description in the user-facing transcript.
    func composeBrownTaskBriefing(for task: AgentTask) async -> String {
        var parts: [String] = []
        parts.append("Task: \"\(task.title)\" (ID: \(task.id.uuidString))\n\n\(task.description)")
        // A prior acknowledgment means this is a resume (respawn after interruption, or a
        // rejection sent back for revision). The synthetic ack hasn't run yet at briefing time,
        // so the counter still reflects earlier attempts. State it explicitly here — Brown no
        // longer sees a "Task continuing:" tool result in its history to infer it from, and the
        // Prior Progress / Last Working State sections below can both be empty if it died early.
        if task.acknowledgmentCount > 0 {
            parts.append("You are RESUMING this task — a prior attempt was interrupted or sent back for revision. Continue from where you left off using the context below; do not restart from scratch.")
        }
        if !task.descriptionAttachments.isEmpty {
            var lines: [String] = []
            for attachment in task.descriptionAttachments {
                lines.append(await attachmentMarkdownLine(attachment))
            }
            parts.append("## Attachments\n\(lines.joined(separator: "\n"))")
        }
        if let criteria = task.renderedAcceptanceCriteria(includeVerdicts: task.acknowledgmentCount > 0) {
            parts.append("""
                ## Acceptance criteria — the contract your submission is judged against
                Each is judged independently, on evidence. Your `task_complete` is accepted only when \
                EVERY criterion below is satisfied (or waived). Provide the specific evidence each one asks \
                for. These numbers are stable — a rejection referring to "Criterion 3" means this list's #3.
                \(criteria)
                """)
        }
        if let steps = task.renderedSteps(includeIDs: true) {
            parts.append("""
                ## Steps — your working plan
                This plan is YOURS to own and evolve with `manage_steps` (update / set_status / reorder / \
                delete). If it was seeded for you, adopt and refine it — do NOT start a second parallel plan. \
                The validators read this list, so keep every step's status honest.
                \(steps)
                """)
        }
        if !task.updates.isEmpty {
            var updateLines: [String] = []
            for update in task.updates {
                if update.attachments.isEmpty {
                    updateLines.append("- \(update.message)")
                } else {
                    var refs: [String] = []
                    for attachment in update.attachments {
                        refs.append(await attachmentMarkdownLine(attachment))
                    }
                    updateLines.append("- \(update.message)\n  \(refs.joined(separator: "\n  "))")
                }
            }
            parts.append("## Prior Progress\n\(updateLines.joined(separator: "\n"))")
        }
        if let brownContext = task.lastBrownContext {
            parts.append("## Last Working State\n\(brownContext)")
        }
        return parts.joined(separator: "\n\n")
    }

    /// Markdown-link representation of an attachment, with a stable `file://` URL when
    /// the per-session registry has one. Format:
    /// `[filename](file:///abs/path) mime · size · id=<UUID>`
    /// When the file isn't reachable (no registry, no on-disk file), appends a clear
    /// `· UNLOADABLE` marker so Brown sees that the reference exists but the bytes don't.
    ///
    /// The URL is built via `Self.fileURLString(_:)` which uses `URL.path(percentEncoded:
    /// false)` — `URL.absoluteString` percent-encodes spaces (`Foo Bar.png` → `Foo%20Bar.png`)
    /// and the LLM consuming the link tends to either (a) pass the percent-encoded string
    /// to `file_read` which fails because the on-disk filename has literal spaces, or (b)
    /// shell-escape the spaces to `Foo\ Bar.png` because Brown reflexively shell-escapes
    /// paths it sees as filesystem-y, which also fails. Emitting raw-space `file://` URLs
    /// matches what macOS Finder produces when copying a path and what Brown can paste
    /// verbatim into `file_read` (which now also normalizes file:// + percent-encoding +
    /// shell-escapes for resilience).
    func attachmentMarkdownLine(_ attachment: Attachment) async -> String {
        let label = attachment.filename
        let meta = "\(attachment.mimeType) · \(attachment.formattedSize) · id=\(attachment.id.uuidString)"
        guard let url = await attachmentRegistry?.urlFor(attachment) else {
            return "[\(label)](#) \(meta) · UNLOADABLE"
        }
        let exists = FileManager.default.fileExists(atPath: url.path)
        let urlString = Self.fileURLString(url)
        if exists {
            return "[\(label)](\(urlString)) \(meta)"
        } else {
            return "[\(label)](\(urlString)) \(meta) · UNLOADABLE: file missing on disk"
        }
    }

    /// Builds a `file://` URL string from a file URL using a raw (non-percent-encoded)
    /// path component. Foundation's `URL.absoluteString` percent-encodes spaces and other
    /// reserved characters, producing strings like `file:///foo/Foo%20Bar.png` — that's
    /// RFC 3986-correct but trips LLMs that paste the URL into `file_read` without
    /// decoding. `URL.path(percentEncoded: false)` returns the raw filesystem path which
    /// we prepend `file://` to; it's the format macOS Finder produces when copying a
    /// path and the format `file_read` accepts directly. (file_read also normalizes the
    /// percent-encoded form for resilience, but emitting clean URLs avoids the
    /// LLM-confusion path entirely.)
    static func fileURLString(_ url: URL) -> String {
        "file://" + url.path(percentEncoded: false)
    }

    /// Maximum number of MOST-RECENT updates whose attachments get rehydrated into Brown's
    /// briefing on a respawn. Older updates' attachment refs still appear in the markdown
    /// briefing text (so Brown knows they existed and can `view_attachment` them by id),
    /// but their image bytes are NOT eagerly re-injected into the conversation history.
    /// Without this cap, every Brown respawn re-pays the full image-cost of the entire
    /// task, compounding badly across long-running multi-update tasks.
    static let briefingUpdateAttachmentBudget = 3

    /// Returns the attachments that should be eagerly rehydrated into Brown's briefing
    /// (i.e. injected as image content blocks where applicable). Selection rules:
    /// - **Description attachments**: ALL included. The user attached these to *ask about
    ///   them*; Brown's first turn needs to see them.
    /// - **Update attachments**: only the most-recent `briefingUpdateAttachmentBudget`
    ///   updates' attachments are eagerly loaded. Older updates' refs appear as markdown
    ///   links in the briefing text (Brown can call `view_attachment(ids:)` to load them).
    /// - **Result attachments**: NEVER eagerly loaded on a respawn. The result is the
    ///   *output* of the task, not Brown's input — re-seating Brown to "redo" or "revise"
    ///   doesn't require him to look at his own previous output's attached files. If
    ///   needed, Brown can `view_attachment` them.
    ///
    /// Lazy-loads bytes via the registry where the in-memory record is metadata-only
    /// (e.g. a task restored from disk after restart).
    func collectTaskAttachments(_ task: AgentTask) async -> [Attachment] {
        var collected: [Attachment] = []
        var candidates: [Attachment] = task.descriptionAttachments
        let recentUpdates = task.updates.suffix(Self.briefingUpdateAttachmentBudget)
        candidates.append(contentsOf: recentUpdates.flatMap { $0.attachments })
        for candidate in candidates {
            if candidate.data != nil {
                collected.append(candidate)
                continue
            }
            if let registry = attachmentRegistry, let resolved = await registry.resolve(candidate.id) {
                collected.append(resolved)
            } else {
                collected.append(candidate)
            }
        }
        return collected
    }

    /// Re-arms wakes for any `.scheduled` task that doesn't already have a wake registered
    /// on Smith's actor. Belt-and-suspenders pass run from `start(resumingTaskID:)` after
    /// disk replay — covers stale-snapshot or first-launch cases where the persistence file
    /// is missing a wake the task store still needs. Past-due `.scheduled` tasks are
    /// promoted to `.pending` so the cold-launch task summary surfaces them.
    /// `excluded` skips a task that's about to be promoted out of `.scheduled` by the
    /// run_task path (no point arming a wake we'd immediately cancel).
    /// Filters a disk-replayed wake snapshot down to the wakes still valid to re-arm on a
    /// fresh Smith. Rules, per wake:
    ///
    /// - **Non-auto-run wakes** (Smith imperatives: pause/stop/summarize, user follow-ups):
    ///   kept, deduped by id. These carry instructions Smith must interpret; dropping them
    ///   would break the documented promise that arbitrary `schedule_task_action` wakes
    ///   survive restarts.
    /// - **Auto-run `run_task` wakes**: dropped when the task is missing or inactive, or
    ///   when the wake is PAST-DUE and either (a) it targets `resumingTaskID` — this very
    ///   restart is its fulfillment — or (b) its task has already left `.scheduled`, which
    ///   means it fired and promoted the task before this snapshot was taken; replaying it
    ///   re-fires it forever (the 2026-07-08 resurrection storm). A past-due wake whose
    ///   task is still `.scheduled` elapsed while the app was quit and must fire (the
    ///   documented cold-launch catch-up). A FUTURE wake is always kept — regardless of
    ///   task status and even when it targets the resuming task ("run it again at 6pm").
    ///   A fired wake with a RECURRENCE is rolled forward to its next future occurrence
    ///   instead of dropped, so the persist race can't kill the series.
    /// - **Duplicates**: auto-run wakes deduped by (taskID, wakeAt) — the incident's disk
    ///   snapshot had accumulated the same 9 PM wake two and three times over.
    ///
    /// Accepted trade-off: a `run` wake against a `.paused`/`.interrupted` task that
    /// elapses while the app is QUIT is indistinguishable here from one that already
    /// fired, so it is dropped (logged, task stays visible in the UI) rather than fired
    /// late. Firing it would require distinguishing "elapsed while quit" from "fired and
    /// dispatch failed", and guessing wrong on the latter is what produced the storm.
    ///
    /// Internal (not private) for direct unit-testing — the replay filter is the guard
    /// against wake-resurrection restart storms and needs test coverage.
    func replayableWakes(from wakes: [ScheduledWake], resumingTaskID: UUID?) async -> [ScheduledWake] {
        let now = Date()
        let allTasks = await taskStore.allTasks()
        let tasksByID = Dictionary(allTasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seenAutoRunKeys = Set<String>()
        var seenIDs = Set<UUID>()
        var kept: [ScheduledWake] = []
        var droppedCount = 0
        for wake in wakes {
            if AgentActor.wakeIsAutoRunRunTask(wake), let taskID = wake.taskID {
                guard let task = tasksByID[taskID], task.disposition == .active else { droppedCount += 1; continue }
                var candidate = wake
                // Only a PAST-DUE wake can be "already handled": for the resuming task it
                // is this very restart's trigger; for any other task that has left
                // `.scheduled` it fired-and-promoted before the snapshot. A FUTURE wake is
                // always live — including one aimed at the resuming task ("run it again at
                // 6pm" queued while starting it now; survivesTaskTermination exists for
                // exactly that).
                let isFulfilledOrFired = wake.wakeAt <= now
                    && (taskID == resumingTaskID || task.status != .scheduled)
                if isFulfilledOrFired {
                    // A RECURRING wake must not take its whole series down with it: the
                    // fired occurrence schedules its successor in memory, but this disk
                    // snapshot can predate that persist (the same race that resurrects
                    // one-shot wakes). Roll the fired occurrence forward to its next
                    // future fire time — mirroring checkScheduledWake's reschedule — and
                    // let the (taskID, wakeAt) dedupe collapse it if the successor DID
                    // reach disk. One-shot fired wakes just drop.
                    guard let rolled = Self.rolledForwardRecurrence(of: wake, after: now) else {
                        droppedCount += 1
                        continue
                    }
                    candidate = rolled
                }
                let key = "\(taskID.uuidString)|\(candidate.wakeAt.timeIntervalSince1970)"
                guard seenAutoRunKeys.insert(key).inserted else { droppedCount += 1; continue }
                kept.append(candidate)
            } else {
                guard seenIDs.insert(wake.id).inserted else { droppedCount += 1; continue }
                kept.append(wake)
            }
        }
        if droppedCount > 0 {
            stopLogger.notice("Wake replay: dropped \(droppedCount, privacy: .public) stale/duplicate wake(s), kept \(kept.count, privacy: .public)")
        }
        return kept
    }

    /// Rolls a fired recurring wake forward to its first occurrence strictly after `now`,
    /// preserving the chain identity (`originalID`, recurrence, survives flag) exactly as
    /// `AgentActor.checkScheduledWake`'s reschedule does. Returns nil for one-shot wakes
    /// and for exhausted recurrences. Skipping straight to a FUTURE occurrence — rather
    /// than the next occurrence after the fired one — is deliberate: intermediate
    /// occurrences belong to fire windows that already elapsed, and re-firing them
    /// immediately on replay is the storm shape this filter exists to prevent. Bounded
    /// iteration guards against a degenerate recurrence that never reaches the future.
    private static func rolledForwardRecurrence(of wake: ScheduledWake, after now: Date) -> ScheduledWake? {
        guard let recurrence = wake.recurrence else { return nil }

        // `.interval` catch-up in O(1): a 60 s interval left offline for a week needs
        // 10,000+ steps, which exhausted the iteration-capped loop below and silently
        // killed the series (agy review finding). Number of whole intervals to reach
        // strictly past `now`, computed arithmetically.
        // `>= minimumIntervalSeconds` matches `nextOccurrence`'s own floor: a persisted
        // sub-minimum interval (hand-edited or from an older build) must die here exactly
        // as it would on the live reschedule path, not get resurrected by the fast path.
        if case .interval(let seconds) = recurrence, seconds >= Recurrence.minimumIntervalSeconds {
            let interval = TimeInterval(seconds)
            let elapsed = now.timeIntervalSince(wake.wakeAt)
            let steps = max(1, Int(floor(elapsed / interval)) + 1)
            let fireAt = wake.wakeAt.addingTimeInterval(TimeInterval(steps) * interval)
            return ScheduledWake(
                wakeAt: fireAt,
                instructions: wake.instructions,
                taskID: wake.taskID,
                recurrence: recurrence,
                originalID: wake.originalID,
                previousFireAt: fireAt.addingTimeInterval(-interval),
                survivesTaskTermination: wake.survivesTaskTermination
            )
        }

        // Calendar recurrences step at most once per day, so the cap spans ~27 years —
        // a true runaway guard, not a reachable limit.
        var fireAt = wake.wakeAt
        var previousFireAt = wake.previousFireAt
        for _ in 0..<10_000 {
            guard let next = recurrence.nextOccurrence(after: fireAt) else { return nil }
            previousFireAt = fireAt
            fireAt = next
            if fireAt > now {
                return ScheduledWake(
                    wakeAt: fireAt,
                    instructions: wake.instructions,
                    taskID: wake.taskID,
                    recurrence: recurrence,
                    originalID: wake.originalID,
                    previousFireAt: previousFireAt,
                    survivesTaskTermination: wake.survivesTaskTermination
                )
            }
        }
        return nil
    }

    private func rearmScheduledTaskWakes(excluding excluded: UUID?) async {
        guard let smithAgent = smith else { return }
        let existingTaskIDs: Set<UUID> = Set(
            await smithAgent.listScheduledWakes().compactMap { $0.taskID }
        )
        let now = Date()
        let scheduled = await taskStore.allTasks().filter {
            $0.disposition == .active && $0.status == .scheduled && $0.id != excluded
        }
        for task in scheduled {
            guard let fireAt = task.scheduledRunAt else { continue }
            if fireAt > now {
                if existingTaskIDs.contains(task.id) { continue }
                let imperative = TaskActionKind.run.imperativeText(for: task, extra: nil)
                _ = await smithAgent.scheduleWake(
                    wakeAt: fireAt,
                    instructions: imperative,
                    taskID: task.id
                )
            } else {
                await taskStore.promoteScheduledToPending(id: task.id)
            }
        }
    }

    public init(
        providers: [AgentRole: any LLMProvider],
        configurations: [AgentRole: ModelConfiguration],
        providerAPITypes: [AgentRole: ProviderAPIType] = [:],
        agentTuning: [AgentRole: AgentTuningConfig] = [:],
        semanticSearchEngine: SemanticSearchEngine,
        usageStore: UsageStore,
        autoAdvanceEnabled: Bool = true,
        autoRunInterruptedTasks: Bool = false,
        memoryStore: MemoryStore? = nil,
        inactiveTaskStore: InactiveTaskStore = InactiveTaskStore()
    ) {
        self.channel = MessageChannel()
        self.taskStore = TaskStore(inactiveStore: inactiveTaskStore)
        self.memoryStore = memoryStore ?? MemoryStore(engine: semanticSearchEngine)
        self.llmProviders = providers
        self.llmConfigs = configurations
        self.providerAPITypes = providerAPITypes
        self.agentTuning = agentTuning
        self.autoAdvanceEnabled = autoAdvanceEnabled
        self.autoRunInterruptedTasks = autoRunInterruptedTasks
        self.usageStore = usageStore
        self.timerEventLog = TimerEventLog()
    }

    /// Updates the auto-advance setting at runtime so it takes effect immediately.
    public func setAutoAdvance(_ enabled: Bool) {
        autoAdvanceEnabled = enabled
    }

    /// Registers a callback fired when Security Agent triggers an abort.
    public func setOnAbort(_ handler: @escaping @Sendable (String) -> Void) {
        onAbort = handler
    }

    /// Registers a callback fired when an agent starts or stops an LLM API call.
    public func setOnProcessingStateChange(_ handler: @escaping @Sendable (AgentRole, Bool) -> Void) {
        onProcessingStateChange = handler
    }

    /// Registers a callback fired when an agent starts or stops executing a tool.
    /// Parameters: agent role, tool name, started (true on start, false on completion).
    public func setOnToolExecutionStateChange(_ handler: @escaping @Sendable (AgentRole, String, Bool) -> Void) {
        onToolExecutionStateChange = handler
    }

    /// Installs the per-session attachment persistence hooks. Called by the app layer
    /// once after constructing the runtime — the loader/saver closures bridge to the
    /// session-scoped `PersistenceManager`, which the runtime itself doesn't carry.
    /// Internally constructs an `AttachmentRegistry` so `create_task`, `task_update`,
    /// and `task_complete` can resolve LLM-supplied attachment IDs and ingest local
    /// files Brown produces.
    public func setAttachmentPersistence(
        loader: @escaping @Sendable (UUID, String) async -> Data?,
        saver: @escaping @Sendable (Attachment) async throws -> Void,
        urlProvider: (@Sendable (UUID, String) async -> URL?)? = nil,
        syncURLProvider: (@Sendable (UUID, String) -> URL?)? = nil
    ) {
        attachmentRegistry = AttachmentRegistry(loader: loader, saver: saver, urlProvider: urlProvider)
        attachmentURLProviderClosure = syncURLProvider
    }

    /// Pre-registers a list of attachments in the per-session registry. Used during
    /// `start(resumingTaskID:)` to seed the registry with attachments persisted on
    /// existing tasks so a fresh Brown can resolve IDs referenced from prior updates.
    public func registerAttachments(_ attachments: [Attachment]) async {
        guard let registry = attachmentRegistry else { return }
        await registry.register(contentsOf: attachments)
    }

    /// Resolves a single attachment by ID via the registry, lazy-loading bytes from
    /// disk if needed. Used by the seed-Brown path to rehydrate task-attached files.
    public func resolveAttachment(id: UUID) async -> Attachment? {
        guard let registry = attachmentRegistry else { return nil }
        return await registry.resolve(id)
    }

    /// Sets the per-file ingest cap on the active registry. App-layer Settings calls this
    /// when the user changes `SharedAppState.maxAttachmentBytesPerFile`.
    public func setMaxAttachmentBytesPerFile(_ bytes: Int) async {
        guard let registry = attachmentRegistry else { return }
        await registry.setMaxIngestBytes(bytes)
    }

    /// Sets the per-message aggregate cap. Enforced by tool-side resolvers via
    /// `currentMaxAttachmentBytesPerMessage()`.
    public func setMaxAttachmentBytesPerMessage(_ bytes: Int) {
        maxAttachmentBytesPerMessage = max(0, bytes)
    }

    /// Returns the active per-message cap. Used by tool-side resolvers to short-circuit
    /// before posting the channel message.
    public func currentMaxAttachmentBytesPerMessage() -> Int { maxAttachmentBytesPerMessage }

    /// Injects the session's MCP client host. The runtime borrows it to supply Brown's
    /// dynamic, server-provided tools each turn; lifecycle stays with the app layer.
    public func setMCPHost(_ host: MCPClientHost?) {
        mcpHost = host
    }

    /// Replaces the per-role LLM providers / model configs / API types after construction, so a
    /// model change in Settings takes effect without tearing down the session. Merges by role —
    /// roles absent from the passed dictionaries keep their current provider.
    ///
    /// Timing: Brown and its `SecurityEvaluator` (Security Agent) read `llmProviders`/`llmConfigs` at spawn,
    /// so they pick up the new model on the **next task**. The long-lived Smith and the
    /// `TaskSummarizer` are rebuilt from these same dicts on the next runtime restart
    /// (`restartForNewTask`). An in-flight agent keeps the provider it started with — a model swap
    /// never yanks a call mid-flight.
    public func setProviders(
        providers: [AgentRole: any LLMProvider],
        configurations: [AgentRole: ModelConfiguration],
        apiTypes: [AgentRole: ProviderAPIType]
    ) {
        for (role, provider) in providers { llmProviders[role] = provider }
        for (role, config) in configurations { llmConfigs[role] = config }
        for (role, apiType) in apiTypes { providerAPITypes[role] = apiType }
        // New configuration is grounds to retry: close a breaker opened by
        // missing-provider spawn failures (or by scoping failures against a backend the
        // user may just have fixed).
        scopingFailureStreak = 0
        lastScopingFailureAt = nil
    }

    /// Updates the global tool-security configuration (user Settings). Applied to each Brown at its
    /// next spawn (the per-call flag and pre-flight flag are read at spawn; the global policy too).
    /// Overrides the convergence budget (see `maxConsecutiveValidationRoundsWithoutProgress`).
    /// Exists so the budget is tunable without a rebuild — and so tests can drive the
    /// non-convergence path without scripting a full budget's worth of rejection rounds.
    public func setMaxConsecutiveValidationRoundsWithoutProgress(_ rounds: Int) {
        maxConsecutiveValidationRoundsWithoutProgress = max(1, rounds)
    }

    public func setToolSecurity(preflightScoping: Bool, perCallCheck: Bool, globalPolicy: [String: ToolPolicy]) async {
        preflightScopingEnabled = preflightScoping
        perCallCheckEnabled = perCallCheck
        globalToolPolicy = globalPolicy
        // Apply to every live worker so changes take effect immediately (no session restart) —
        // picked up on the worker's next turn (policy / scoping flag) or next tool call
        // (per-call review).
        for workerHandle in supervisor.handles(role: .brown) {
            let brown = workerHandle.agent
            await brown.setGlobalToolPolicy(globalPolicy)
            await brown.setPreflightScopingActive(preflightScoping)
            await brown.setPerCallApprovalEnabled(perCallCheck)
        }
    }

    /// Sets (or clears, with `enabled == nil`) a per-task user tool override: persists it on the task
    /// and, if that task's worker is live, pushes the updated set so it takes effect next turn. A
    /// later re-evaluation will NOT clobber it — the live registry re-applies overrides each refresh.
    public func setTaskToolOverride(taskID: UUID, tool: String, enabled: Bool?) async {
        await taskStore.setUserToolOverride(id: taskID, tool: tool, enabled: enabled)
        guard let task = await taskStore.task(id: taskID),
              let brownHandle = liveWorkerHandle(for: task) else { return }
        await brownHandle.agent.setUserToolOverrides(task.userToolOverrides ?? [:])
    }

    /// The live worker for a task: matched by the handle's own task binding or by task
    /// assignment (legacy spawn-then-assign paths don't stamp the handle). Internal so
    /// the validation coordinator (a cross-file extension) can describe worker tools.
    func liveWorkerHandle(for task: AgentTask) -> AgentSupervisor.AgentHandle? {
        supervisor.handles(role: .brown).first {
            $0.taskID == task.id || task.assigneeIDs.contains($0.id)
        }
    }

    /// Bulk variant of `setTaskToolOverride`: sets the same `enabled` value for many tools at once
    /// (one persist) and pushes the merged set to a live worker. Backs the per-MCP-server shortcut.
    public func setTaskToolOverrides(taskID: UUID, tools: [String], enabled: Bool?) async {
        await taskStore.setUserToolOverrides(id: taskID, tools: tools, enabled: enabled)
        guard let task = await taskStore.task(id: taskID),
              let brownHandle = liveWorkerHandle(for: task) else { return }
        await brownHandle.agent.setUserToolOverrides(task.userToolOverrides ?? [:])
    }

    /// Registers a callback fired when an agent comes online, with its role and tool names.
    /// Forwards a live available-tool-names update to the same sink as agent-start, so the
    /// inspector's "Available Tools" reflects the current (scoped) set rather than the static list.
    private func publishAvailableToolNames(_ role: AgentRole, _ names: [String]) {
        onAgentStarted?(role, names)
    }

    public func setOnAgentStarted(_ handler: @escaping @Sendable (AgentRole, [String]) -> Void) {
        onAgentStarted = handler
    }

    /// Registers a callback fired when any agent records a new LLM turn.
    public func setOnTurnRecorded(_ handler: @escaping @Sendable (AgentRole, LLMTurnRecord) -> Void) {
        onTurnRecorded = handler
    }

    public func setOnLearnedModelOutputLimit(_ handler: @escaping @Sendable (String, String, Int) -> Void) {
        onLearnedModelOutputLimit = handler
    }

    /// Registers a callback fired when a security evaluation is recorded.
    public func setOnEvaluationRecorded(_ handler: @escaping @Sendable (EvaluationRecord) -> Void) {
        onEvaluationRecorded = handler
    }

    /// Registers a callback fired when an agent's conversation history changes.
    public func setOnContextChanged(_ handler: @escaping @Sendable (AgentRole, [LLMMessage]) -> Void) {
        onContextChanged = handler
    }

    /// Whether the system has been aborted by Security Agent.
    public var isAborted: Bool { aborted }

    /// Clears the abort state so the system can be restarted.
    public func resetAbort() {
        aborted = false
    }

    /// Returns the role of the agent with the given ID, if it exists.
    public func roleForAgent(id: UUID) -> AgentRole? {
        supervisor.role(of: id)
    }

    /// True while the agent with this ID is tracked in the live registry. Backs the
    /// per-turn liveness lease (`ToolContext.isAgentCurrent`): an agent that has been
    /// stopped, terminated, or lost to a teardown race reads false here and self-stops
    /// at its next turn boundary instead of acting as a zombie.
    public func isAgentRegistered(_ id: UUID) -> Bool {
        supervisor.isCurrent(id)
    }

    /// Returns the currently active UUID for the given role, or nil if no such agent is running.
    public func agentIDForRole(_ role: AgentRole) -> UUID? {
        supervisor.firstHandle(role: role)?.id
    }

    /// Starts a task. Despite the historical name, this is no longer a full system
    /// restart when Smith is alive — Phase 2 of the post-incident work made Smith
    /// LONG-LIVED: starting a task cycles the WORKER (terminate old Brown, spawn a fresh
    /// one, brief it) while Smith keeps its conversation. That removes the restart
    /// amnesia that produced the 2026-07-08 double-amendment (each Smith forgot the last
    /// one's actions) and the lost-user-message hand-off machinery: Smith simply
    /// remembers. The full teardown+boot survives ONLY as the cold path (no Smith:
    /// app launch, post-stop).
    ///
    /// Routed through `lifecycleQueue` so it serializes with every other lifecycle
    /// transition. Fire-and-forget by design (tools cannot await a transition that may
    /// tear down the very agent making the call).
    public func restartForNewTask(taskID: UUID) {
        lifecycleQueue.schedule { [weak self] in
            guard let self else { return }
            // Template interception: starting a template never runs the template — it
            // clones a fresh instance and runs THAT. The template stays put (gets a
            // "started instance" note) so it can spawn another instance next time. This
            // is the single chokepoint every start path funnels through (run_task, the
            // play button, auto-advance, scheduled wakes), so all of them clone.
            let startID = await self.resolveStartTarget(taskID: taskID)
            if await self.hasLiveSmith() {
                await self.performStartTaskWithLiveSmith(taskID: startID)
                return
            }
            // Cold path — no Smith to preserve. Capture the most recent user message
            // before stopping (it may contain permissions or instructions), and the
            // session ID so Smith's pre-task planning calls get attributed to the task.
            let lastUserMessage = await self.captureLastUserMessage()
            let priorSessionID = await self.currentSessionID
            await self.performStopAll(preserveObserverCallbacks: true)
            if let priorSessionID {
                await self.usageStore.backfillTaskID(startID, forSession: priorSessionID)
            }
            await self.performStart(resumingTaskID: startID, lastUserMessage: lastUserMessage)
        }
    }

    /// If `taskID` is a template, clone a fresh instance, note it on the template, and
    /// announce the instance; return the ID to actually start (the instance, or the
    /// original for a non-template). Runs on the lifecycle queue via `restartForNewTask`.
    private func resolveStartTarget(taskID: UUID) async -> UUID {
        guard let task = await taskStore.task(id: taskID), task.isTemplate else { return taskID }
        guard let instance = await taskStore.cloneTemplateInstance(templateID: taskID) else { return taskID }
        await taskStore.addUpdate(id: taskID, message: "Started instance \(instance.id.uuidString) from this template.")
        await channel.post(ChannelMessage(
            sender: .system,
            content: instance.title,
            metadata: [
                "messageKind": .string("task_created"),
                "taskID": .string(instance.id.uuidString),
                "taskDescription": .string(instance.description),
                "clonedFromTemplate": .string(taskID.uuidString)
            ]
        ))
        return instance.id
    }

    private func hasLiveSmith() -> Bool {
        supervisor.firstHandle(role: .smith) != nil
    }

    /// The Phase 2 task-start path: cycle the worker under a surviving Smith. Runs ONLY
    /// as a lifecycle-queue item. Mirrors `performStart`'s resuming branch for the Brown
    /// side (spawn → status → assign → briefing → synthetic ack), but Smith is informed
    /// with one appended turn instead of being rebuilt from scratch.
    private func performStartTaskWithLiveSmith(taskID: UUID) async {
        guard !aborted, !stopRequested else { return }
        guard let task = await taskStore.task(id: taskID) else {
            await channel.post(ChannelMessage(
                sender: .system,
                content: "Could not start task \(taskID.uuidString): it was not found in the task store.",
                metadata: ["isError": .bool(true)]
            ))
            return
        }

        // Cycle out IDLE workers: any whose task is terminal, inactive, or gone is a
        // leftover from a previous task and frees its slot here. Workers on live tasks
        // are untouchable — capacity never evicts. Resumable outgoing tasks (e.g. a
        // scheduled-interrupt paused one) get their context saved first, preserving the
        // old full-restart path's resume-ability guarantee.
        for brownHandle in supervisor.handles(role: .brown) {
            let workerTask = await taskStore.taskForAgent(agentID: brownHandle.id)
            // Slot-holding statuses: running/validating (actively working or awaiting a
            // punch list) and awaitingReview (parked worker that provide_help /
            // review_work-reject unparks — terminating it would lose its context).
            // Paused is deliberately NOT one: the scheduled-interrupt flow pauses the
            // blocker precisely so its worker cycles out here (context saved first;
            // resume respawns from lastBrownContext).
            let occupiesSlot = workerTask.map {
                ($0.status == .running || $0.status == .validating || $0.status == .awaitingReview)
                    && $0.disposition == .active
            } ?? false
            guard !occupiesSlot else { continue }
            // Context is saved only for the workers actually being cycled out — saving
            // every live worker's context on every task start would pile up to 10
            // sequential snapshot round-trips on the lifecycle queue (agy finding).
            if let workerTask, !workerTask.status.isTerminal {
                await saveBrownContextToTask(brownID: brownHandle.id, brown: brownHandle.agent)
            }
            _ = await performTerminateAgent(id: brownHandle.id)
        }

        // The race-free capacity gate: tool-level checks are read-then-act and CAN race
        // (observed 2026-07-09: a create_task auto-start raced the auto-advance drain and
        // the loser's task stranded). This runs on the lifecycle queue, where all spawns
        // and terminations serialize — the loser is PENDED, never failed and never
        // evicting anyone; the auto-advance drain starts it when a slot frees.
        if supervisor.handles(role: .brown).count >= maxConcurrentWorkers {
            await taskStore.updateStatus(id: taskID, status: .pending)
            await channel.post(ChannelMessage(
                sender: .system,
                content: "Task \"\(task.title)\" queued — all \(maxConcurrentWorkers) worker slot(s) are busy. It will start automatically when one frees.",
                metadata: [
                    "messageKind": .string("task_queued_at_capacity"),
                    "taskID": .string(taskID.uuidString)
                ]
            ))
            return
        }

        guard let brownID = await performSpawnBrown(for: task) else {
            // An abort/stop mid-spawn is not the task's failure (same rule as performStart).
            guard !aborted, !stopRequested else { return }
            await taskStore.updateStatus(id: taskID, status: .failed)
            if let smithAgent = supervisor.firstHandle(role: .smith)?.agent {
                await smithAgent.appendUserMessage("""
                    [System: Task "\(task.title)" (ID: \(taskID.uuidString)) could not be started — the worker \
                    failed to spawn (provider unreachable or tool-scoping failed; details were posted to the \
                    channel). The task has been marked FAILED. Tell the user briefly what happened; saying \
                    "retry" will re-run it via `run_task`, which auto-resets failed tasks.]
                    """)
            }
            return
        }

        await taskStore.updateStatus(id: taskID, status: .running)
        await taskStore.assignAgent(taskID: taskID, agentID: brownID)
        let refreshed = await taskStore.task(id: taskID) ?? task

        let briefing = await composeBrownTaskBriefing(for: refreshed)
        let attachmentsForBrown = await collectTaskAttachments(refreshed)
        if let brownAgent = supervisor.agent(id: brownID) {
            await brownAgent.setAcknowledgesTaskOnFirstTurn()
            await brownAgent.appendUserMessage(briefing, attachments: attachmentsForBrown)
        }

        if let smithAgent = supervisor.firstHandle(role: .smith)?.agent {
            await smithAgent.appendUserMessage("""
                [System: Task "\(refreshed.title)" (ID: \(taskID.uuidString)) has been started. A fresh worker \
                (Brown) was spawned and briefed automatically. Do NOT call `run_task`, `create_task`, or \
                `message_brown` FOR THIS task — Brown will signal progress via task_update / task_complete, \
                and you'll get the periodic Brown-activity digest; do NOT poll. This start came from your own \
                run_task call or a scheduled timer: if the user doesn't already know it started, tell them in \
                one short line. Handle any NEW user message normally.]
                """)
        }
    }

    /// Awaits every previously-scheduled restart. Surfaced for tests / smoke
    /// scripts that need a quiescence point before asserting on runtime state.
    /// Test hook: drives the auto-advance pending-task drain directly (normally invoked
    /// from the task-termination hook).
    public func drainPendingTaskQueueForTesting() async {
        await drainPendingTaskQueue()
    }

    public func waitForPendingRestarts() async {
        await lifecycleQueue.waitForAll()
    }

    /// Returns the content of the most recent user message that Smith has not yet
    /// acknowledged, if any. A user message is considered acknowledged once Smith
    /// has posted any Smith→user message after it, so we avoid re-forwarding
    /// already-answered requests across a restart.
    private func captureLastUserMessage() async -> String? {
        let messages = await channel.allMessages()
        for message in messages.reversed() {
            if case .agent(.smith) = message.sender,
               case .user = message.recipient {
                // Hit Smith's most recent reply to the user without finding a
                // newer user message — nothing unhandled to forward.
                return nil
            }
            // A task-created banner means Smith already acted on the most recent user message
            // by turning it into a task; don't re-forward that message as prose (it would
            // double-process). Reached before any user message means the latest one is handled.
            if case .string("task_created") = message.metadata?["messageKind"] {
                return nil
            }
            if case .user = message.sender {
                // Buffer-origin echoes are delivered (and turned into tasks) via the
                // pending-user-message drain, not this prose path — never re-forward them.
                if case .bool(true) = message.metadata?["bufferOrigin"] { return nil }
                return message.content
            }
        }
        return nil
    }

    /// Starts the Smith agent and the monitoring timer.
    /// - Parameter resumingTaskID: When set, skips the "ask user" preamble and immediately
    ///   instructs Smith to spawn Brown and begin work on this task.
    /// - Parameter lastUserMessage: The most recent user message captured before a restart,
    ///   included in the initial instruction so new Smith doesn't lose user context.
    public func start(resumingTaskID: UUID? = nil, lastUserMessage: String? = nil) async {
        await lifecycleQueue.run { [weak self] in
            await self?.performStart(resumingTaskID: resumingTaskID, lastUserMessage: lastUserMessage)
        }
    }

    /// Unwinds the partial state of a `performStart` that failed before any agent was
    /// registered: power assertion, summarizer, generation, and the channel's session
    /// stamp. Nothing else exists yet by construction (agents register after the guards),
    /// so this is the complete failure-path teardown.
    private func abandonFailedStart() async {
        await powerManager?.shutdown()
        powerManager = nil
        // `taskSummarizer` is deliberately KEPT (matching performStopAll): late
        // summarize calls for tasks that terminated around the stop/start boundary
        // read it fire-and-forget, and nilling it here would silently skip them.
        // The next successful start overwrites it anyway.
        _ = supervisor.endGeneration()
        await channel.setCurrentSessionID(nil)
    }

    /// The actual start implementation. Runs ONLY as a lifecycle-queue item (or from
    /// another implementation already inside one) — never call directly from a public
    /// entry point.
    private func performStart(resumingTaskID: UUID? = nil, lastUserMessage: String? = nil) async {
        guard !startInProgress, smith == nil else {
            // Bailing — but if we were asked to resume a specific task, don't silently drop
            // it (the historical `guard smith == nil` drop bug). Re-route it through the
            // restart queue so it runs once the in-flight start has finished.
            if let resumingTaskID {
                restartForNewTask(taskID: resumingTaskID)
            }
            return
        }
        guard !aborted, !stopRequested else { return }
        startInProgress = true
        defer { startInProgress = false }

        // Mint a fresh session ID for this run. Propagated to every agent, evaluator,
        // and summarizer so their UsageRecords carry it, and published to the
        // MessageChannel so every posted message is auto-stamped with the session.
        let generation = supervisor.beginGeneration()
        let sessionID = generation.sessionID
        await channel.setCurrentSessionID(sessionID)

        // Delivery tracking is per-Smith by definition (a fresh Smith has incorporated
        // nothing), so reset it at generation start. Without this, a drain suspended in
        // `acceptChannelMessage` while a stopAll interleaved could re-insert a stale ID
        // AFTER the stop's clear, and the next session's drain would skip that buffered
        // message until yet another stop cycle (agy review finding).
        deliveredUserMessageChannelIDs.removeAll()

        let powerMgr = PowerAssertionManager(taskStore: taskStore)
        await powerMgr.start()
        powerManager = powerMgr

        // Create the TaskSummarizer only if a summarizer model is explicitly configured.
        // If not configured, task summarization is silently skipped.
        if let summarizerProvider = llmProviders[.summarizer],
           let summarizerConfig = llmConfigs[.summarizer] {
            taskSummarizer = TaskSummarizer(
                provider: summarizerProvider,
                memoryStore: memoryStore,
                channel: channel,
                contextWindowSize: summarizerConfig.contextWindowSize,
                maxOutputTokens: summarizerConfig.maxTokens,
                usageStore: usageStore,
                configuration: summarizerConfig,
                providerType: providerAPITypes[.summarizer]?.rawValue ?? "",
                sessionID: sessionID
            )
        } else {
            taskSummarizer = nil
        }

        guard let smithConfig = llmConfigs[.smith],
              let provider = llmProviders[.smith] else {
            await channel.post(ChannelMessage(sender: .system, content: "No Smith provider configured — cannot start."))
            // A start that fails before any agent exists must not leave a live generation
            // behind: `currentSessionID` would read as "running", and a later tool-driven
            // spawnBrown would register a worker into a session that never started Smith
            // (codex review finding).
            await abandonFailedStart()
            return
        }

        let id = UUID()
        let followUpScheduler = FollowUpScheduler()
        let context = makeToolContext(agentID: id, role: .smith, followUpScheduler: followUpScheduler, currentResumingTaskID: resumingTaskID)

        // Smith only wakes for: private messages (user/Brown/Security Agent→Smith), system termination notices.
        // Public Brown messages, tool_request/tool execution messages, and security review notices
        // are completely filtered out — they generate too much noise and don't need Smith's attention.
        let smithMessageFilter: @Sendable (ChannelMessage) -> Bool = { message in
            // Drop Smith's own outgoing messages — they are published to the channel and would
            // immediately re-wake Smith, producing an infinite loop of repeated messages.
            if case .agent(let role) = message.sender, role == .smith {
                return false
            }
            // Drop all public messages from Brown, Security Agent, or Summarizer, except online
            // announcements which Smith needs for coordination. Summarizer results are
            // persisted to the memory store and task record — Smith doesn't need them
            // in its conversation history (and they can distract from pending user messages).
            if case .agent(let role) = message.sender, message.recipientID == nil,
               role == .brown || role == .securityAgent || role == .summarizer {
                guard case .string(let kind) = message.metadata?["messageKind"],
                      kind == "agent_online" else { return false }
            }
            // Drop tool_request messages (Brown's approval requests).
            if case .string(let kind) = message.metadata?["messageKind"], kind == "tool_request" {
                return false
            }
            // Drop tool execution trace messages.
            if message.metadata?["tool"] != nil {
                return false
            }
            // For system messages, only pass through diagnostics directly relevant to Smith:
            // agent lifecycle events (errors, termination), rate-limit notices, and
            // system guidance injected by tools (e.g., task_update_guidance).
            if case .system = message.sender {
                if case .string(let kind) = message.metadata?["messageKind"],
                   kind == "task_update_guidance" {
                    // Always pass through — this is system guidance for Smith.
                } else {
                    let c = message.content
                    guard c.hasPrefix("Agent ") || c.hasPrefix("Rate limit:") else { return false }
                }
            }
            return true
        }

        let smithAgent = AgentActor(
            id: id,
            configuration: AgentConfiguration(
                role: .smith,
                llmConfig: smithConfig,
                providerAPIType: providerAPITypes[.smith] ?? .openAICompatible,
                systemPrompt: SmithBehavior.systemPrompt(autoAdvanceEnabled: autoAdvanceEnabled),
                toolNames: SmithBehavior.toolNames,
                suppressesRawTextToChannel: true,
                pollInterval: agentTuning[.smith]?.pollInterval ?? 20,
                messageDebounceInterval: agentTuning[.smith]?.messageDebounceInterval ?? 1,
                messageAcceptFilter: smithMessageFilter,
                maxToolCallsPerIteration: agentTuning[.smith]?.maxToolCalls ?? 100
            ),
            provider: provider,
            tools: SmithBehavior.tools(validatorCatalogSummary: validatorCatalogSummary()),
            toolContext: context
        )
        await followUpScheduler.set(agent: smithAgent)
        await smithAgent.setUsageStore(usageStore)
        await smithAgent.setSessionID(currentSessionID)

        // Auto-run wake fires bypass Smith and drive `restartForNewTask` directly. This
        // is what "scheduled task → run at fire time" was always meant to be: fully
        // mechanical, no LLM in the loop. Smith learns about the new run when its fresh
        // process boots with `resumingTaskID` set (auto-spawned Brown, briefing pre-seeded).
        //
        // Gated on "nothing in flight": if a task is currently running or awaiting
        // Smith's review, we do NOT yank it. The wake's task was already promoted to
        // `.pending` by `AgentActor.checkScheduledWake`; it sits in the queue and the
        // runtime's normal auto-advance (after the current task finishes via
        // `review_work(accepted: true)`) picks it up. We post a system banner so the user
        // sees that the schedule fired but was deferred.
        await smithAgent.setOnAutoRunTask { [weak self] taskID in
            guard let self else { return }
            await self.dispatchAutoRunWake(taskID: taskID)
        }
        if let turnCallback = onTurnRecorded {
            await smithAgent.setOnTurnRecorded { turn in turnCallback(.smith, turn) }
        }
        if let contextCallback = onContextChanged {
            await smithAgent.setOnContextChanged { messages in contextCallback(.smith, messages) }
        }
        // Brown-activity digest assembler: pulls recent channel messages since the cutoff and
        // formats a brief summary that Smith can react to without polling. Returns nil when
        // there's no Brown alive to summarize OR when the window contains no fresh activity —
        // either way the digest is suppressed. Gating on Brown's presence avoids the misleading
        // "Brown made 0 tool calls — likely deep in tool work or stuck" message that fires when
        // no Brown exists at all.
        await smithAgent.setSmithDigestProvider { [weak self] since in
            guard let self else { return nil }
            return await self.assembleDigestIfBrownAlive(since: since)
        }
        // Cancel any task-scoped wakes when the task transitions to a terminal status the first time.
        // Also drain `pendingScheduledRunQueue` so any deferred scheduled task — or a paused
        // task awaiting resume after an interrupt — runs immediately when the in-flight slot
        // frees up. The scheduled-run drain runs INDEPENDENTLY of `autoAdvanceEnabled`
        // (scheduled wakes are a commitment, not a deferred suggestion). The pending-task
        // drain that follows IS gated on `autoAdvanceEnabled` and only runs when the
        // scheduled drain didn't claim the slot — that's the auto-advance step Smith's
        // prompt promises after `review_work(accepted: true)`.
        let scheduler = followUpScheduler
        await taskStore.setOnTaskTerminated { [weak self] taskID in
            // Fire-and-forget Task to stay synchronous from TaskStore's view.
            // Both calls are non-throwing today; if either ever gains a `throws`
            // signature, wrap them in `do { try await ... } catch { os_log(.error) }`
            // so the failure surfaces rather than vanishing into the unstructured
            // Task. (L3 from the 2026-04-27 concurrency review.)
            Task {
                await scheduler.cancelWakesForTask(taskID)
                let kicked = await self?.drainPendingScheduledRunQueue() ?? false
                if !kicked {
                    await self?.drainPendingTaskQueue()
                }
                // Task boundaries are the long-lived Smith's compaction points: the
                // terminated task's play-by-play just became history (Phase 2).
                await self?.autoCompactSmithIfNeeded()
            }
        }

        // Wire timer lifecycle callbacks from Smith's actor into the runtime's event log so
        // the timers UI / history view can render scheduled / fired / cancelled rows.
        let eventLog = timerEventLog
        let timerSurfaceContext = onTimerEventForChannel
        await smithAgent.setTimerCallbacks(
            onScheduled: { wake in
                Task {
                    let event = TimerEvent.scheduled(from: wake)
                    await eventLog.record(event)
                    await timerSurfaceContext?(event)
                }
            },
            onFired: { primary, all in
                Task {
                    let event = TimerEvent.fired(primary: primary, batchSize: all.count)
                    await eventLog.record(event)
                    await timerSurfaceContext?(event)
                }
            },
            onCancelled: { wake, cause in
                Task {
                    let event = TimerEvent.cancelled(wake: wake, cause: cause)
                    await eventLog.record(event)
                    await timerSurfaceContext?(event)
                }
            }
        )

        supervisor.register(id: id, role: .smith, agent: smithAgent)

        let subID = await channel.subscribe { [weak smithAgent] message in
            guard let smithAgent else { return }
            Task { await smithAgent.receiveChannelMessage(message) }
        }
        supervisor.addSubscription(subID, to: id)

        // Remove a buffered user message from durable storage only when Smith incorporates it
        // into the conversation — not when it's merely accepted into the volatile pending queue.
        await smithAgent.setOnInboundUserMessagesIncorporated { [weak self] channelMessageIDs in
            Task { await self?.handleInboundUserMessagesIncorporated(channelMessageIDs) }
        }

        // Replay persisted wakes onto the freshly-built Smith. Runs on every `start()` —
        // cold launch AND `restartForNewTask` — so wakes survive run_task restarts in
        // addition to app quit. The disk file is kept current via `onTimerEventForChannel`.
        // Without this, every `restartForNewTask` silently dropped the previous Smith's
        // in-memory wake list, so a second-or-later scheduled task simply never fired.
        //
        // The replay is FILTERED: the disk snapshot can lag the in-memory list (the
        // persist runs via a MainActor hop that races the restart's teardown), so a wake
        // that already fired can come back from disk and fire again on the fresh Smith —
        // which restarts, replays, and fires it again, forever. That resurrection loop
        // produced 31 full runtime generations in 8 seconds on 2026-07-08.
        if let loader = loadPersistedWakes {
            let wakes = await loader()
            if !wakes.isEmpty {
                let replayable = await replayableWakes(from: wakes, resumingTaskID: resumingTaskID)
                if !replayable.isEmpty {
                    await smithAgent.restoreScheduledWakes(replayable)
                }
            }
        }

        // Re-seed the pending-scheduled-run queue from disk so wakes that fired and were
        // deferred (or paused tasks queued for resume after an interrupt) still run when
        // the slot frees up. The queue is per-session, so each window's runtime restores
        // its own list — no cross-session bleed.
        if let loader = loadPendingScheduledRunQueue {
            let queue = await loader()
            if !queue.isEmpty {
                pendingScheduledRunQueue = queue
            }
        }
        // Belt-and-suspenders: re-arm any `.scheduled` task that doesn't yet have a wake
        // after disk replay (covers stale snapshots, first-run, etc.). Past-due `.scheduled`
        // tasks get promoted to `.pending` so the cold-launch instruction surfaces them.
        await rearmScheduledTaskWakes(excluding: resumingTaskID)

        // Mark any leftover running tasks as interrupted — no Brown is running them anymore.
        // (Clean shutdowns mark these interrupted via AppViewModel; this catches crashes/force-quits.)
        // Skip the resuming task if present — it will be set to running momentarily.
        let allTasks = await taskStore.allTasks()
        let activeTasks = allTasks.filter { $0.disposition == .active }
        let leftoverRunningTasks = activeTasks.filter { $0.status == .running && $0.id != resumingTaskID }
        for task in leftoverRunningTasks {
            await taskStore.updateStatus(id: task.id, status: .interrupted)
        }

        // Validation is idempotent and restartable: tasks caught mid-validation by a
        // quit/crash re-enqueue from their sticky-verdict state (partial rounds were
        // never persisted as conclusions).
        for task in activeTasks where task.status == .validating {
            startTaskValidation(taskID: task.id)
        }

        // Cold-boot auto-advance: with "Auto-run next task" on, pending tasks start
        // filling worker slots at launch — Smith reports them, he does not gatekeep them
        // (previously they sat until Smith or the user acted; observed 2026-07-09 as
        // "asks if I want to run them"). The restarts enqueue behind this start.
        await drainPendingTaskQueue()

        // Pre-register every persisted task attachment so a fresh Brown spawned during
        // this run can resolve IDs referenced by `task_update` / `task_complete` calls
        // that originally landed in a prior session. Bytes are lazy-loaded on first
        // resolve via the registry's loader closure.
        if attachmentRegistry != nil {
            let allTaskAttachments: [Attachment] = activeTasks.flatMap { task in
                task.descriptionAttachments
                    + task.updates.flatMap { $0.attachments }
                    + task.resultAttachments
            }
            if !allTaskAttachments.isEmpty {
                await registerAttachments(allTaskAttachments)
            }
        }

        let initialInstruction: String

        // Fast path: restarting for a specific task (triggered by run_task).
        // Auto-spawn Brown, deliver task briefing, and tell Smith to monitor.
        if let resumingTaskID {
            if var resumingTask = await taskStore.task(id: resumingTaskID) {
                // Auto-spawn Brown and deliver the task briefing
                let brownSpawned: Bool
                if let brownID = await performSpawnBrown(for: resumingTask) {
                    await taskStore.updateStatus(id: resumingTaskID, status: .running)
                    await taskStore.assignAgent(taskID: resumingTaskID, agentID: brownID)
                    // Re-read to get the latest state (includes any amendments from run_task)
                    resumingTask = await taskStore.task(id: resumingTaskID) ?? resumingTask

                    // Seed Brown's conversation directly from the task store. We used to
                    // post this as a Smith → Brown channel message, which duplicated the
                    // New Task banner's description in the user's transcript. The briefing
                    // is mechanically `task.title + task.description` plus optional resume
                    // context — all already in the task store; Brown is the only consumer
                    // (Security Agent reads task.description directly). Direct seeding keeps the
                    // data flow clean and stays symmetric with `rebuildContextFromTask`.
                    let briefing = await composeBrownTaskBriefing(for: resumingTask)
                    let attachmentsForBrown = await collectTaskAttachments(resumingTask)
                    if let brownAgent = supervisor.agent(id: brownID) {
                        // Synthetic ack runs BEFORE any LLM call on Brown's first run-loop
                        // tick — set it before seeding so the synthetic-tool-call branch
                        // doesn't accidentally race with the seeded user message.
                        await brownAgent.setAcknowledgesTaskOnFirstTurn()
                        await brownAgent.appendUserMessage(briefing, attachments: attachmentsForBrown)
                    }
                    brownSpawned = true
                } else {
                    brownSpawned = false
                }

                // Build Smith's initial instruction
                var smithParts: [String] = []

                let hasMemories = !(resumingTask.relevantMemories?.isEmpty ?? true)
                let hasPriorTasks = !(resumingTask.relevantPriorTasks?.isEmpty ?? true)
                if hasMemories || hasPriorTasks {
                    smithParts.append("""
                        ## Other information

                        The information below is NOT part of this task and does NOT reflect the user's intent for this task.
                        It is provided only because it MIGHT be a source of relevant context - but it also might be completely
                        useless and unrelated.

                        Use it with caution.

                        DO NOT ASSUME that any part of it might also apply to the current task. Rather, if there are things that
                        MIGHT apply, ASK the user for clarification right away.
                        """)
                    if let memories = resumingTask.relevantMemories, !memories.isEmpty {
                        let memoryLines = memories.map { "- \($0.content) (similarity: \(String(format: "%.2f", $0.similarity)))" }
                        smithParts.append("### Relevant memories:\n\(memoryLines.joined(separator: "\n"))")
                    }
                    if let priorTasks = resumingTask.relevantPriorTasks, !priorTasks.isEmpty {
                        let taskLines = priorTasks.map { task in
                            "- \(task.title): \(task.summary) (similarity: \(String(format: "%.2f", task.similarity)))"
                        }
                        smithParts.append("### Relevant prior task summaries:\n\(taskLines.joined(separator: "\n"))")
                    }
                }

                if brownSpawned {
                    smithParts.append("""
                        Brown is already working on task "\(resumingTask.title)" (ID: \(resumingTaskID.uuidString)). \
                        The task description and any prior progress have been delivered to Brown automatically. \
                        Do NOT call `run_task`, `create_task`, or `message_brown` FOR THIS task — Brown is already briefed and working. \
                        This restriction applies ONLY to this in-progress task. If the user sends a NEW message, handle it normally: \
                        create a task for genuine new work, or simply reply if they're answering a question or chatting — use your judgment, and don't force a task for a clarification. \
                        Brown will signal progress via task_update / task_complete; you'll also get an automatic 10-minute Brown-activity digest. Do NOT poll. \
                        The user is already informed about THIS task. Don't inform them about it a 2nd time.
                        """)
                } else {
                    // An abort/stop mid-spawn is not the task's failure: leave its status
                    // alone and stop building this generation — the queued stopAll owns
                    // the teardown of whatever exists.
                    guard !aborted, !stopRequested else { return }
                    // A failed spawn must not leave the task looking like ordinary pending
                    // work the user is waiting on — that's what let a stranded reminder be
                    // mistaken for "the task the user means" after the 2026-07-08 outage.
                    // Mark it failed; `run_task` auto-resets failed tasks, so retrying is
                    // one call once the provider is reachable again.
                    await taskStore.updateStatus(id: resumingTaskID, status: .failed)
                    smithParts.append("""
                        Failed to start task "\(resumingTask.title)" (ID: \(resumingTaskID.uuidString)) — Brown could not be spawned \
                        (LLM provider unreachable or the security agent could not scope tools; details were posted to the channel). \
                        The task has been marked FAILED. Send the user a short message explaining the task could not start and why, \
                        and that saying "retry" will run it again (via `run_task`, which auto-resets failed tasks). \
                        IMPORTANT: this failure applies ONLY to that one task. If the user sends a NEW message, handle it normally — \
                        create a task for genuine new work, or simply reply if they're chatting. Do NOT attach a new request to the failed task.
                        """)
                }

                if let userMsg = lastUserMessage, !userMsg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    smithParts.append("""
                        UNHANDLED USER MESSAGE: the user sent the following message and no Smith has acted on it yet. \
                        It arrived before this restart, but it is a LIVE request, not background context — handle it now, \
                        exactly as if it had just arrived. If it describes new work, create a NEW task for it (do not fold \
                        it into the task above). If it's a question or chat, reply to the user.
                        ---
                        \(userMsg)
                        ---
                        """)
                }

                initialInstruction = smithParts.joined(separator: "\n\n")
            } else {
                initialInstruction = """
                    The system restarted for task \(resumingTaskID.uuidString) but the task was not found in the store. \
                    Send the user a message explaining the issue.
                    """
            }
        } else {
            // Cold launch — gather all active tasks by status and surface everything to Smith.
            let awaitingReviewTasks = activeTasks.filter { $0.status == .awaitingReview }
            let interruptedTasks = activeTasks.filter { $0.status == .interrupted }
            // Templates are `.pending` launchers, not queued work — exclude them from the
            // startup pending list so Smith isn't told they're being auto-started (they
            // aren't; they run only on explicit action).
            let pendingTasks = activeTasks.filter { $0.status == .pending && !$0.isTemplate }
            let pausedTasks = activeTasks.filter { $0.status == .paused }
            let scheduledTasks = activeTasks.filter { $0.status == .scheduled }
            let recentFailed = Array(
                activeTasks
                    .filter { $0.status == .failed }
                    .sorted { $0.updatedAt > $1.updatedAt }
                    .prefix(5)
            )

            // Note: re-arming scheduled-task wakes happens earlier in `start()` via
            // `rearmScheduledTaskWakes()` — it runs on every restart path, not just cold launch.
            let nowAtBoot = Date()

            // If autoRunInterruptedTasks is enabled and no awaitingReview task needs attention
            // first, resume the tasks that were interrupted when this session came up. Every
            // task that was mid-run at quit should restart — not just the first — capped by
            // worker capacity. What doesn't fit now goes onto `launchResumeQueue` and resumes
            // as running tasks finish (`drainPendingTaskQueue`). This is scoped to the LAUNCH
            // batch on purpose: a task the user Stops mid-session also becomes `.interrupted`,
            // but it never enters this queue, so it stays stopped until the next launch.
            var autoResumedTasks: [AgentTask] = []
            if autoRunInterruptedTasks, awaitingReviewTasks.isEmpty {
                var remaining = interruptedTasks.sorted { $0.createdAt < $1.createdAt }
                while supervisor.handles(role: .brown).count < maxConcurrentWorkers, let task = remaining.first {
                    guard let brownID = await performSpawnBrown(for: task) else { break }
                    remaining.removeFirst()
                    await taskStore.updateStatus(id: task.id, status: .running)
                    await taskStore.assignAgent(taskID: task.id, agentID: brownID)

                    let briefing = await composeBrownTaskBriefing(for: task)
                    let attachmentsForBrown = await collectTaskAttachments(task)
                    if let brownAgent = supervisor.agent(id: brownID) {
                        await brownAgent.setAcknowledgesTaskOnFirstTurn()
                        await brownAgent.appendUserMessage(briefing, attachments: attachmentsForBrown)
                    }
                    autoResumedTasks.append(task)
                }
                // The overflow drains as slots free.
                launchResumeQueue = remaining.map(\.id)
            }

            // Build Smith's initial instruction with ALL task categories
            var parts: [String] = []

            if !autoResumedTasks.isEmpty {
                let list = autoResumedTasks
                    .map { "\"\($0.title)\" (ID: \($0.id.uuidString))" }
                    .joined(separator: "\n- ")
                let lead = autoResumedTasks.count == 1
                    ? "Brown has automatically resumed the interrupted task:"
                    : "Brown workers have automatically resumed \(autoResumedTasks.count) interrupted tasks:"
                parts.append("""
                    \(lead)
                    - \(list)
                    Do NOT call `message_brown` for these — the workers are already briefed and working. \
                    They signal progress via task_update / task_complete; you'll also get an automatic 10-minute Brown-activity digest. Do NOT poll.
                    """)
            }

            // A help request also parks in awaitingReview, but it's a blocker, not finished
            // work — split it out so Smith is pointed at `provide_help`, not `review_work`.
            let helpRequestTasks = awaitingReviewTasks.filter { $0.helpRequest != nil }
            let reviewTasks = awaitingReviewTasks.filter { $0.helpRequest == nil }
            if !reviewTasks.isEmpty {
                let taskList = reviewTasks.map { task in
                    var entry = "- \(task.title) (id: \(task.id.uuidString))"
                    if let result = task.result {
                        entry += "\n  Result: \(result)"
                    }
                    if let commentary = task.commentary {
                        entry += "\n  Commentary: \(commentary)"
                    }
                    return entry
                }.joined(separator: "\n")
                parts.append("\(reviewTasks.count) task(s) are awaiting your review:\n\(taskList)\nReview each and call `review_work`.")
            }
            if !helpRequestTasks.isEmpty {
                let taskList = helpRequestTasks.map { task in
                    "- \(task.title) (id: \(task.id.uuidString))\n  \(task.helpRequest ?? "")"
                }.joined(separator: "\n")
                parts.append("\(helpRequestTasks.count) task(s) have a BLOCKER from Brown awaiting your help (not a review):\n\(taskList)\nResolve each with `provide_help`, or `message_user` first if you need something from the user. Do NOT call `review_work` on these.")
            }

            // Show interrupted tasks that were NOT auto-resumed (e.g. beyond worker capacity)
            let resumedIDs = Set(autoResumedTasks.map { $0.id })
            let remainingInterrupted = interruptedTasks.filter { !resumedIDs.contains($0.id) }
            if !remainingInterrupted.isEmpty {
                let list = remainingInterrupted
                    .map { task in
                        var entry = "- \(task.title) (id: \(task.id.uuidString)) — interrupted"
                        if !task.description.isEmpty {
                            entry += "\n  Description: \(task.description)"
                        }
                        if let lastUpdate = task.updates.last {
                            entry += "\n  Last update: \(lastUpdate.message)"
                        }
                        return entry
                    }
                    .joined(separator: "\n")
                parts.append("The following task(s) were interrupted and can be resumed with `run_task`:\n\(list)")
            }

            if !pendingTasks.isEmpty {
                let list = pendingTasks
                    .map { task in
                        var entry = "- \(task.title) (id: \(task.id.uuidString))"
                        if !task.description.isEmpty {
                            entry += "\n  Description: \(task.description)"
                        }
                        return entry
                    }
                    .joined(separator: "\n")
                if autoAdvanceEnabled {
                    parts.append("""
                        The following pending task(s) are being started AUTOMATICALLY by the system \
                        (auto-run is enabled) — do NOT ask the user whether to run them, in what order, \
                        or call `run_task` on them yourself. Just mention them as already underway:
                        \(list)
                        """)
                } else {
                    parts.append("The following task(s) are pending and waiting to be started (auto-run is OFF — ask the user whether to start them):\n\(list)")
                }
            }

            if !pausedTasks.isEmpty {
                let list = pausedTasks
                    .map { task in
                        var entry = "- \(task.title) (id: \(task.id.uuidString)) — paused"
                        if !task.description.isEmpty {
                            entry += "\n  Description: \(task.description)"
                        }
                        if let lastUpdate = task.updates.last {
                            entry += "\n  Last update: \(lastUpdate.message)"
                        }
                        return entry
                    }
                    .joined(separator: "\n")
                parts.append("The following task(s) are paused:\n\(list)")
            }

            if !scheduledTasks.isEmpty {
                let formatter = RuntimeDateFormatters.timestamp
                let list = scheduledTasks
                    .compactMap { task -> String? in
                        guard let fireAt = task.scheduledRunAt, fireAt > nowAtBoot else { return nil }
                        return "- \(task.title) (id: \(task.id.uuidString)) — scheduled to run at \(formatter.string(from: fireAt))"
                    }
                    .joined(separator: "\n")
                if !list.isEmpty {
                    parts.append("The following task(s) are scheduled to run at a specific time. The runtime will fire a timer at the appointed time and instruct you to call `run_task`. Do NOT call `run_task` on these early unless the user asks:\n\(list)")
                }
            }

            if !recentFailed.isEmpty {
                let list = recentFailed
                    .map { task in
                        var entry = "- \(task.title) (id: \(task.id.uuidString))"
                        if !task.description.isEmpty {
                            entry += "\n  Description: \(task.description)"
                        }
                        return entry
                    }
                    .joined(separator: "\n")
                parts.append("The following task(s) previously failed (most recent first):\n\(list)")
            }

            if parts.isEmpty {
                initialInstruction = """
                    No tasks are pending. Introduce yourself with "Hello <user's nickname>, how can I help?" - and nothing more.
                    """
            } else {
                initialInstruction = """
                    \(parts.joined(separator: "\n\n"))

                    Send the user a single private message (recipient_id: "user") summarizing the situation \
                    and asking how they would like to proceed. \
                    Then wait for the user to reply before taking action on any tasks. \
                    When the user asks you to continue or run a task, use `list_tasks` to get the full task \
                    details (including the description) before proceeding — do not ask the user for information \
                    that is already in the task.
                    """
            }
        }

        // Final barrier: don't launch Smith's run loop if an abort or stop arrived during
        // the awaits above. Smith is registered but never started; the queued stopAll
        // unsubscribes and drops it (stop() on a never-started agent is a no-op).
        guard !aborted, !stopRequested else { return }
        await smithAgent.start(initialInstruction: initialInstruction)
        onAgentStarted?(.smith, smithAgent.toolNames)

        await channel.post(ChannelMessage(
            sender: .system,
            content: "System online. Smith agent active.",
            metadata: [
                "messageKind": .string("restart_chrome"),
                "restartChromeKind": .string("system_online")
            ]
        ))

        monitoringTimer = MonitoringTimer(
            interval: 60,
            channel: channel,
            taskStore: taskStore
        )
        await monitoringTimer?.start()

        // Cold-launch drain: if the queue restored from disk has entries AND nothing is
        // currently in flight, kick off the head right now. We hop through Task.detached
        // with a tiny grace so this `start()` call fully unwinds before
        // `drainPendingScheduledRunQueue` calls `restartForNewTask` (which itself wraps
        // a `stopAll() + start()` in a detached task — calling it from within `start()`
        // would race the in-progress build).
        if !pendingScheduledRunQueue.isEmpty {
            Task.detached { [weak self] in
                try? await Task.sleep(nanoseconds: 100_000_000)
                await self?.drainPendingScheduledRunQueue()
            }
        }

        // Reseed the pending-user-message buffer from disk (crash / cold-launch recovery) and
        // deliver any buffered messages now that Smith is running. Union by id so messages
        // enqueued during this start's window (already in memory) are neither lost nor
        // duplicated by the disk copy; FIFO restored by receive time. Runs AFTER the
        // "System online" post above so the transcript ordering is correct. Inline (not
        // detached) because delivery via `acceptChannelMessage` does not trigger a restart.
        if let loader = loadPendingUserMessages {
            let disk = await loader()
            if !disk.isEmpty {
                let known = Set(pendingUserMessages.map { $0.id })
                let merged = pendingUserMessages + disk.filter { !known.contains($0.id) }
                pendingUserMessages = merged.sorted { $0.receivedAt < $1.receivedAt }
            }
        }
        await drainPendingUserMessages()
    }

    /// Sends a user message (with optional attachments) to Smith.
    ///
    /// The message is always enqueued into the persisted pending-user-message buffer, a UI-echo
    /// copy is posted to the channel immediately (marked `bufferOrigin` so the live
    /// subscription ignores it — the buffer's drain is the sole delivery path), and the drain
    /// is kicked. This removes the old check-then-act race: previously `sendUserMessage` posted
    /// directly, and a message landing while Smith was stopped/starting hit `AgentActor`'s
    /// `guard isRunning` and was silently dropped. Now delivery is deferred until Smith can
    /// actually accept it, and the message survives an app quit or crash in between.
    public func sendUserMessage(_ text: String, attachments: [Attachment] = []) async {
        await powerManager?.activityOccurred()
        if let registry = attachmentRegistry, !attachments.isEmpty {
            await registry.register(contentsOf: attachments)
        }

        let pending = PendingUserMessage(
            channelMessageID: UUID(),
            text: text,
            attachments: attachments,
            receivedAt: Date()
        )
        pendingUserMessages.append(pending)
        if pendingUserMessages.count > Self.pendingUserMessageSoftCap {
            stopLogger.notice("pendingUserMessages large count=\(self.pendingUserMessages.count, privacy: .public)")
        }
        await persistPendingUserMessages?(pendingUserMessages)

        // Immediate UI echo so the message appears in the transcript right away even during a
        // slow startup. `bufferOrigin` keeps the live subscription from delivering it to Smith
        // (the drain owns delivery, tied to acceptance); `pendingUserMessageID` links it.
        // Timestamp is the receive time so the transcript stays chronological regardless of
        // when the drain later runs.
        await channel.post(ChannelMessage(
            id: pending.channelMessageID,
            timestamp: pending.receivedAt,
            sender: .user,
            recipientID: smithID,
            recipient: .agent(.smith),
            content: text,
            attachments: attachments,
            metadata: [
                "bufferOrigin": .bool(true),
                "pendingUserMessageID": .string(pending.id.uuidString)
            ]
        ))

        await drainPendingUserMessages()
    }

    /// The single delivery path for `pendingUserMessages`. Delivers buffered messages to Smith
    /// in FIFO order once it is running, removing each from the persisted queue only after
    /// Smith *accepts* it — not merely after the channel post. (The live subscription delivers
    /// asynchronously via an unstructured `Task`, and Smith can stop before that Task runs, so
    /// "posted" is not "accepted".) Idempotent and safe to call repeatedly. Re-checks Smith
    /// liveness after every suspension so a mid-drain teardown leaves the remaining messages
    /// buffered rather than losing them.
    public func drainPendingUserMessages() async {
        guard !isDrainingUserMessages else { return }

        // No Smith yet. Kick a cold start (whose end-of-start drain will deliver) — but ONLY
        // when a start can actually succeed. Kicking while aborted or without a configured
        // Smith would spin a start that bails at its early guards, re-kicked forever by each
        // new message. Route through `lifecycleQueue` so it serializes with `restartForNewTask`.
        guard let currentSmith = smith, let startSmithID = smithID else {
            if !startInProgress, !aborted,
               llmProviders[.smith] != nil, llmConfigs[.smith] != nil,
               !pendingUserMessages.isEmpty {
                lifecycleQueue.schedule { [weak self] in
                    await self?.performStart()
                }
            }
            return
        }

        // Not running yet (subscribed-but-not-running startup window). Leave everything
        // buffered; the in-flight / next `start()`'s end-of-start drain delivers it.
        guard await currentSmith.running else { return }

        isDrainingUserMessages = true
        defer { isDrainingUserMessages = false }

        // Deliver every not-yet-delivered buffered message to Smith. Delivery does NOT remove
        // the message from the persisted buffer — that happens only when Smith incorporates it
        // (`handleInboundUserMessagesIncorporated`), so a teardown or crash before incorporation
        // redelivers rather than loses it. `deliveredUserMessageChannelIDs` stops us re-handing
        // the same message to a Smith that has it queued but hasn't processed it yet. Re-snapshot
        // each pass so messages appended mid-drain are picked up; stop when a pass delivers none.
        while !Task.isCancelled {
            let undelivered = pendingUserMessages.filter { !deliveredUserMessageChannelIDs.contains($0.channelMessageID) }
            if undelivered.isEmpty { break }

            var deliveredAny = false
            for pending in undelivered {
                if Task.isCancelled { break }
                // Re-verify the same Smith is still current and running after each suspension —
                // `stopAll`/abort can tear it down while we're awaiting.
                guard let liveSmith = smith, smithID == startSmithID, await liveSmith.running else { return }
                // The incorporation callback may have removed/consumed it during an await.
                guard pendingUserMessages.contains(where: { $0.id == pending.id }),
                      !deliveredUserMessageChannelIDs.contains(pending.channelMessageID) else { continue }

                var resolved: [Attachment] = []
                if let registry = attachmentRegistry, !pending.attachments.isEmpty {
                    // Re-register the (byte-stripped) metadata so a post-crash reseed can resolve;
                    // `register` won't clobber an in-memory copy that already carries bytes.
                    await registry.register(contentsOf: pending.attachments)
                    let (found, _) = await registry.resolve(idStrings: pending.attachments.map { $0.id.uuidString })
                    resolved = found
                }

                let delivery = ChannelMessage(
                    id: pending.channelMessageID,
                    timestamp: pending.receivedAt,
                    sender: .user,
                    recipientID: startSmithID,
                    recipient: .agent(.smith),
                    content: pending.text,
                    attachments: resolved
                )

                let accepted = await liveSmith.acceptChannelMessage(delivery)
                guard accepted else { return }
                deliveredUserMessageChannelIDs.insert(pending.channelMessageID)
                deliveredAny = true
            }
            if !deliveredAny { break }
        }
    }

    /// Called (via the Smith incorporation callback) with the `channelMessageID`s of buffered
    /// user messages that Smith has just taken into its conversation. This is the point at which
    /// a message is durably handled, so it's finally removed from the persisted buffer.
    private func handleInboundUserMessagesIncorporated(_ channelMessageIDs: [UUID]) async {
        let incorporated = Set(channelMessageIDs)
        let before = pendingUserMessages.count
        pendingUserMessages.removeAll { incorporated.contains($0.channelMessageID) }
        deliveredUserMessageChannelIDs.subtract(incorporated)
        if pendingUserMessages.count != before {
            await persistPendingUserMessages?(pendingUserMessages)
        }
    }

    /// Stops all agents and the monitoring timer.
    ///
    /// `preserveObserverCallbacks: true` keeps the AppViewModel-set observer closures
    /// (`onTurnRecorded`, `onEvaluationRecorded`, `onContextChanged`, `onAgentStarted`,
    /// `onAbort`, `onTimerEventForChannel`) alive across the stop. Used by
    /// `restartForNewTask`, which calls `stopAll` then `start` on the SAME runtime
    /// instance — clearing the callbacks left every subsequent run blind to inspector
    /// updates because nothing re-wires them. Default false matches the prior
    /// "stopAll for good" semantics that AppViewModel.stopAll relies on.
    public func stopAll(preserveObserverCallbacks: Bool = false) async {
        // Raise the flag and cancel the in-flight item BEFORE enqueueing: the flag makes
        // transitions bail at their barriers; the cancellation reaches into their slow
        // awaits (the scoping LLM call checks Task.isCancelled, and the retry backoff
        // sleeps are cancellation-aware). Teardowns ignore cancellation by construction.
        stopRequested = true
        lifecycleQueue.cancelCurrent()
        await lifecycleQueue.run { [weak self] in
            await self?.performStopAll(preserveObserverCallbacks: preserveObserverCallbacks)
        }
    }

    /// The actual teardown implementation. Runs ONLY as a lifecycle-queue item (or from
    /// another implementation already inside one).
    private func performStopAll(preserveObserverCallbacks: Bool = false) async {
        // This stop is the answer to any pending stop request.
        stopRequested = false
        let entryStart = Date()
        stopLogger.notice("Runtime.stopAll entry agents=\(self.supervisor.count, privacy: .public) preserveCallbacks=\(preserveObserverCallbacks, privacy: .public)")

        // End the generation SYNCHRONOUSLY, before the first await: `endGeneration()`
        // removes and returns every handle in one step, so no agent can be observed as
        // half-removed — or erased-from-tracking while still running (the 2026-07-08
        // zombie incident) — during the awaits below. An agent registered by an
        // interleaved flow after this line belongs to a NEW generation this stopAll
        // doesn't touch; the lifecycle queue makes that interleaving impossible anyway.
        let handles = supervisor.endGeneration()
        // Drop per-Smith delivery tracking. Anything delivered-but-not-incorporated stays in
        // `pendingUserMessages` and will be redelivered to the next Smith by its start-drain.
        deliveredUserMessageChannelIDs.removeAll()

        await powerManager?.shutdown()
        powerManager = nil

        await monitoringTimer?.stop()
        monitoringTimer = nil

        // Save Brown's context summary to its task before stopping agents
        if let brownHandle = handles.first(where: { $0.role == .brown }) {
            await saveBrownContextToTask(brownID: brownHandle.id, brown: brownHandle.agent)
        }

        let parallelStart = Date()
        await withTaskGroup(of: Void.self) { group in
            for handle in handles {
                group.addTask { await handle.agent.stop() }
            }
        }
        let parallelMs = Int(Date().timeIntervalSince(parallelStart) * 1000)
        stopLogger.notice("Runtime.stopAll all agent.stop() returned elapsedMs=\(parallelMs, privacy: .public)")

        for handle in handles {
            for subID in handle.subscriptionIDs {
                await channel.unsubscribe(subID)
            }
        }

        // Archive evaluation records from the generation's evaluators.
        for handle in handles {
            guard let evaluator = handle.evaluator else { continue }
            let records = await evaluator.evaluationHistory()
            if !records.isEmpty {
                archivedEvaluationRecords[handle.id] = records
            }
        }

        // Clear the channel's session stamp. Unconditional: the lifecycle queue means no
        // start() can have begun a new generation while this teardown was suspended (the
        // Phase 0 guard against that race is obsolete under serialization).
        await channel.setCurrentSessionID(nil)

        // Drop the observer callbacks now that the runtime is quiescent. They
        // hold strong references to closures captured against the app layer's
        // view model and runtime; releasing them here makes lifetime crisp and
        // prevents any deferred Task captured before stopAll from invoking a
        // stale callback after the runtime has finished tearing down.
        //
        // SKIPPED for `restartForNewTask`: that flow calls `stopAll` then immediately
        // `start` on the same runtime, and the AppViewModel-set observers are the only
        // wiring that pushes turn / evaluation / context updates to the inspector.
        // Clearing them mid-restart left every Brown after the first one with no
        // observability — Security Agent's evaluation history disappeared from the right pane,
        // turn records stopped accumulating, and timer-event channel posts went silent.
        if !preserveObserverCallbacks {
            clearObserverCallbacks()
        }

        await channel.post(ChannelMessage(
            sender: .system,
            content: "All agents stopped.",
            metadata: [
                "messageKind": .string("restart_chrome"),
                "restartChromeKind": .string("agents_stopped")
            ]
        ))
        let totalMs = Int(Date().timeIntervalSince(entryStart) * 1000)
        stopLogger.notice("Runtime.stopAll exit elapsedMs=\(totalMs, privacy: .public)")
    }

    /// Drops every observer callback the app layer has wired up. Called by
    /// `stopAll()` so a quiescent runtime no longer holds references to UI-side
    /// closures, and exposed via `observerCallbacksCleared` for tests.
    private func clearObserverCallbacks() {
        onAbort = nil
        onProcessingStateChange = nil
        onToolExecutionStateChange = nil
        onAgentStarted = nil
        onTurnRecorded = nil
        onEvaluationRecorded = nil
        onContextChanged = nil
        onTimerEventForChannel = nil
    }

    /// True iff every observer callback is nil. Surfaced for tests; do not
    /// rely on this from app code.
    public var observerCallbacksCleared: Bool {
        onAbort == nil
            && onProcessingStateChange == nil
            && onToolExecutionStateChange == nil
            && onAgentStarted == nil
            && onTurnRecorded == nil
            && onEvaluationRecorded == nil
            && onContextChanged == nil
            && onTimerEventForChannel == nil
    }

    /// Emergency abort triggered by an agent. Stops everything; requires user interaction to restart.
    ///
    /// Deliberately NOT routed through the lifecycle queue as a whole: the `aborted` flag
    /// must be visible IMMEDIATELY so an in-flight queued transition (a start stuck in
    /// scoping retries, say) bails at its next check instead of running to completion.
    /// Only the teardown at the end enqueues — via the public `stopAll()` — so it still
    /// serializes behind whatever is in flight.
    public func abort(reason: String, callerRole: AgentRole? = nil) async {
        guard !aborted else { return }
        aborted = true
        // Reach into the in-flight transition's slow awaits too, not just its barriers.
        lifecycleQueue.cancelCurrent()

        // Capture the abort handler BEFORE `stopAll()` runs — `stopAll()` clears
        // every observer callback as part of teardown, so reading `onAbort`
        // after it would always be nil and the UI would never see the abort.
        let abortHandler = onAbort
        let callerName = callerRole?.displayName ?? "safety monitor"
        await channel.post(ChannelMessage(
            sender: .system,
            content: "ABORT triggered by \(callerName): \(reason). All agents stopped. User interaction required to restart."
        ))

        await stopAll()
        abortHandler?("ABORT triggered by \(callerName): \(reason)")
    }

    /// Spawns a Brown+Security Agent pair. Terminates any existing Brown first (single Brown policy).
    public func spawnBrown(for task: AgentTask? = nil) async -> UUID? {
        await lifecycleQueue.run { [weak self] in
            await self?.performSpawnBrown(for: task)
        }
    }

    /// The actual spawn implementation. Runs ONLY as a lifecycle-queue item (or from
    /// `performStart`, which already is one).
    private func performSpawnBrown(for task: AgentTask? = nil) async -> UUID? {
        // Fail fast on a stopped runtime: without this, the standalone (tool-driven)
        // spawn path paid a full scoping LLM call before registration failed at the end.
        guard supervisor.currentGeneration != nil else { return nil }
        guard !aborted else { return nil }

        // Worker pool policy: a worker is 1:1 with its task, so a respawn for the same
        // task always cycles that task's existing worker (punch-list respawns, run_task
        // restarts). Beyond that, capacity NEVER evicts — a running task's worker is
        // untouchable. Callers gate before spawning (tool checks, the race-free pend
        // gate in performStartTaskWithLiveSmith); reaching capacity here fails the
        // spawn cleanly as the runtime's own invariant.
        if let task {
            // Match by the handle's task binding AND by task assignment — legacy paths
            // (review_work respawn) assign via the task store after a task-less spawn.
            let sameTaskWorkers = supervisor.handles(role: .brown).filter {
                $0.taskID == task.id || task.assigneeIDs.contains($0.id)
            }
            for worker in sameTaskWorkers {
                _ = await performTerminateAgent(id: worker.id)
            }
        }
        guard supervisor.handles(role: .brown).count < maxConcurrentWorkers else {
            stopLogger.notice("spawnBrown refused — worker capacity \(self.maxConcurrentWorkers, privacy: .public) reached")
            return nil
        }

        guard let brownConfig = llmConfigs[.brown],
              let brownProvider = llmProviders[.brown] else {
            await channel.post(ChannelMessage(sender: .system, content: "No Brown provider configured — cannot spawn."))
            openSpawnBreakerForInfrastructureFailure()
            return nil
        }
        guard let securityAgentProvider = llmProviders[.securityAgent] else {
            await channel.post(ChannelMessage(sender: .system, content: "No Security Agent provider configured — Brown requires a security evaluator."))
            openSpawnBreakerForInfrastructureFailure()
            return nil
        }

        let brownID = UUID()

        // Tool-execution tracker shared between Brown's tool context (writer) and the
        // SecurityEvaluator's Security Agent prompt (reader) so Security Agent can see whether an approved
        // tool call actually succeeded or failed. Without this shared instance, retries
        // after a tool error would be misread as duplicate operations and denied.
        let executionTracker = ToolExecutionTracker()

        // Create the SecurityEvaluator with the Security Agent's LLM config — this evaluator
        // IS the Security Agent (it runs as a lightweight evaluator, not a full agent actor).
        let securityAgentConfig = llmConfigs[.securityAgent]
        let evaluator = SecurityEvaluator(
            provider: securityAgentProvider,
            systemPrompt: SecurityAgentBehavior.systemPrompt,
            channel: channel,
            abort: { [weak self] reason, callerRole in
                guard let self else { return }
                await self.abort(reason: reason, callerRole: callerRole)
            },
            usageStore: usageStore,
            configuration: securityAgentConfig,
            providerType: providerAPITypes[.securityAgent]?.rawValue ?? "",
            sessionID: currentSessionID,
            hasToolSucceeded: { [executionTracker] toolCallID in
                await executionTracker.hasSucceeded(toolCallID: toolCallID)
            },
            hasToolFailed: { [executionTracker] toolCallID in
                await executionTracker.hasFailed(toolCallID: toolCallID)
            }
        )
        // The evaluator stays a LOCAL until Brown's registration attaches it to the agent's
        // handle — a spawn that fails before registration simply drops it, with no staging
        // entry to clean up on every failure path.
        // Wire the evaluation-recorded callback BEFORE the per-task scoping pass runs below, so
        // the "(tool scoping)" evaluation record is pushed live to the inspector like per-call
        // verdicts. (Wiring it after scoping would drop the scoping record from the live view.)
        if let evalCallback = onEvaluationRecorded {
            await evaluator.setOnEvaluationRecorded(evalCallback)
        }
        // Forward Security Agent's LLM turn records so the inspector shows the security agent's per-session
        // token usage and cost (previously empty — Security Agent produced no turn records, so its card
        // always read 0 tokens / $0.00 even though its usage was in the global UsageStore).
        if let turnCallback = onTurnRecorded {
            await evaluator.setOnTurnRecorded { turn in turnCallback(.securityAgent, turn) }
        }

        // Brown's message filter: drop security review messages and tool execution trace messages.
        // Brown already receives all security feedback directly as tool results — approved calls
        // return the tool output, denied calls return "Tool execution denied: <reason>".
        // Echoing these through the channel as [System] messages wastes tokens and adds noise.
        let brownMessageFilter: @Sendable (ChannelMessage) -> Bool = { message in
            // Drop all security disposition messages (SAFE/WARN/UNSAFE/ABORT).
            if message.metadata?["securityDisposition"] != nil { return false }
            // Drop tool_request and tool_output echo messages (posted for UI visibility
            // only), and context-management notices (Smith's compaction is none of the
            // worker's business).
            if case .string(let kind) = message.metadata?["messageKind"],
               kind == "tool_request" || kind == "tool_output" || kind == "context_management"
                || kind == "validation_report" || kind == "validation_escalation" { return false }
            return true
        }

        let filesRead = FileReadTracker()
        let brownContext = makeToolContext(
            agentID: brownID,
            role: .brown,
            filesReadInSession: filesRead,
            executionTracker: executionTracker
        )

        // Pre-flight `gh auth status` so Brown sees verified GitHub auth state in his tool list
        // from turn one. Capturing once at spawn is sufficient — auth doesn't change mid-task.
        // The snapshot lands inside `GhTool.toolDescription`; it is intentionally NOT posted to
        // the channel so it does not clutter the user-visible transcript.
        let ghAuthSnapshot = await GhAuthChecker.authStatus()

        // Brown's dynamic (MCP server) tools, refreshed each turn. Built explicitly to
        // keep the closure's `@Sendable` capture of the host actor unambiguous.
        let mcpToolsProvider: (@Sendable () async -> [any AgentTool])?
        if let host = mcpHost {
            mcpToolsProvider = { await host.currentBridgedTools() }
        } else {
            mcpToolsProvider = nil
        }

        // Per-task tool scoping: before the worker starts, let the security agent (Security Agent) pick
        // the subset of tools it may use for THIS task. Skipped when there's no task context
        // (e.g. the post-review re-spawn path), which falls back to the unscoped tool set.
        var scopedApprovedNames: Set<String>?
        if let task {
            await channel.post(ChannelMessage(
                sender: .system,
                content: "Preparing task — starting MCP servers and checking security policy…",
                metadata: ["messageKind": .string("preparing")]
            ))
            if let host = mcpHost {
                await host.waitUntilSettled(timeout: .seconds(5))
            }
            guard !aborted else {
                return nil
            }
            let builtIns = BrownBehavior.tools(ghAuthStatusSnapshot: ghAuthSnapshot)
            let mcpTools = mcpHost != nil ? await mcpHost!.currentBridgedTools() : []
            let candidateNames = Set((builtIns + mcpTools).map(\.name))
            if preflightScopingEnabled {
                // Circuit breaker: after repeated consecutive scoping failures (usually a
                // dead/unreachable backend), stop attempting for a cooldown window instead
                // of hammering it once per restart.
                if isScopingBreakerOpen, let lastFailure = lastScopingFailureAt {
                    let retryInSeconds = Int(Self.scopingBreakerCooldown - Date().timeIntervalSince(lastFailure))
                    await channel.post(ChannelMessage(
                        sender: .system,
                        content: "Not starting task \"\(task.title)\": the security agent's tool-scoping has failed \(scopingFailureStreak) times in a row — the model backend looks unreachable. Waiting ~\(max(retryInSeconds, 1))s before allowing another attempt. Check the Security Agent's model configuration or backend, then retry the task.",
                        metadata: ["isError": .bool(true)]
                    ))
                    return nil
                }

                // Light the Security Agent card while it scopes — this is a real (often slow) Security Agent
                // LLM call, so it shouldn't look idle during "Preparing…". Cleared right after.
                await notifyProcessingStateChange(role: .securityAgent, isProcessing: true)
                let scoping = await evaluator.scopeTools(
                    candidateTools: builtIns + mcpTools,
                    taskTitle: task.title,
                    taskID: task.id.uuidString,
                    taskDescription: task.description
                )
                await notifyProcessingStateChange(role: .securityAgent, isProcessing: false)
                guard scoping.succeeded else {
                    // A user-initiated cancellation (Stop/abort during "Preparing…") also
                    // lands here with the evaluator's cancelled sentinel. That says nothing
                    // about backend health — don't open the breaker — and the user asked
                    // for it, so a scary "security agent failed" error would be misleading;
                    // post a neutral line instead.
                    guard scoping.rawResponse != ToolScopingResult.cancelledSentinel else {
                        await channel.post(ChannelMessage(
                            sender: .system,
                            content: "Task \"\(task.title)\" start cancelled.",
                            metadata: ["messageKind": .string("preparing")]
                        ))
                        return nil
                    }
                    // Hard stop — the security agent could not evaluate the toolset. Do NOT spawn
                    // a worker; surface to the user.
                    scopingFailureStreak += 1
                    lastScopingFailureAt = Date()
                    await channel.post(ChannelMessage(
                        sender: .system,
                        content: "Could not start task \"\(task.title)\": the security agent failed to evaluate which tools are safe to use. Check Security Agent's model configuration.",
                        metadata: ["isError": .bool(true)]
                    ))
                    return nil
                }
                scopingFailureStreak = 0
                lastScopingFailureAt = nil
                guard !scoping.approvedNames.isEmpty else {
                    // Refusal — no tools approved for this task. Don't spawn a hamstrung worker.
                    await channel.post(ChannelMessage(
                        sender: .system,
                        content: "The security agent did not approve any tools for task \"\(task.title)\", so it cannot be run.",
                        metadata: ["isWarning": .bool(true)]
                    ))
                    return nil
                }
                scopedApprovedNames = scoping.approvedNames
                await taskStore.setApprovedTools(id: task.id, approvedTools: Array(scoping.approvedNames))
            } else {
                // Pre-flight scoping disabled in Settings: the base approved set is every candidate.
                // Global Always/Never policy and per-task user overrides still apply at the registry.
                scopedApprovedNames = candidateNames
                await taskStore.setApprovedTools(id: task.id, approvedTools: Array(candidateNames))
            }
        }

        // Re-check after the (possibly long) scoping LLM call above: an abort or stop
        // raised mid-scoping must not be answered by minting a fresh worker. The queued
        // stopAll owns teardown of anything already built (codex review finding).
        guard !aborted, !stopRequested else { return nil }

        let brownAgent = AgentActor(
            id: brownID,
            configuration: AgentConfiguration(
                role: .brown,
                llmConfig: brownConfig,
                providerAPIType: providerAPITypes[.brown] ?? .openAICompatible,
                systemPrompt: BrownBehavior.systemPrompt,
                toolNames: BrownBehavior.toolNames,
                requiresToolApproval: true,
                pollInterval: agentTuning[.brown]?.pollInterval ?? 25,
                messageDebounceInterval: agentTuning[.brown]?.messageDebounceInterval ?? 1,
                messageAcceptFilter: brownMessageFilter,
                maxToolCallsPerIteration: agentTuning[.brown]?.maxToolCalls ?? 100
            ),
            provider: brownProvider,
            tools: BrownBehavior.tools(ghAuthStatusSnapshot: ghAuthSnapshot),
            toolContext: brownContext,
            dynamicToolsProvider: mcpToolsProvider
        )
        await brownAgent.setSecurityEvaluator(evaluator)
        await brownAgent.setPerCallApprovalEnabled(perCallCheckEnabled)
        if let scopedApprovedNames, let task {
            await brownAgent.enableToolScoping(approvedNames: scopedApprovedNames)
            await brownAgent.setPreflightScopingActive(preflightScopingEnabled)
            await brownAgent.setGlobalToolPolicy(globalToolPolicy)
            await brownAgent.setUserToolOverrides(task.userToolOverrides ?? [:])
            let scopedTaskID = task.id
            await brownAgent.setOnApprovedToolsChanged { [weak self] names in
                guard let self else { return }
                await self.taskStore.setApprovedTools(id: scopedTaskID, approvedTools: Array(names))
            }
        }
        await brownAgent.setUsageStore(usageStore)
        await brownAgent.setSessionID(currentSessionID)
        if let turnCallback = onTurnRecorded {
            await brownAgent.setOnTurnRecorded { turn in turnCallback(.brown, turn) }
        }
        if let contextCallback = onContextChanged {
            await brownAgent.setOnContextChanged { messages in contextCallback(.brown, messages) }
        }
        // Push Brown's LIVE scoped tool set to the inspector as it changes. Reuses the
        // `onAgentStarted` sink (which just sets `agentToolNames[role]`), so the inspector shows
        // the actual scoped tools instead of the static configured list.
        await brownAgent.setOnActiveToolNamesChanged { [weak self] names in
            guard let self else { return }
            Task { await self.publishAvailableToolNames(.brown, names) }
        }
        // Note: evaluator.setOnEvaluationRecorded is wired earlier (right after the evaluator is
        // created) so the per-task scoping evaluation record is captured live.

        // Registration returns nil only when no generation is active — i.e. the runtime
        // was stopped while this spawn was mid-flight. Failing the spawn cleanly here is
        // exactly the structural guard against creating an untracked (unkillable) agent.
        // The `!aborted` re-check closes the last window: an abort raised during the
        // wiring awaits since the post-scoping barrier must not get a registered, started
        // worker (agy review finding).
        guard !aborted, !stopRequested,
              supervisor.register(id: brownID, role: .brown, agent: brownAgent, evaluator: evaluator, taskID: task?.id) != nil else {
            await brownAgent.markTerminated()
            stopLogger.warning("spawnBrown: aborted or stopped mid-spawn — discarding unregistered Brown \(brownID.uuidString.prefix(8), privacy: .public)")
            return nil
        }

        // Label the worker's channel messages with its task so the UI can distinguish
        // workers ("Brown" alone is ambiguous once several run concurrently).
        if let task {
            await brownAgent.setChannelTaskTitle(task.title)
        }

        let brownSubID = await channel.subscribe { [weak brownAgent] message in
            guard let brownAgent else { return }
            Task { await brownAgent.receiveChannelMessage(message) }
        }
        supervisor.addSubscription(brownSubID, to: brownID)

        // Announce Security Agent is online (evaluator is ready) for UI consistency.
        await channel.post(ChannelMessage(
            sender: .agent(.securityAgent),
            content: "Security Agent online.",
            metadata: ["messageKind": .string("agent_online")]
        ))
        onAgentStarted?(.securityAgent, SecurityAgentBehavior.toolNames)

        await brownAgent.start()
        onAgentStarted?(.brown, brownAgent.toolNames)

        return brownID
    }

    /// Terminates a specific agent. If it's a Brown, also cleans up its SecurityEvaluator.
    public func terminateAgent(id: UUID, callerID: UUID? = nil) async -> Bool {
        await lifecycleQueue.run { [weak self] in
            await self?.performTerminateAgent(id: id, callerID: callerID) ?? false
        }
    }

    /// The actual terminate implementation. Runs ONLY as a lifecycle-queue item (or from
    /// `performSpawnBrown` / `performTerminateTaskAgents`, which already are).
    private func performTerminateAgent(id: UUID, callerID: UUID? = nil) async -> Bool {
        let agentSlug = id.uuidString.prefix(8)
        // Remove the whole handle SYNCHRONOUSLY before the first await (clear-first
        // discipline, same as stopAll / handleAgentSelfTerminate) so no interleaved flow
        // can observe a half-removed agent between the awaits below.
        guard let handle = supervisor.remove(id: id) else {
            stopLogger.notice("Runtime.terminateAgent agent not found id=\(agentSlug, privacy: .public) — early return")
            return false
        }
        let agent = handle.agent
        let agentRole: AgentRole? = handle.role
        let evaluator = handle.evaluator
        let role = handle.role.rawValue
        stopLogger.notice("Runtime.terminateAgent entry id=\(agentSlug, privacy: .public) role=\(role, privacy: .public)")

        let stopStart = Date()
        await agent.stop()
        let elapsedMs = Int(Date().timeIntervalSince(stopStart) * 1000)
        stopLogger.notice("Runtime.terminateAgent agent.stop returned id=\(agentSlug, privacy: .public) role=\(role, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public)")

        // Archive the agent's state after stop so the inspector can still display it.
        if let agentRole {
            await archiveAgent(agent, role: agentRole)
        }

        // Archive the security evaluator's history.
        if let evaluator {
            let records = await evaluator.evaluationHistory()
            archivedEvaluationRecords[id] = records
        }

        await unsubscribe(handle)

        // Scrub the terminated agent's UUID from every task's assignee list so stale
        // Brown UUIDs don't accumulate across respawns. Without this, the periodic
        // status messages Smith sees ("assigned to N agents") grow monotonically and
        // misrepresent how many agents are actually live on a task.
        await taskStore.unassignAgentFromAllTasks(agentID: id)

        return true
    }

    /// Returns a snapshot of the conversation history for the active agent with the given role.
    public func contextSnapshot(for role: AgentRole) async -> [LLMMessage]? {
        guard let agent = supervisor.firstHandle(role: role)?.agent else { return nil }
        return await agent.contextSnapshot()
    }

    /// Returns a snapshot of recent LLM turns for the active agent with the given role.
    public func turnsSnapshot(for role: AgentRole) async -> [LLMTurnRecord]? {
        guard let agent = supervisor.firstHandle(role: role)?.agent else { return nil }
        return await agent.turnsSnapshot()
    }

    /// Returns the security evaluation history for the current (or most recent) Brown.
    /// Worker-pool M2 (per-agent inspector re-key) must make this per-agent; at capacity
    /// 1 "the first Brown" is the only Brown, so this stays correct until then.
    public func evaluationHistory() async -> [EvaluationRecord] {
        // Try active evaluator first.
        if let evaluator = supervisor.firstHandle(role: .brown)?.evaluator {
            return await evaluator.evaluationHistory()
        }
        // Fall back to archived records from the most recently terminated Brown.
        if let records = archivedEvaluationRecords.values.max(by: {
            ($0.last?.timestamp ?? .distantPast) < ($1.last?.timestamp ?? .distantPast)
        }) {
            return records
        }
        return []
    }

    /// Terminates all agents assigned to a task. Used when the user stops or pauses a task
    /// from the UI — the task status alone doesn't stop Brown's LLM loop.
    public func terminateTaskAgents(taskID: UUID) async {
        await lifecycleQueue.run { [weak self] in
            await self?.performTerminateTaskAgents(taskID: taskID)
        }
    }

    private func performTerminateTaskAgents(taskID: UUID) async {
        let taskSlug = taskID.uuidString.prefix(8)
        let entryStart = Date()
        stopLogger.notice("Runtime.terminateTaskAgents entry task=\(taskSlug, privacy: .public)")
        // Halting a task (pause/stop) also halts any in-flight validation of it.
        cancelTaskValidation(taskID: taskID)
        guard let task = await taskStore.task(id: taskID) else {
            stopLogger.notice("Runtime.terminateTaskAgents no task found task=\(taskSlug, privacy: .public)")
            return
        }
        stopLogger.notice("Runtime.terminateTaskAgents task=\(taskSlug, privacy: .public) assignees=\(task.assigneeIDs.count, privacy: .public)")
        for agentID in task.assigneeIDs {
            _ = await performTerminateAgent(id: agentID)
        }
        let elapsedMs = Int(Date().timeIntervalSince(entryStart) * 1000)
        stopLogger.notice("Runtime.terminateTaskAgents exit task=\(taskSlug, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public)")
    }

    /// Summarizes a completed or failed task and saves the embedding to the memory store.
    ///
    /// Runs as a fire-and-forget operation — errors are posted to the channel.
    public func summarizeAndEmbedTask(taskID: UUID) async {
        guard let task = await taskStore.task(id: taskID) else { return }
        guard task.status == .completed || (task.status == .failed && !task.updates.isEmpty) else { return }

        if let summarizer = taskSummarizer {
            await notifyProcessingStateChange(role: .summarizer, isProcessing: true)
            let summary = await summarizer.summarizeAndEmbed(task: task)
            await notifyProcessingStateChange(role: .summarizer, isProcessing: false)
            if let summary {
                await taskStore.setSummary(id: taskID, summary: summary)
            }
        }
    }

    /// Posts a private message from the user directly to the agent with the given role.
    public func sendDirectMessage(to role: AgentRole, text: String) async {
        guard let agentID = agentIDForRole(role) else { return }
        await channel.post(ChannelMessage(
            sender: .user,
            recipientID: agentID,
            recipient: .agent(role),
            content: text
        ))
    }

    /// Replaces the system prompt in the active agent's conversation history.
    public func updateSystemPrompt(for role: AgentRole, prompt: String) async {
        guard let agent = supervisor.firstHandle(role: role)?.agent else { return }
        await agent.updateSystemPrompt(prompt)
    }

    /// Updates the idle poll interval for the active agent with the given role.
    public func updatePollInterval(for role: AgentRole, interval: TimeInterval) async {
        guard let agent = supervisor.firstHandle(role: role)?.agent else { return }
        await agent.updatePollInterval(interval)
    }

    /// Updates the maximum tool calls per LLM response for the active agent with the given role.
    public func updateMaxToolCalls(for role: AgentRole, count: Int) async {
        guard let agent = supervisor.firstHandle(role: role)?.agent else { return }
        await agent.updateMaxToolCalls(count)
    }

    /// All currently active agent IDs.
    public func activeAgentIDs() -> [UUID] {
        Array(supervisor.handlesByID.keys)
    }

    // MARK: - Agent Archive

    /// Snapshot of a terminated agent's state, preserved for inspector display.
    public struct AgentArchiveEntry: Sendable {
        public let role: AgentRole
        public let contextSnapshot: [LLMMessage]
        public let turnsSnapshot: [LLMTurnRecord]
        public let terminatedAt: Date
    }

    /// Returns the archived snapshot for a terminated agent role, if any.
    public func archivedSnapshot(for role: AgentRole) -> AgentArchiveEntry? {
        terminatedAgentArchive[role]
    }

    /// Snapshots the given agent's state into the archive before it is deallocated.
    private func archiveAgent(_ agent: AgentActor, role: AgentRole) async {
        let context = await agent.contextSnapshot()
        let turns = await agent.turnsSnapshot()
        terminatedAgentArchive[role] = AgentArchiveEntry(
            role: role,
            contextSnapshot: context,
            turnsSnapshot: turns,
            terminatedAt: Date()
        )
    }

    // MARK: - Private

    /// Removes channel subscriptions for a given agent.
    private func unsubscribe(_ handle: AgentSupervisor.AgentHandle) async {
        for subID in handle.subscriptionIDs {
            await channel.unsubscribe(subID)
        }
    }

    func makeToolContext(
        agentID: UUID,
        role: AgentRole,
        followUpScheduler: FollowUpScheduler? = nil,
        currentResumingTaskID: UUID? = nil,
        filesReadInSession: FileReadTracker? = nil,
        executionTracker: ToolExecutionTracker? = nil
    ) -> ToolContext {
        // Strong-capture the tracker so it survives beyond this stack frame. Callers that
        // also need to read tool-execution outcomes (e.g. SecurityEvaluator) must pass the
        // same instance via this parameter so writer (tool execute) and reader (Security Agent prompt)
        // share state. When unset, a fresh tracker is created for this agent only — that
        // agent's writes/reads stay consistent, but no one else can observe them.
        let tracker = executionTracker ?? ToolExecutionTracker()
        let learnedLimitCallback = onLearnedModelOutputLimit

        return ToolContext(
            agentID: agentID,
            agentRole: role,
            channel: channel,
            taskStore: taskStore,
            currentConfiguration: llmConfigs[role],
            currentProviderType: providerAPITypes[role]?.rawValue,
            spawnBrown: { [weak self] in
                guard let self else { return nil }
                return await self.spawnBrown()
            },
            terminateAgent: { [weak self] id, callerID in
                guard let self else { return false }
                return await self.terminateAgent(id: id, callerID: callerID)
            },
            abort: { [weak self] reason, callerRole in
                guard let self else { return }
                await self.abort(reason: reason, callerRole: callerRole)
            },
            agentRoleForID: { [weak self] id in
                guard let self else { return nil }
                return await self.roleForAgent(id: id)
            },
            agentIDForRole: { [weak self] role in
                guard let self else { return nil }
                return await self.agentIDForRole(role)
            },
            onSelfTerminate: { [weak self] in
                guard let self else { return }
                await self.handleAgentSelfTerminate(id: agentID)
            },
            beginTaskValidation: { [weak self] taskID in
                await self?.startTaskValidation(taskID: taskID)
            },
            loadEvaluatorRegistry: { [weak self] in
                guard let directory = await self?.evaluatorsDirectory else { return nil }
                return EvaluatorRegistry.load(from: directory)
            },
            workerCapacity: { [weak self] in
                await self?.maxConcurrentWorkers ?? 1
            },
            saveEvaluatorDefinition: { [weak self] definition, overwrite in
                await self?.saveEvaluatorDefinition(definition, overwrite: overwrite) ?? "runtime unavailable"
            },
            // Liveness lease: true only while this exact agent ID is still in the live
            // registry. A deallocated runtime also reads as not-current — an agent whose
            // runtime is gone is by definition a zombie.
            isAgentCurrent: { [weak self] in
                guard let self else { return false }
                return await self.isAgentRegistered(agentID)
            },
            onProcessingStateChange: { [weak self] isProcessing in
                guard let self else { return }
                Task { await self.notifyProcessingStateChange(role: role, isProcessing: isProcessing) }
            },
            onSecurityAgentProcessingStateChange: { [weak self] isProcessing in
                guard let self else { return }
                Task { await self.notifyProcessingStateChange(role: .securityAgent, isProcessing: isProcessing) }
            },
            onToolExecutionStateChange: { [weak self] toolName, started in
                guard let self else { return }
                Task { await self.notifyToolExecutionStateChange(role: role, toolName: toolName, started: started) }
            },
            scheduleWake: { [followUpScheduler] wakeAt, instructions, taskID, replacesID, recurrence, survivesTaskTermination in
                guard let followUpScheduler else { return .error("Scheduler not available.") }
                return await followUpScheduler.scheduleWake(
                    wakeAt: wakeAt,
                    instructions: instructions,
                    taskID: taskID,
                    replacesID: replacesID,
                    recurrence: recurrence,
                    survivesTaskTermination: survivesTaskTermination
                )
            },
            listScheduledWakes: { [followUpScheduler] in
                guard let followUpScheduler else { return [] }
                return await followUpScheduler.listScheduledWakes()
            },
            cancelScheduledWake: { [followUpScheduler] id in
                guard let followUpScheduler else { return false }
                return await followUpScheduler.cancelWake(id: id)
            },
            restartForNewTask: { [weak self] taskID in
                guard let self else { return }
                await self.restartForNewTask(taskID: taskID)
            },
            currentResumingTaskID: currentResumingTaskID,
            memoryStore: memoryStore,
            summarizeCompletedTask: { [weak self] taskID in
                guard let self else { return }
                await self.summarizeAndEmbedTask(taskID: taskID)
            },
            reconcileMemory: { [weak self] existing, new in
                guard let self, let summarizer = await self.taskSummarizer else { return .distinct }
                return await summarizer.reconcileMemoryTexts(existing: existing, new: new)
            },
            extractWebContent: { [weak self] content, prompt in
                guard let self else { return nil }
                return await self.taskSummarizer?.extractWebContent(content: content, prompt: prompt)
            },
            autoAdvanceEnabled: { [weak self] in await self?.autoAdvanceEnabled ?? false },
            recordFileRead: { path in
                filesReadInSession?.record(PathNormalization.normalize(path))
            },
            hasFileBeenRead: { path in
                filesReadInSession?.contains(PathNormalization.normalize(path)) ?? false
            },
            setToolExecutionStatus: { [tracker] toolCallID, succeeded in
                await tracker.recordExecutionStatus(toolCallID: toolCallID, succeeded: succeeded)
            },
            hasToolSucceeded: { [tracker] toolCallID in
                await tracker.hasSucceeded(toolCallID: toolCallID)
            },
            hasToolFailed: { [tracker] toolCallID in
                await tracker.hasFailed(toolCallID: toolCallID)
            },
            resolveAttachments: { [weak self] idStrings in
                guard let self else { return ([], idStrings) }
                guard let registry = await self.attachmentRegistry else { return ([], idStrings) }
                return await registry.resolve(idStrings: idStrings)
            },
            ingestAttachmentFile: { [weak self] path in
                guard let registry = await self?.attachmentRegistry else {
                    return (nil, "Attachment registry not configured for this runtime.")
                }
                let result = await registry.ingestFile(path: path)
                switch result {
                case .success(let attachment):
                    return (attachment, nil)
                case .failure(let err):
                    return (nil, err.description)
                }
            },
            ingestAttachmentData: { [weak self] data, filename, mimeType in
                guard let registry = await self?.attachmentRegistry else {
                    return (nil, "Attachment registry not configured for this runtime.")
                }
                let result = await registry.ingestData(data, filename: filename, mimeType: mimeType)
                switch result {
                case .success(let attachment):
                    return (attachment, nil)
                case .failure(let err):
                    return (nil, err.description)
                }
            },
            attachmentURLProvider: attachmentURLProviderClosure ?? { _, _ in nil },
            stageAttachmentsForNextTurn: { [weak self] attachments, detailString in
                guard let self else { return }
                guard let agent = await self.supervisor.agent(id: agentID) else { return }
                let detail: AgentActor.AttachmentDetail
                switch detailString.lowercased() {
                case "thumbnail": detail = .thumbnail
                case "full": detail = .full
                default: detail = .standard
                }
                let entries = attachments.map { (attachment: $0, detail: detail) }
                await agent.stageAttachments(entries)
            },
            maxAttachmentBytesPerMessage: { [weak self] in
                guard let self else { return 50 * 1024 * 1024 }
                return await self.maxAttachmentBytesPerMessage
            },
            // Capture the runtime callback by value (not `self`) so this @Sendable closure
            // can fire from the agent's context without an actor hop — mirrors how
            // `onTurnRecorded` is threaded to agents.
            onLearnedModelOutputLimit: { providerID, modelID, limit in
                learnedLimitCallback?(providerID, modelID, limit)
            }
        )
    }

    private func notifyProcessingStateChange(role: AgentRole, isProcessing: Bool) async {
        onProcessingStateChange?(role, isProcessing)
        await powerManager?.activityOccurred()
    }

    private func notifyToolExecutionStateChange(role: AgentRole, toolName: String, started: Bool) async {
        onToolExecutionStateChange?(role, toolName, started)
        await powerManager?.activityOccurred()
    }

    /// Cleans up registry entries and channel subscriptions when an agent's run loop exits on its own.
    /// Guarded by handle presence to be idempotent with terminateAgent().
    private func handleAgentSelfTerminate(id: UUID) async {
        // Remove the whole handle SYNCHRONOUSLY before the first await (same clear-first
        // discipline as stopAll) so a concurrent teardown interleaving with the archive work
        // below can never observe a half-removed agent.
        guard let handle = supervisor.remove(id: id) else { return }
        let agent = handle.agent
        let role: AgentRole? = handle.role
        let evaluator = handle.evaluator

        // Belt-and-braces: the run loop reported it exited on its own, but if this path is
        // ever reached while the loop is somehow still live, the flag prevents an
        // untracked-but-running agent. Deliberately NOT full `stop()`: onSelfTerminate is
        // called from inside the agent's own run task, and stop() awaits that task's
        // completion — a guaranteed 5 s grace-timeout stall plus a self-cancellation.
        await agent.markTerminated()

        // Archive the agent's state after stop so the inspector can still display it.
        if let role {
            await archiveAgent(agent, role: role)
        }

        // Archive security evaluator records before cleanup.
        if let evaluator {
            let records = await evaluator.evaluationHistory()
            archivedEvaluationRecords[id] = records
        }

        await unsubscribe(handle)

        // Mark any running tasks assigned to this agent as failed — no agent is working on them anymore.
        // Trigger summarization for tasks that had progress (updates).
        let allTasks = await taskStore.allTasks()
        for task in allTasks where task.assigneeIDs.contains(id) {
            // Compare-and-set: only fail the task if it is STILL `.running` at the moment of
            // the write. A task that raced to `.completed`/`.awaitingReview` (via
            // `task_complete`) after this snapshot must not be force-failed. `task.status`
            // from the snapshot is not trustworthy here, so the decision is made atomically
            // inside the store.
            let didFail = await taskStore.updateStatus(id: task.id, ifCurrentlyEquals: .running, to: .failed)
            if didFail && !task.updates.isEmpty {
                Task.detached { [weak self] in
                    guard let self else { return }
                    await self.summarizeAndEmbedTask(taskID: task.id)
                }
            }
        }

        // Mirror the explicit `terminateAgent` cleanup: scrub this agent's UUID from every
        // task's assignee list so stale UUIDs don't accumulate across self-terminations.
        // Without this, the periodic "assigned to N agents" status grows monotonically
        // every time an agent's run loop exits on its own.
        await taskStore.unassignAgentFromAllTasks(agentID: id)
    }

    /// Extracts Brown's last few assistant messages and saves a compressed context summary
    /// to the task it was working on, enabling better resumability.
    /// Takes the Brown reference explicitly (rather than resolving through the
    /// supervisor) so `stopAll` can call it AFTER the registry has been snapshot-and-
    /// cleared at teardown entry.
    private func saveBrownContextToTask(brownID: UUID, brown: AgentActor) async {
        let context = await brown.contextSnapshot()

        // Find the task Brown was working on
        let task = await taskStore.taskForAgent(agentID: brownID)
        guard let task else { return }

        // Extract the last few assistant messages as a summary
        let assistantMessages = context.compactMap { msg -> String? in
            guard msg.role == .assistant else { return nil }
            switch msg.content {
            case .text(let s) where !s.isEmpty: return s
            case .mixed(let s, let calls) where !s.isEmpty || !calls.isEmpty:
                let toolPart = calls.map { "[\($0.name)]" }.joined(separator: ", ")
                return [s, toolPart].filter { !$0.isEmpty }.joined(separator: " ")
            case .toolCalls(let calls):
                return calls.map { "[\($0.name)]" }.joined(separator: ", ")
            default: return nil
            }
        }
        let recentMessages = assistantMessages.suffix(5)
        guard !recentMessages.isEmpty else { return }

        let summary = recentMessages.joined(separator: "\n---\n")
        // Cap to prevent storing extremely long context
        let truncated = summary.count > 2000 ? String(summary.suffix(2000)) : summary
        await taskStore.setLastBrownContext(id: task.id, context: truncated)
    }

    /// Atomically (from the runtime actor's perspective) checks Brown's presence
    /// and assembles the digest. Folding both checks into one actor call removes
    /// the prior TOCTOU window where Brown could terminate between
    /// `agentIDForRole(.brown)` and `assembleBrownActivityDigest`, leaving Smith
    /// with a digest about an agent that was already gone.
    private func assembleDigestIfBrownAlive(since: Date) async -> String? {
        guard agentIDForRole(.brown) != nil else { return nil }
        // Nothing to monitor while a task sits in awaitingReview — Brown has stopped and is
        // waiting on Smith's `review_work`, and the `task_complete` already woke Smith with the
        // review prompt. A recurring "Brown activity" digest here is pure noise; historically it
        // woke Smith every 10 minutes into a "No action needed" text-only loop that the circuit
        // breaker eventually terminated. Smith's job in this state is to review, not to monitor.
        let activeTasks = await taskStore.allTasks().filter { $0.disposition == .active }
        if activeTasks.contains(where: { $0.status == .awaitingReview }) { return nil }
        return await Self.assembleBrownActivityDigest(channel: channel, since: since)
    }

    /// Builds Smith's periodic Brown-activity digest from channel history since `since`.
    /// Returns nil when nothing meaningful has happened (so the digest wake is suppressed).
    ///
    /// Iteration is bounded to messages in `[since, now]` via the channel's binary-search
    /// `messages(since:)` lookup so this is cheap even when the channel holds the full
    /// 10K-message backlog. Security Agent denial breadcrumbs are detected via the structured
    /// `securityDisposition` metadata key (set by `SecurityEvaluator.postToChannel` on
    /// ABORT messages) rather than by substring-matching the rendered content.
    static func assembleBrownActivityDigest(channel: MessageChannel, since: Date) async -> String? {
        let recent = await channel.messages(since: since)
        guard !recent.isEmpty else { return nil }
        // The post-scan `noBrownActivity` check below is the real suppression gate; this early
        // return is just a cheap short-circuit for a genuinely empty window.

        var taskUpdateCount = 0
        var toolCallCount = 0
        var toolBuckets: [String: Int] = [:]
        var lastUpdate: String?
        var lastUpdateAt: Date?
        var securityAgentDenials = 0
        var lastDenial: String?
        var msgFromBrownToSmith: [(Date, String)] = []

        for msg in recent {
            // Brown public/tool messages — count tool calls once per request (not also per output).
            if case .agent(let role) = msg.sender, role == .brown {
                if case .string("tool_request") = msg.metadata?["messageKind"] {
                    toolCallCount += 1
                    if case .string(let name) = msg.metadata?["tool"] {
                        toolBuckets[name, default: 0] += 1
                    }
                } else if msg.metadata?["tool"] != nil {
                    // tool_output — already accounted for via tool_request, skip.
                } else if case .string(let kind) = msg.metadata?["messageKind"] {
                    if kind == "task_update" {
                        taskUpdateCount += 1
                        lastUpdate = msg.content
                        lastUpdateAt = msg.timestamp
                    } else if kind == "task_complete" {
                        msgFromBrownToSmith.append((msg.timestamp, "task_complete: " + String(msg.content.prefix(120))))
                    }
                } else if msg.recipientID != nil {
                    // Private Brown→Smith messages (other than the structured kinds above).
                    msgFromBrownToSmith.append((msg.timestamp, String(msg.content.prefix(120))))
                }
            }
            // Security Agent denial breadcrumbs: structured metadata key set by
            // `AgentActor.postSecurityReviewToChannel` ("denied") and `SecurityEvaluator`
            // ("abort"). Substring-matching the content was unreliable — Smith log lines
            // often quote denial reasons and would have been counted as denials themselves.
            if case .string(let dispo) = msg.metadata?["securityDisposition"],
               dispo == "abort" || dispo == "denied" {
                securityAgentDenials += 1
                lastDenial = msg.content
            }
        }

        // Honor this function's contract ("returns nil when nothing meaningful has happened").
        // The raw window is frequently non-empty purely because Smith's own idle "No action
        // needed" posts land on the channel — so keying suppression off `recent.isEmpty` alone
        // let a phantom "Brown made 0 tool calls — likely stuck" digest fire every cycle, which
        // woke Smith into a self-sustaining text-only loop. Suppress on the absence of actual
        // Brown activity instead.
        let noBrownActivity = toolCallCount == 0 && taskUpdateCount == 0
            && securityAgentDenials == 0 && msgFromBrownToSmith.isEmpty
        guard !noBrownActivity else { return nil }

        var lines: [String] = []
        lines.append("- Brown made \(toolCallCount) tool call(s) and sent \(taskUpdateCount) task_update(s).")
        if !toolBuckets.isEmpty {
            let topTools = toolBuckets.sorted { $0.value > $1.value }.prefix(5)
                .map { "\($0.key)×\($0.value)" }
                .joined(separator: ", ")
            lines.append("- Top tools: \(topTools)")
        }
        if let lastUpdate, let lastUpdateAt {
            let formatter = RuntimeDateFormatters.clock
            let preview = lastUpdate.replacingOccurrences(of: "\n", with: " ")
            let trimmed = preview.count > 200 ? String(preview.prefix(200)) + "…" : preview
            lines.append("- Last task_update at \(formatter.string(from: lastUpdateAt)): \(trimmed)")
        } else {
            lines.append("- No task_update from Brown in this window — likely deep in tool work or stuck.")
        }
        if securityAgentDenials > 0 {
            lines.append("- Security Agent denied \(securityAgentDenials) call(s). Latest reason snippet: \((lastDenial ?? "").prefix(160))")
        }
        for (_, text) in msgFromBrownToSmith.prefix(3) {
            lines.append("- Brown→Smith: \(text)")
        }
        return lines.joined(separator: "\n")
    }
}
