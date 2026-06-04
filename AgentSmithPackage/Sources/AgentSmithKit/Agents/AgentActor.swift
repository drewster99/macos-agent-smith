import Foundation
import os

/// Core agent actor: owns an LLM session, subscribes to the channel,
/// runs an async loop of receive -> LLM -> act -> report.
public actor AgentActor {
    let id: UUID
    let configuration: AgentConfiguration
    private let provider: any LLMProvider
    private let tools: [any AgentTool]
    /// Optional source of additional, dynamically-changing tools (currently MCP
    /// server tools for Brown). Queried at the top of each turn so per-server/per-tool
    /// toggles and `tools/list_changed` updates take effect on the next LLM call.
    private let dynamicToolsProvider: (@Sendable () async -> [any AgentTool])?
    /// The static `tools` merged with the latest `dynamicToolsProvider()` result.
    /// Refreshed each turn by `refreshActiveTools()` and used for both tool-definition
    /// assembly and tool-call dispatch.
    private var activeTools: [any AgentTool]
    /// Per-agent tool registry + availability gate. Rebuilt each turn from the candidate
    /// set (built-ins + dynamic MCP tools); `activeTools` is its `availableTools()`.
    private var toolRegistry = ToolRegistry()
    /// When true (Brown only), this agent's tools are security-scoped per task: candidates are
    /// seeded *disabled* and only `approvedToolNames` (plus forced lifecycle tools) are
    /// available. When false (Smith/Jones), every candidate is seeded approved (no scoping).
    private var toolScopingEnabled = false
    /// The current security-approved tool names (the scoping verdict). Drives `isApproved`.
    private var approvedToolNames: Set<String> = []
    /// Whether the worker has acknowledged its task yet — gates which forced lifecycle tools
    /// are exposed (pre-ack: `task_acknowledged`; post-ack: `task_update` / `task_complete`).
    private var taskAcknowledged = false
    /// Fingerprint of the candidate set at the last scoping. A change (MCP added/removed/
    /// redefined) triggers a fresh stateless re-scope at the next turn boundary.
    private var lastScopedFingerprint: String?
    /// Fired when the approved tool set changes (initial scope already happened in the runtime;
    /// this is for mid-task re-scopes) so the runtime can persist it on the task as a record.
    private var onApprovedToolsChanged: (@Sendable (Set<String>) async -> Void)?
    /// Fired (when the set changes) with the names of the tools currently available to this
    /// agent — the live, registry-gated set — so the inspector can show the real scoped tools
    /// rather than the static configured list.
    private var onActiveToolNamesChanged: (@Sendable ([String]) -> Void)?
    private var lastPublishedToolNames: [String]?
    private let toolContext: ToolContext

    private var conversationHistory: [LLMMessage] = []
    private var isRunning = false
    private var runTask: Task<Void, Never>?

    /// Direct security evaluator for tool approval (replaces Jones agent + ToolRequestGate).
    private var securityEvaluator: SecurityEvaluator?
    /// Token usage store for persistent analytics. Set via `setUsageStore(_:)`.
    private var usageStore: UsageStore?
    /// Session ID for the current orchestration run — stamped on every UsageRecord.
    /// Set via `setSessionID(_:)` at start time. Nil when the actor is running
    /// detached from a session (shouldn't happen in normal orchestration).
    private var sessionID: UUID?
    /// Captured before context pruning, emitted on the next UsageRecord.
    private var pendingPreResetTokens: Int?
    /// Accumulators for the current turn's tool execution stats. Populated during
    /// `handleResponse` as each tool runs; read and zeroed when the UsageRecord is
    /// written after `handleResponse` returns.
    private var turnToolExecutionMs: Int = 0
    private var turnToolResultChars: Int = 0
    /// Set after context pruning to prevent re-using stale token counts from `llmTurns`.
    /// Cleared on the next successful LLM response.
    private var lastUsageStale = false

    /// How long the idle loop waits between checks. Mutable so the user can adjust at runtime.
    private var pollInterval: TimeInterval

    /// Messages from the channel that arrived while waiting for the LLM.
    private var pendingChannelMessages: [ChannelMessage] = []

    /// Attachments staged by `view_attachment` for injection into the next user turn.
    /// Drained by `drainPendingMessages` — image bytes (downscaled) become content blocks
    /// in the assembled LLM message; text/document refs are appended to the message body.
    /// Cleared after each drain so a stage that doesn't get a turn (rare) doesn't leak
    /// across runs.
    private var pendingStagedAttachments: [(attachment: Attachment, detail: AttachmentDetail)] = []

    /// Detail tier requested by `view_attachment`. Controls which downscale variant gets
    /// staged for injection. Mirrors the tool's `detail` parameter.
    enum AttachmentDetail: Sendable {
        case thumbnail  // 512px long edge
        case standard   // 1024px long edge (default)
        case full       // original bytes, no resize

        var maxLongEdge: Int? {
            switch self {
            case .thumbnail: return 512
            case .standard: return 1024
            case .full: return nil
            }
        }
    }

    /// Whether the agent has unprocessed input that requires an LLM call.
    /// Prevents re-querying the LLM with identical context after a text-only response.
    private var hasUnprocessedInput = false

    /// Timestamp of the most recently received channel message. Used for debounce.
    private var lastChannelMessageAt: Date?
    /// True only when the agent was idle and new channel messages arrived, triggering
    /// the debounce window. Cleared once we commit to an LLM call. Stays false during
    /// an active tool loop so tool results are processed without unnecessary delay.
    private var debouncingForMessages = false
    /// All scheduled wakes for this agent. Each carries an id, time, reason, and optional task
    /// association. Sorted ascending by `wakeAt`. The earliest wake bounds the next idle sleep.
    private var scheduledWakes: [ScheduledWake] = []

    /// The currently sleeping idle task. Cancelling it wakes the agent early.
    private var idleSleepTask: Task<Void, Never>?

    /// Seconds of channel silence required before processing new messages.
    private let messageDebounceInterval: TimeInterval

    /// Timestamp of the most recent direct message from the user to this agent.
    /// Used to gate availability of the `reply_to_user` tool.
    private var lastDirectUserMessageAt: Date?

    /// Tracks consecutive LLM errors for exponential backoff.
    private var consecutiveErrors = 0
    private static let maxConsecutiveErrors = 50
    private static let maxBackoffSeconds: Double = 180

    /// Wall-clock seconds before the per-turn stall watchdog logs a warning and posts
    /// a system message. The watchdog itself doesn't unstick anything (per-tool timeouts
    /// in `runToolWithTimeout` and URLSession's resource timeout do that) — it just makes
    /// a stuck "Thinking" indicator observable from `log stream` and the channel.
    /// Set well above any single legitimate LLM call + tool batch (gpt-5.5 with reasoning
    /// can run a minute, large file_read fan-outs add a few more) but well below the point
    /// at which a user would assume the agent is dead.
    private static let stallWatchdogSeconds: Int = 600

    /// Tracks consecutive context overflow errors (separate from general errors).
    /// Context overflows trigger aggressive pruning instead of backoff.
    private var consecutiveContextOverflows = 0
    private static let maxContextOverflowRetries = 3

    /// Tracks consecutive prune-driven rebuilds without an intervening successful
    /// LLM turn. The run loop calls `pruneHistoryIfNeeded` at the top of every
    /// iteration; if the rebuilt context is still over the threshold, the next
    /// iteration triggers another rebuild — without this guard a misconfigured
    /// model or oversized task envelope put the loop in a tight cycle observed in
    /// production posting roughly a thousand "Context rebuilt..." banners per
    /// second. Reset on every successful LLM response.
    private var consecutivePruneRebuilds = 0
    private static let maxConsecutivePruneRebuilds = 3

    /// Tracks consecutive LLM responses that contain only text (no tool calls).
    /// When this exceeds the role-specific threshold, the agent is likely
    /// degenerate (e.g. repetition loop) and should be terminated.
    /// Brown (tool-heavy) triggers at 6; Smith (conversational) at 30.
    private var consecutiveTextOnlyResponses = 0

    /// Timestamp of the most recent text-only response. Used to tell a tight degenerate loop
    /// (responses seconds apart) from legitimate periodic idleness — e.g. Smith answering the
    /// 10-minute Brown digest with "No action needed." across many hours. Without this, those
    /// well-separated idle assessments accumulated toward the text-only limit and terminated a
    /// perfectly healthy Smith (observed: 30 digest ticks over ~5h killed it as a "loop").
    private var lastTextOnlyResponseAt: Date?

    /// A text-only response arriving at least this long after the previous one is treated as a
    /// fresh idle assessment (digest tick, scheduled wake, new user message), not a loop
    /// iteration — so `consecutiveTextOnlyResponses` resets. Comfortably below the 600s digest
    /// cadence and far above any tight degenerate loop, which re-fires in seconds.
    private static let textOnlyLoopGapSeconds: TimeInterval = 120

    /// Tracks consecutive completely empty responses (no text AND no tool calls).
    /// Distinct from text-only: empty means the model produced NOTHING, not even
    /// narration. For Brown, a three-strike escalation applies:
    ///   1st: inject a continuation prompt and retry immediately
    ///   2nd: rebuild context from task state (same recovery as context overflow)
    ///   3rd: terminate — the model is unable to proceed
    /// Reset on any non-empty response.
    private var consecutiveEmptyResponses = 0
    private static let maxConsecutiveEmptyResponses = 3

    /// Tracks consecutive identical tool calls (same name + same normalized arguments).
    /// Catches degenerate loops where the LLM repeatedly calls the same tool with the same
    /// arguments (e.g. task_update spam). Any different tool call or text-only response resets.
    /// Threshold of 4 is safely above the WARN retry case (max 2 identical calls).
    private var lastToolCallSignature: String?
    private var consecutiveIdenticalToolCalls = 0
    private static let maxConsecutiveIdenticalToolCalls = 4

    /// Brown-only: time of the most recent successful task_acknowledged/task_update/task_complete.
    /// Used by the silence nudge. Initialized when the run loop starts.
    private var lastTaskCommunicationAt: Date?
    /// Brown-only: tool calls Brown has executed since his last task communication.
    /// Reset on every successful task_acknowledged/task_update/task_complete.
    private var toolCallsSinceTaskCommunication = 0
    /// Brown-only: armed = the nudge is allowed to fire. Cleared once the nudge fires,
    /// re-armed when Brown sends a task communication. Prevents the nudge from re-firing
    /// every iteration while Brown is still silent.
    private var brownSilenceNudgeArmed = true
    /// The nudge fires if EITHER:
    ///   (a) ≥ minSeconds elapsed AND ≥ minToolCalls executed since last task communication, OR
    ///   (b) ≥ hardCeilingSeconds elapsed regardless of tool-call count.
    /// (a) catches the common drift case while ignoring brief tool-call bursts. (b) is the
    /// hard ceiling for slow-tool cases — e.g. a long `pnpm install` followed by a slow build,
    /// only a few tool calls in 20 minutes, but Brown is still silent and Smith deserves to know.
    private static let brownSilenceNudgeMinSeconds: TimeInterval = 300       // 5 minutes
    private static let brownSilenceNudgeMinToolCalls = 10
    private static let brownSilenceNudgeHardCeilingSeconds: TimeInterval = 900  // 15 minutes

    /// Smith-only: time of the last digest wake. Used to gate the periodic auto-digest.
    /// Reset on every successful digest fire AND on inbound task_update / task_complete from
    /// Brown (Smith already saw fresh signal that way). Initialized at agent start.
    private var lastSmithDigestAt: Date?
    /// Smith-only: how often to auto-digest. Paired with Brown's 9-minute silence-nudge ceiling
    /// so by the time Smith digests, Brown has either responded to the nudge (Smith already saw)
    /// or is still ignoring it (digest content).
    private static let smithDigestIntervalSeconds: TimeInterval = 600
    /// Smith-only: closure that builds a brief digest of Brown's recent activity. Set by the
    /// orchestration runtime after Smith is constructed; nil = digest disabled. Argument is the
    /// since-cutoff. Returns nil to suppress this fire (no fresh activity).
    private var smithDigestProvider: (@Sendable (Date) async -> String?)?

    /// Timer-lifecycle callbacks. The runtime wires these so the timers UI / event log can
    /// observe scheduling without poking actor internals. See `setTimerCallbacks(onScheduled:onFired:onCancelled:)`.
    private var onWakeScheduled: (@Sendable (ScheduledWake) -> Void)?
    /// Fires once per `checkScheduledWake` batch with the *primary* wake (first in the batch)
    /// and the full set of due wakes — keeping the batch grouped so the event log can show a
    /// single fire per LLM turn instead of N rows.
    private var onWakeFired: (@Sendable (ScheduledWake, [ScheduledWake]) -> Void)?
    private var onWakeCancelled: (@Sendable (ScheduledWake, WakeCancellationCause) -> Void)?
    /// Hook the runtime wires to auto-execute `run_task` for a fired wake without going
    /// through Smith's LLM. Eliminates the dependency on the model to follow the
    /// `[System: A timer has fired]` imperative — weak local models (e.g. gemma3:27b)
    /// were asking the user for confirmation instead of executing. The wake is
    /// considered an "auto-run" wake when its imperative was rendered by
    /// `TaskActionKind.run.imperativeText` AND it carries a `taskID`. Other actions
    /// (pause/stop/summarize) still flow through Smith for now.
    private var onAutoRunTask: (@Sendable (UUID) async -> Void)?

    private var maxToolCallsPerIteration: Int
    /// Maximum concurrent Jones security evaluations to prevent overwhelming the LLM backend.
    private static let maxConcurrentEvaluations = 5

    /// Worst-case character overhead for tool definitions and per-turn suffixes
    /// that are sent with each API call but not stored in conversationHistory.
    private let apiOverheadChars: Int

    /// When true, the agent has called `task_complete` and is waiting for Smith's review.
    /// While set, `drainPendingMessages` will not re-wake the agent unless a private message
    /// addressed to it arrives (indicating Smith sent revision feedback).
    private var awaitingTaskReview = false

    /// Messages held back from the current drain to be delivered on a separate turn.
    /// Used to ensure task_complete messages get their own focused LLM turn.
    private var deferredMessages: [ChannelMessage] = []

    /// When set, the agent executes this tool on its first turn without calling the LLM.
    /// Used for `task_acknowledged` on fresh task assignments — saves tokens and latency
    /// since the tool takes no arguments.
    private var syntheticFirstToolCall: String?

    /// Per-turn LLM call log for per-turn inspection.
    private var llmTurns: [LLMTurnRecord] = []
    /// Message count at the time of the previous LLM call — used to compute inputDelta.
    private var lastTurnMessageCount: Int = 0

    /// Maximum number of turn records kept per agent. Oldest are dropped when exceeded.
    private static let maxTurnRecords = 100

    /// Only the most recent N turns retain their full contextSnapshot; older turns
    /// have the snapshot stripped to avoid O(n^2) memory growth across long sessions.
    private static let recentSnapshotWindow = 10

    /// Hard cap on the size of the old file we'll read from disk to compute
    /// a file_write diff. Files larger than this skip the diff entirely (the
    /// row renders the path + output without an inline diff). Only the
    /// resulting `[DiffLine]` is persisted, not the raw content — this cap
    /// exists to bound the disk I/O on the actor thread, not the stored size.
    /// DiffGenerator has its own independent 1000-line cap that kicks in for
    /// small-byte, many-line inputs.
    private static let maxDiffCaptureBytes = 1_000_000

    /// Character set used to generate synthetic tool-call IDs. Precomputed so we
    /// can pull random elements without force-unwrapping a substring on every char.
    private static let toolCallIDCharset: [Character] = Array(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    )

    /// Fires after each LLM turn is recorded, pushing the turn to the UI layer.
    private var onTurnRecorded: (@Sendable (LLMTurnRecord) -> Void)?

    /// Fires when the conversation history changes, pushing a live snapshot to the UI layer.
    private var onContextChanged: (@Sendable ([LLMMessage]) -> Void)?

    init(
        id: UUID = UUID(),
        configuration: AgentConfiguration,
        provider: any LLMProvider,
        tools: [any AgentTool],
        toolContext: ToolContext,
        dynamicToolsProvider: (@Sendable () async -> [any AgentTool])? = nil
    ) {
        self.id = id
        self.configuration = configuration
        self.provider = provider
        self.tools = tools
        self.activeTools = tools
        self.dynamicToolsProvider = dynamicToolsProvider
        self.toolContext = toolContext
        self.pollInterval = configuration.pollInterval
        self.messageDebounceInterval = configuration.messageDebounceInterval
        self.maxToolCallsPerIteration = configuration.maxToolCallsPerIteration

        // Worst-case overhead: all tool definitions sent with each API call.
        let toolChars = tools.reduce(0) {
            $0 + $1.definition(for: configuration.role).estimatedCharacterCount
        }
        self.apiOverheadChars = toolChars

        conversationHistory.append(.system(configuration.systemPrompt))
    }

    /// Injects the security evaluator used for Brown's tool approval flow.
    func setSecurityEvaluator(_ evaluator: SecurityEvaluator) {
        securityEvaluator = evaluator
    }

    /// Injects the usage store for persistent token analytics.
    public func setUsageStore(_ store: UsageStore) {
        usageStore = store
    }

    /// Injects the orchestration session ID. Called at start time by the runtime so
    /// every UsageRecord this actor writes is stamped with the current session.
    public func setSessionID(_ id: UUID?) {
        sessionID = id
    }

    /// Registers a callback fired after each LLM turn is recorded.
    public func setOnTurnRecorded(_ handler: @escaping @Sendable (LLMTurnRecord) -> Void) {
        onTurnRecorded = handler
    }

    /// Registers a callback fired when the conversation history changes materially.
    public func setOnContextChanged(_ handler: @escaping @Sendable ([LLMMessage]) -> Void) {
        onContextChanged = handler
    }

    /// Returns a snapshot of the agent's full conversation history for inspection.
    public func contextSnapshot() -> [LLMMessage] {
        conversationHistory
    }

    /// Appends a user-role message to this agent's conversation history before any LLM
    /// call. Used by the orchestration runtime to seed Brown with the task briefing at
    /// spawn time without going through the public channel — the briefing was previously
    /// posted as a Smith → Brown channel message that duplicated the New Task banner's
    /// description for the user. Direct injection keeps the data flow `taskStore → Brown`
    /// instead of `taskStore → Smith → channel.post → Brown`, eliminates the redundant
    /// transcript row, and stays symmetric with `rebuildContextFromTask` (which already
    /// seeds Brown's history from the task store on the rebuild path).
    public func appendUserMessage(_ text: String) {
        conversationHistory.append(.user(text))
        hasUnprocessedInput = true
        pushLiveContext()
    }

    /// Same as `appendUserMessage(_:)` but also injects image attachments as inline
    /// image content for the LLM. Non-image attachments should already be referenced in
    /// the text body via `[filename](file://…) … id=<UUID>` markdown lines so the agent
    /// can quote the id forward downstream. Used by the seed-Brown briefing path so a
    /// task created with attached files reaches Brown's first LLM turn with the bytes intact.
    /// Stages attachments for injection into the next user turn. Called by the
    /// `view_attachment` tool so Brown can pull a previously-known attachment into his
    /// visual context on demand. Multiple calls before a single LLM turn accumulate;
    /// duplicates (same `id` and `detail`) are deduped on drain.
    ///
    /// Internal because `AttachmentDetail` is internal — the only caller is the
    /// `OrchestrationRuntime`-supplied closure on `ToolContext`, which is in-package.
    func stageAttachments(_ items: [(attachment: Attachment, detail: AttachmentDetail)]) {
        pendingStagedAttachments.append(contentsOf: items)
        hasUnprocessedInput = true
    }

    public func appendUserMessage(_ text: String, attachments: [Attachment]) {
        if attachments.isEmpty {
            appendUserMessage(text)
            return
        }
        var images: [LLMImageContent] = []
        for attachment in attachments where attachment.isImage {
            guard let data = attachment.data else { continue }
            // Same downscale as the channel-message path. Briefing-time injection is the
            // most context-expensive moment in Brown's lifetime — every reset re-pays the
            // image cost, so doing it at full resolution by default would compound badly
            // across long-running tasks.
            let resized = ImageDownscaler.downscale(data, sourceMimeType: attachment.mimeType)
            guard ImageDownscaler.isProviderInjectable(mimeType: resized.mimeType) else { continue }
            images.append(LLMImageContent(data: resized.data, mimeType: resized.mimeType))
        }
        if images.isEmpty {
            conversationHistory.append(.user(text))
        } else {
            conversationHistory.append(.user(text, images: images))
        }
        hasUnprocessedInput = true
        pushLiveContext()
    }

    /// Returns a snapshot of recent LLM turns for per-turn inspection.
    public func turnsSnapshot() -> [LLMTurnRecord] {
        llmTurns
    }

    /// Replaces the system prompt in the agent's conversation history.
    public func updateSystemPrompt(_ prompt: String) {
        guard !conversationHistory.isEmpty else { return }
        conversationHistory[0] = .system(prompt)
        pushLiveContext()
    }

    /// Updates the idle poll interval for this agent.
    public func updatePollInterval(_ interval: TimeInterval) {
        pollInterval = interval
    }

    /// Updates the maximum number of tool calls executed per LLM response.
    public func updateMaxToolCalls(_ count: Int) {
        maxToolCallsPerIteration = count
    }

    /// Queues a synthetic tool call to execute on the agent's first turn, bypassing the LLM.
    /// The tool must take no arguments. Cleared after execution.
    public func setSyntheticFirstToolCall(_ toolName: String) {
        syntheticFirstToolCall = toolName
    }

    /// Enables per-task security scoping for this agent (Brown), seeding the initial approved
    /// set from the runtime's pre-start scoping pass. After this, only approved + forced
    /// lifecycle tools are available; mid-task candidate changes trigger a fresh stateless
    /// re-scope at the turn boundary.
    public func enableToolScoping(approvedNames: Set<String>) {
        toolScopingEnabled = true
        approvedToolNames = approvedNames
    }

    /// Registers a callback fired when the approved tool set changes mid-task, so the runtime
    /// can persist the new set on the task as a record.
    public func setOnApprovedToolsChanged(_ handler: @escaping @Sendable (Set<String>) async -> Void) {
        onApprovedToolsChanged = handler
    }

    /// Registers a callback fired (on change) with the live set of available tool names, so the
    /// inspector reflects the actual scoped tools rather than the static configured list.
    public func setOnActiveToolNamesChanged(_ handler: @escaping @Sendable ([String]) -> Void) {
        onActiveToolNamesChanged = handler
    }

    /// Replaces the actor's scheduled-wake list with the supplied set. Used by the runtime at
    /// cold-launch to replay wakes persisted from a prior process. Bypasses the
    /// `onWakeScheduled` callback so the timer-event log isn't double-stamped (the original
    /// `.scheduled` events are already persisted in the timer history). Wakes with `wakeAt`
    /// in the past relative to `now` are kept as-is — `checkScheduledWake()` on the next
    /// loop iteration will fire them, which is the correct recovery behavior for a wake that
    /// elapsed while the app was quit.
    public func restoreScheduledWakes(_ wakes: [ScheduledWake]) {
        scheduledWakes = wakes.sorted { $0.wakeAt < $1.wakeAt }
        interruptIdleSleep()
    }

    /// Schedules a wake. Returns `.scheduled(wake)` on success, or `.error(...)` for
    /// validation failures. If `replacesID` is supplied, that wake is cancelled before
    /// scheduling the new one. Multiple wakes can share a wake time without conflict —
    /// callers that genuinely want a single replacement should pass `replacesID`.
    func scheduleWake(
        wakeAt: Date,
        instructions: String,
        taskID: UUID? = nil,
        replacesID: UUID? = nil,
        recurrence: Recurrence? = nil,
        originalID: UUID? = nil,
        previousFireAt: Date? = nil,
        survivesTaskTermination: Bool = false
    ) -> ScheduleWakeOutcome {
        let trimmedInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInstructions.isEmpty else {
            return .error("instructions must not be empty — describe what the agent should do when the wake fires.")
        }

        if let replacesID, let replacedWake = scheduledWakes.first(where: { $0.id == replacesID }) {
            scheduledWakes.removeAll { $0.id == replacesID }
            onWakeCancelled?(replacedWake, .replaced)
        }

        let wake = ScheduledWake(
            wakeAt: wakeAt,
            instructions: trimmedInstructions,
            taskID: taskID,
            recurrence: recurrence,
            originalID: originalID,
            previousFireAt: previousFireAt,
            survivesTaskTermination: survivesTaskTermination
        )
        scheduledWakes.append(wake)
        scheduledWakes.sort { $0.wakeAt < $1.wakeAt }
        interruptIdleSleep()
        onWakeScheduled?(wake)
        return .scheduled(wake)
    }

    /// Returns all currently-scheduled wakes for this agent, sorted ascending by `wakeAt`.
    public func listScheduledWakes() -> [ScheduledWake] {
        scheduledWakes
    }

    /// Cancels a single wake by id. Returns true if it existed and was removed.
    @discardableResult
    public func cancelWake(id: UUID) -> Bool {
        guard let removed = scheduledWakes.first(where: { $0.id == id }) else { return false }
        scheduledWakes.removeAll { $0.id == id }
        onWakeCancelled?(removed, .userRequest)
        return true
    }

    /// Cancels wakes associated with the given task whose `survivesTaskTermination` is false.
    /// Returns the ids of cancelled wakes. Wakes flagged to survive — currently `run` and
    /// `summarize` action wakes — are deliberately retained so the user can queue multiple
    /// future runs against the same task without the first run's completion wiping the
    /// queue.
    @discardableResult
    public func cancelWakesForTask(_ taskID: UUID) -> [UUID] {
        let cancelled = scheduledWakes.filter { $0.taskID == taskID && !$0.survivesTaskTermination }
        scheduledWakes.removeAll { $0.taskID == taskID && !$0.survivesTaskTermination }
        for wake in cancelled {
            onWakeCancelled?(wake, .taskTerminated)
        }
        return cancelled.map { $0.id }
    }

    /// Smith-only: registers the closure used to assemble periodic Brown-activity digests.
    /// Idempotent — replaces any prior provider.
    public func setSmithDigestProvider(_ provider: @escaping @Sendable (Date) async -> String?) {
        smithDigestProvider = provider
    }

    /// Registers timer-lifecycle callbacks fired from the actor when wakes are scheduled,
    /// fired, or cancelled. Used by `OrchestrationRuntime` to populate the timer-event log
    /// without leaking actor internals into the UI.
    public func setTimerCallbacks(
        onScheduled: (@Sendable (ScheduledWake) -> Void)? = nil,
        onFired: (@Sendable (ScheduledWake, [ScheduledWake]) -> Void)? = nil,
        onCancelled: (@Sendable (ScheduledWake, WakeCancellationCause) -> Void)? = nil
    ) {
        onWakeScheduled = onScheduled
        onWakeFired = onFired
        onWakeCancelled = onCancelled
    }

    /// Wires the runtime's auto-run handler. When a wake fires whose imperative matches
    /// the `TaskActionKind.run` shape, `checkScheduledWake` calls this directly instead
    /// of injecting the imperative into Smith's conversation. The runtime then drives
    /// `restartForNewTask`; Smith finds out about the new run when its fresh process
    /// boots with `resumingTaskID` set.
    public func setOnAutoRunTask(_ handler: @escaping @Sendable (UUID) async -> Void) {
        onAutoRunTask = handler
    }

    /// Returns true when this wake was scheduled by `TaskActionKind.run.imperativeText` —
    /// i.e. its imperative starts with "Call \`run_task\` on ". This is the only action
    /// whose execution is fully mechanical (no LLM judgment required), so the runtime
    /// can drive it directly. The wake's `taskID` is the source of truth for which task
    /// to run; the imperative string match is just the action discriminator.
    static func wakeIsAutoRunRunTask(_ wake: ScheduledWake) -> Bool {
        wake.taskID != nil
            && wake.instructions.hasPrefix("Call `run_task` on ")
    }

    /// Starts the agent's run loop.
    public func start(initialInstruction: String? = nil) {
        guard !isRunning else { return }
        isRunning = true
        if configuration.role == .brown {
            lastTaskCommunicationAt = Date()
            toolCallsSinceTaskCommunication = 0
            brownSilenceNudgeArmed = true
        } else if configuration.role == .smith {
            lastSmithDigestAt = Date()
        }

        if let instruction = initialInstruction {
            conversationHistory.append(.user(instruction))
            hasUnprocessedInput = true
            pushLiveContext()
        }

        let role = configuration.role
        let ctx = toolContext
        let agentID = id
        runTask = Task { [weak self] in
            // Announce on the public channel so all agents and the UI know we're alive.
            await ctx.post(ChannelMessage(
                sender: .agent(role),
                content: "\(role.displayName) agent \(agentID) is online.",
                metadata: ["messageKind": .string("agent_online")]
            ))

            guard let self else { return }
            await self.runLoop()
        }
    }

    /// Stops the agent and waits (up to a bounded grace period) for its run loop
    /// to actually exit before returning.
    ///
    /// Without the await, callers like `OrchestrationRuntime.stopAll` and
    /// `terminateAgent` were only signalling cancellation — the run loop could
    /// still be blocked inside `provider.send(...)` or `BashTool.execute(...)`
    /// when the runtime moved on, spawning a *new* agent for the same role while
    /// the old one kept executing. That produced "zombie Browns" that logged LLM
    /// calls for a task nobody believed they were on anymore.
    ///
    /// The grace period is capped so a pathologically unresponsive subprocess
    /// can't block `stopAll` indefinitely; the pair of this + a cancel-aware
    /// `ProcessRunner` means clean unwinds usually take milliseconds.
    public func stop() async {
        let role = configuration.role.rawValue
        let agentID = id.uuidString.prefix(8)
        let stopStart = Date()
        Self.stopLogger.notice("AgentActor.stop entry role=\(role, privacy: .public) agent=\(agentID, privacy: .public)")
        isRunning = false
        consecutiveEmptyResponses = 0
        guard let task = runTask else {
            Self.stopLogger.notice("AgentActor.stop no runTask — early return role=\(role, privacy: .public) agent=\(agentID, privacy: .public)")
            return
        }
        task.cancel()
        Self.stopLogger.notice("AgentActor.stop task.cancel called role=\(role, privacy: .public) agent=\(agentID, privacy: .public)")

        // Race the run loop's exit against a grace timeout. Whichever finishes
        // first wins; the other is cancelled. The `runTask.value` branch runs
        // on the cooperative thread pool, not on this actor, so actor reentrancy
        // lets the run loop continue processing the cancellation while stop()
        // is suspended here.
        let cleanExit = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                _ = await task.value
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        let elapsedMs = Int(Date().timeIntervalSince(stopStart) * 1000)
        if cleanExit {
            Self.stopLogger.notice("AgentActor.stop runTask exited role=\(role, privacy: .public) agent=\(agentID, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public)")
        } else {
            Self.stopLogger.warning("AgentActor.stop 5s timeout fired — runTask did not exit role=\(role, privacy: .public) agent=\(agentID, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public)")
        }
        runTask = nil

        // Force-clear this agent's live activity indicators. A turn cancelled mid-flight leaves
        // its `onProcessingStateChange(true)` un-paired: that pairing's clearing `defer` only runs
        // when the in-flight LLM call finally returns, which — for a slow or cancellation-ignoring
        // provider (e.g. a hung Ollama Cloud request) — can be minutes after `stop()` gave up and
        // orphaned the call. Without this, the agent shows "Thinking"/"Evaluating" indefinitely
        // after being paused/stopped. Firing `false` here is idempotent with the eventual defer.
        toolContext.onProcessingStateChange(false)
        toolContext.onJonesProcessingStateChange(false)

        // Drop UI/runtime observer callbacks now that the agent has shut down.
        // Releases the strong references those closures hold against the app
        // layer's view model so a stopped agent can be deinitialized cleanly.
        onTurnRecorded = nil
        onContextChanged = nil
        smithDigestProvider = nil
        onWakeScheduled = nil
        onWakeFired = nil
        onWakeCancelled = nil
        onAutoRunTask = nil
    }

    /// Injects a channel message into the agent's pending queue.
    ///
    /// Delivery rules:
    /// - Private messages (recipientID != nil) are only delivered to the named recipient.
    /// - Public messages are delivered to everyone except the sender's own role.
    /// - System messages are always delivered.
    public func receiveChannelMessage(_ message: ChannelMessage) {
        guard isRunning else { return }

        if let recipientID = message.recipientID {
            // Private message — only the intended recipient receives it.
            guard recipientID == id else { return }
        } else {
            // Public message — ignore our own role to avoid echo loops.
            if case .agent(let role) = message.sender, role == configuration.role {
                return
            }
        }

        // Drop UI-only notification messages that no agent needs to process.
        if case .string(let kind) = message.metadata?["messageKind"] {
            switch kind {
            case "task_created", "memory_saved", "memory_searched":
                return
            default:
                break
            }
        }

        // Drop error messages — they are for the UI only. Feeding them back into
        // agent conversation history wastes tokens and creates a death spiral when
        // the error is a context overflow (each retry adds the error text, growing
        // the context further).
        if case .bool(true) = message.metadata?["isError"] {
            return
        }

        // Optional per-agent content filter — drops messages that shouldn't trigger a wake.
        if let filter = configuration.messageAcceptFilter, !filter(message) { return }

        // Track when the user sends a direct message to this agent (for reply_to_user availability)
        if case .user = message.sender, message.recipientID == id {
            lastDirectUserMessageAt = Date()
        }

        // Smith only: a task_update or task_complete from Brown is fresh signal — reset the
        // digest clock so we don't fire an auto-digest seconds later that would just summarize
        // what Smith already saw via this message.
        if configuration.role == .smith,
           case .string(let kind) = message.metadata?["messageKind"],
           kind == "task_update" || kind == "task_complete" {
            lastSmithDigestAt = Date()
        }

        pendingChannelMessages.append(message)
        lastChannelMessageAt = Date()
        // Only start debouncing if the agent was idle — during an active tool loop
        // we want tool results processed immediately without the debounce delay.
        if !hasUnprocessedInput {
            debouncingForMessages = true
        }
        interruptIdleSleep()
    }

    /// Whether the agent is currently running.
    public var running: Bool {
        isRunning
    }

    /// The names of tools available to this agent. Nonisolated because `configuration` is a let.
    public nonisolated var toolNames: [String] {
        configuration.toolNames
    }

    // MARK: - Private

    /// Refreshes `activeTools` by merging the static built-in tools with the latest
    /// dynamic tools (MCP). Called at the top of each turn so toggles and server-side
    /// `tools/list_changed` updates are reflected on the next LLM call. No-op for
    /// agents without a dynamic provider (everyone except Brown today).
    private func refreshActiveTools() async {
        let dynamic = await dynamicToolsProvider?() ?? []
        let candidates = tools + dynamic

        guard toolScopingEnabled else {
            // Unscoped agents (Smith/Jones): every candidate approved → activeTools == all
            // candidates, identical to the pre-registry behavior.
            toolRegistry.rebuild(candidates: candidates, defaultApproved: true)
            activeTools = toolRegistry.availableTools()
            publishActiveToolNamesIfChanged()
            return
        }

        // Scoped agent (Brown): candidates start disabled; only the security-approved set and
        // forced lifecycle tools are available.
        toolRegistry.rebuild(candidates: candidates, defaultApproved: false)

        // Stateless per-turn re-evaluation: if the candidate set changed (by content
        // fingerprint, so a silent redefinition counts), re-scope from scratch. The very
        // first refresh just records the fingerprint — the runtime already scoped this set
        // before the worker started.
        let fingerprint = toolRegistry.candidateFingerprint
        if let last = lastScopedFingerprint, last != fingerprint {
            await rescopeToolsStateless()
        }
        lastScopedFingerprint = fingerprint

        toolRegistry.applyApproval(approvedNames: approvedToolNames)
        applyForcedLifecycleFlags()
        activeTools = toolRegistry.availableTools()
        publishActiveToolNamesIfChanged()
    }

    /// Publishes the current available tool names to the inspector when they change. Uses the
    /// registry-available set (never empty — forced lifecycle tools are always present), so it
    /// won't trip the "terminated" badge that keys off an empty tool list.
    private func publishActiveToolNamesIfChanged() {
        let names = activeTools.map(\.name)
        guard names != lastPublishedToolNames else { return }
        lastPublishedToolNames = names
        onActiveToolNamesChanged?(names)
    }

    /// Forces the small set of trusted built-in lifecycle tools available regardless of the
    /// security verdict, so the task lifecycle always functions. Phased on acknowledgement:
    /// pre-ack only `task_acknowledged`; post-ack `task_update` / `task_complete`. `reply_to_user`
    /// is forced throughout but remains gated by its own `isAvailable(in:)` context check
    /// (user-has-messaged) at the definition/dispatch sites. Forcing is a deliberate security
    /// bypass applied ONLY to these trusted built-ins.
    private func applyForcedLifecycleFlags() {
        toolRegistry.setForcedAvailable("task_acknowledged", !taskAcknowledged)
        toolRegistry.setForcedAvailable("task_update", taskAcknowledged)
        toolRegistry.setForcedAvailable("task_complete", taskAcknowledged)
        toolRegistry.setForcedAvailable("request_help", taskAcknowledged)
        toolRegistry.setForcedAvailable("reply_to_user", true)
    }

    /// Re-runs the security scoping pass against the current candidate set (stateless — no
    /// memory of prior approvals), updates `approvedToolNames`, persists the new set on the
    /// task, and injects a generic "tools changed" nudge into the worker's history. On failure
    /// the prior approvals are kept (last-known-good) and nothing is injected.
    private func rescopeToolsStateless() async {
        guard let evaluator = securityEvaluator,
              let task = await currentTaskForScoping() else { return }
        // Light the Security Agent card while it re-scopes (a real Jones LLM call).
        toolContext.onJonesProcessingStateChange(true)
        let result = await evaluator.scopeTools(
            candidateTools: toolRegistry.candidateTools,
            taskTitle: task.title,
            taskID: task.id.uuidString,
            taskDescription: task.description
        )
        toolContext.onJonesProcessingStateChange(false)
        guard result.succeeded else { return }
        // Only act when the *approved* set actually changed. A candidate-set change that
        // leaves Brown's usable tools identical (e.g. a new MCP tool that Jones blocks) must
        // not persist a redundant record or nag Brown.
        guard result.approvedNames != approvedToolNames else { return }
        approvedToolNames = result.approvedNames
        await onApprovedToolsChanged?(approvedToolNames)
        // Generic, intentionally short. Fired only on a security-driven change to the usable
        // set — not on the forced-flag transitions this actor drives deliberately (e.g.
        // ack → update/complete).
        conversationHistory.append(.user("[System] Available tools have changed - confirm availability before use."))
    }

    /// The task this worker is currently assigned to, for scoping context.
    private func currentTaskForScoping() async -> AgentTask? {
        let allTasks = await toolContext.taskStore.allTasks()
        return allTasks.first { $0.assigneeIDs.contains(toolContext.agentID) }
    }

    private func runLoop() async {
        while isRunning, !Task.isCancelled {
            // Re-inject deferred messages (e.g. task_complete held back from a previous batch)
            // so they get their own focused LLM turn.
            if !deferredMessages.isEmpty {
                pendingChannelMessages.append(contentsOf: deferredMessages)
                deferredMessages.removeAll()
            }

            // Smith only: search semantic memory and prior tasks based on the latest pending
            // user message and append the results to that message before it enters Smith's
            // LLM context. Lets Smith consider relevant background before creating a task.
            if configuration.role == .smith {
                await injectAutoMemoryContextIfNeeded()
            }

            drainPendingMessages()
            await checkScheduledWake()
            checkBrownSilenceNudge()
            await checkSmithDigest()
            await pruneHistoryIfNeeded()

            guard hasUnprocessedInput else {
                await idleWait()
                continue
            }

            // If the agent transitioned from idle due to new channel messages,
            // wait for the burst to settle before querying the LLM. This flag
            // is false during an active tool loop, so tool results aren't delayed.
            if debouncingForMessages {
                let debounce = debounceTimeRemaining()
                if debounce > 0 {
                    await idleWait(maxDuration: debounce)
                    continue
                }
                debouncingForMessages = false
            }

            // Synthetic first-turn tool call: execute the tool directly without
            // calling the LLM. Used for task_acknowledged on fresh task assignments.
            if let toolName = syntheticFirstToolCall {
                syntheticFirstToolCall = nil
                if let tool = tools.first(where: { $0.name == toolName }) {
                    // Charset is non-empty so randomElement() never returns nil; the
                    // "0" coalesce keeps us off force-unwrap and gives a known fallback
                    // if the constant is ever emptied during refactoring.
                    let callID = String((0..<9).map { _ in
                        Self.toolCallIDCharset.randomElement() ?? "0"
                    })
                    let syntheticCall = LLMToolCall(
                        id: callID,
                        name: toolName,
                        arguments: "{}"
                    )
                    conversationHistory.append(.assistant(toolCalls: [syntheticCall]))
                    let result = await directExecute(syntheticCall, tool: tool)
                    conversationHistory.append(.toolResult(Self.capToolResult(result), callID: syntheticCall.id))
                    if configuration.role == .brown && toolName == "task_acknowledged" {
                        lastTaskCommunicationAt = Date()
                        toolCallsSinceTaskCommunication = 0
                        brownSilenceNudgeArmed = true
                        taskAcknowledged = true
                    }
                    pushLiveContext()
                }
                continue
            }

            do {
                let activeTasks = await toolContext.taskStore.allTasks().filter { $0.disposition == .active }
                let hasRunnableTasks = activeTasks.contains { $0.status.isRunnable }
                let hasAwaitingReview = activeTasks.contains { $0.status == .awaitingReview }
                let availabilityContext = ToolAvailabilityContext(
                    lastDirectUserMessageAt: lastDirectUserMessageAt,
                    agentRole: configuration.role,
                    hasRunnableTasks: hasRunnableTasks,
                    hasAwaitingReviewTasks: hasAwaitingReview
                )
                // Defense-in-depth: while Brown is awaiting review, hand him an empty
                // tool list regardless of per-tool `isAvailable`. The `drainPendingMessages`
                // gate and the silence-nudge guard above should prevent us from reaching
                // this point with `awaitingTaskReview == true`, but if any other wake
                // source slips through (a stray scheduled wake, a future feature, a bug),
                // Brown's LLM turn produces nothing he can act on.
                await refreshActiveTools()
                let toolDefinitions: [LLMToolDefinition]
                if configuration.role == .brown && awaitingTaskReview {
                    toolDefinitions = []
                } else {
                    toolDefinitions = activeTools
                        .filter { $0.isAvailable(in: availabilityContext) }
                        .map { $0.definition(for: configuration.role) }
                }
                toolContext.onProcessingStateChange(true)
                // Stall watchdog: if this turn (LLM call + tool execution) is still
                // active after `Self.stallWatchdogSeconds`, log a warning and post a
                // single system message. Doesn't unstick anything by itself — the
                // per-tool timeout in `runToolWithTimeout` and URLSession's resource
                // timeout handle that — but it makes the next stuck-Thinking incident
                // observable from `log stream` and the channel without `sample`.
                let watchdogContext = toolContext
                let watchdogRoleRaw = configuration.role.rawValue
                let watchdogRoleName = configuration.role.displayName
                let watchdogAgentIDPrefix = String(id.uuidString.prefix(8))
                let watchdogTask = Task.detached { [stallSeconds = Self.stallWatchdogSeconds] in
                    do {
                        try await Task.sleep(for: .seconds(stallSeconds))
                    } catch {
                        return  // cancelled by the defer below — normal completion path
                    }
                    AgentActor.stopLogger.error("AgentActor stall role=\(watchdogRoleRaw, privacy: .public) agent=\(watchdogAgentIDPrefix, privacy: .public) elapsed>=\(stallSeconds, privacy: .public)s — turn still in flight (LLM call or tool execution)")
                    await watchdogContext.post(ChannelMessage(
                        sender: .system,
                        content: "Agent \(watchdogRoleName) has been in the current turn for \(stallSeconds / 60) minutes — unusually long. A legitimate long subprocess (large bash/gh) explains this; an agent stuck on a tool that doesn't honor cancellation does not. Check the agent inspector for the in-flight tool.",
                        metadata: ["isWarning": .bool(true), "agentRole": .string(watchdogRoleRaw)]
                    ))
                }
                defer {
                    watchdogTask.cancel()
                    toolContext.onProcessingStateChange(false)
                }

                let messagesForLLM = conversationHistory

                let llmStartTime = Date()
                let response = try await provider.send(
                    messages: messagesForLLM,
                    tools: toolDefinitions
                )
                let llmLatencyMs = Int(Date().timeIntervalSince(llmStartTime) * 1000)
                guard isRunning else { break }

                consecutiveErrors = 0
                consecutiveContextOverflows = 0
                consecutivePruneRebuilds = 0
                lastUsageStale = false
                // Defensive clamp: every site that reassigns `conversationHistory` resets
                // `lastTurnMessageCount` synchronously, so today it can't exceed the count —
                // but this actor is re-entrant, and a partial-range slice would trap. An
                // empty `inputDelta` is harmless (the turn's inspector row just shows no
                // incremental input) and self-corrects next turn.
                let deltaStart = min(max(lastTurnMessageCount, 0), conversationHistory.count)
                assert(deltaStart == lastTurnMessageCount,
                       "lastTurnMessageCount (\(lastTurnMessageCount)) out of range for history count \(conversationHistory.count)")
                let inputDelta = Array(conversationHistory[deltaStart...])
                lastTurnMessageCount = conversationHistory.count
                let turnRecord = LLMTurnRecord(
                    inputDelta: inputDelta,
                    response: response,
                    totalMessageCount: conversationHistory.count,
                    contextSnapshot: messagesForLLM,
                    latencyMs: llmLatencyMs,
                    modelID: configuration.llmConfig.model,
                    providerType: configuration.providerAPIType.rawValue,
                    providerID: configuration.llmConfig.providerID,
                    temperature: configuration.llmConfig.temperature ?? 0,
                    maxOutputTokens: configuration.llmConfig.maxTokens,
                    thinkingBudget: configuration.llmConfig.thinkingBudget,
                    usage: response.usage
                )
                llmTurns.append(turnRecord)
                pruneOldTurnSnapshots()
                onTurnRecorded?(turnRecord)

                // Capture task context at the moment of the LLM call, before
                // handleResponse runs any tools that might change it (e.g. task_complete).
                // Smith is never in a task's assigneeIDs (only Brown is), so for Smith
                // we look up the currently active task by status instead.
                let currentTaskAtCallTime: AgentTask?
                if configuration.role == .smith {
                    currentTaskAtCallTime = await toolContext.taskStore.currentActiveTask()
                } else {
                    currentTaskAtCallTime = await toolContext.taskStore.taskForAgent(agentID: id)
                }

                // Reset per-turn tool-execution accumulators. handleResponse will add to
                // these as tools run; the UsageRecord below reads the totals.
                turnToolExecutionMs = 0
                turnToolResultChars = 0

                // Run tools via handleResponse, but capture any error so we can still
                // persist the UsageRecord (LLM call succeeded — its token/cost/latency
                // data is valid even if a subsequent tool failed). Re-thrown below so
                // the outer catch still runs its backoff/retry logic.
                var handleResponseError: Error?
                do {
                    try await handleResponse(response)
                } catch {
                    handleResponseError = error
                }

                // Persist usage record for analytics — with tool execution stats now
                // folded in from handleResponse.
                if let usageStore {
                    await UsageRecorder.record(
                        response: response,
                        context: LLMCallContext(
                            agentRole: configuration.role,
                            taskID: currentTaskAtCallTime?.id,
                            modelID: configuration.llmConfig.model,
                            providerType: configuration.providerAPIType.rawValue,
                            providerID: configuration.llmConfig.providerID,
                            configuration: configuration.llmConfig,
                            sessionID: sessionID,
                            preResetInputTokens: pendingPreResetTokens,
                            totalToolExecutionMs: turnToolExecutionMs,
                            totalToolResultChars: turnToolResultChars
                        ),
                        latencyMs: llmLatencyMs,
                        to: usageStore
                    )
                    pendingPreResetTokens = nil
                }

                if let handleResponseError {
                    throw handleResponseError
                }
            } catch {
                let cancelled = Task.isCancelled
                let role = configuration.role.rawValue
                let agentID = id.uuidString.prefix(8)
                Self.stopLogger.notice("AgentActor.runLoop catch role=\(role, privacy: .public) agent=\(agentID, privacy: .public) isRunning=\(self.isRunning, privacy: .public) isCancelled=\(cancelled, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                guard isRunning else { break }

                // Context overflow: the API rejected the request because messages + completion
                // exceed the model's context window. Rebuild context from task state (Brown)
                // or force-prune (others) and retry immediately — backoff won't help.
                if Self.isContextOverflowError(error) {
                    consecutiveContextOverflows += 1
                    let roleName = configuration.role.displayName

                    if consecutiveContextOverflows <= Self.maxContextOverflowRetries {
                        if configuration.role == .brown {
                            let rebuilt = await rebuildContextFromTask()
                            if !rebuilt {
                                // No running task found — fall back to aggressive prune
                                forceAggressivePrune()
                            }
                        } else {
                            forceAggressivePrune()
                        }
                        await toolContext.post(ChannelMessage(
                            sender: .system,
                            content: "Context overflow for \(roleName) — context rebuilt (attempt \(consecutiveContextOverflows)/\(Self.maxContextOverflowRetries)).",
                            metadata: ["isError": .bool(true), "agentRole": .string(configuration.role.rawValue)]
                        ))
                        continue  // Retry immediately with smaller context
                    } else {
                        await toolContext.post(ChannelMessage(
                            sender: .system,
                            content: "Agent \(roleName) stopped: context overflow persists after \(Self.maxContextOverflowRetries) rebuild attempts.",
                            metadata: ["isError": .bool(true), "agentRole": .string(configuration.role.rawValue)]
                        ))
                        isRunning = false
                        break
                    }
                }

                // Log unhandled 400 errors so we can detect patterns that need specific handling.
                Self.logUnhandled400(error)

                consecutiveErrors += 1
                consecutiveContextOverflows = 0  // Reset overflow counter on non-overflow errors

                let backoff = min(
                    3.0 * pow(2.0, Double(min(consecutiveErrors - 1, 10))),
                    Self.maxBackoffSeconds
                )

                // Surface persistent HTTP 4xx errors (anything in 4xx except 408 timeouts
                // and 429 rate limits) on the first occurrence. These are config/payload
                // problems that retrying won't fix — e.g. invalid API key, unsupported
                // parameter for the model, DeepSeek demanding `reasoning_content` be
                // replayed. Waiting for 5 consecutive failures means the user can sit
                // through ~45 seconds of silent backoff before learning anything is
                // wrong, while their bill ticks up on every attempt.
                //
                // Standard suppression (>=5 consecutive errors) still applies to
                // genuinely transient classes (429, 408, 5xx, network) where the next
                // attempt is reasonably expected to succeed.
                let isPersistentClientError: Bool = {
                    guard let providerError = error as? LLMProviderError,
                          case .httpError(let statusCode, _, _) = providerError else {
                        return false
                    }
                    return (400..<500).contains(statusCode)
                        && statusCode != 429
                        && statusCode != 408
                }()

                let shouldSurfaceNow = consecutiveErrors >= 5
                    || (isPersistentClientError && consecutiveErrors == 1)

                if shouldSurfaceNow {
                    await toolContext.post(ChannelMessage(
                        sender: .system,
                        content: "Agent \(configuration.role.displayName) error (\(consecutiveErrors)/\(Self.maxConsecutiveErrors)): \(error.localizedDescription)",
                        metadata: ["isError": .bool(true), "agentRole": .string(configuration.role.rawValue)]
                    ))
                }

                if consecutiveErrors >= Self.maxConsecutiveErrors {
                    await toolContext.post(ChannelMessage(
                        sender: .system,
                        content: "Agent \(configuration.role.displayName) stopped after \(Self.maxConsecutiveErrors) consecutive errors.",
                        metadata: ["isError": .bool(true), "agentRole": .string(configuration.role.rawValue)]
                    ))
                    isRunning = false
                    break
                }

                // Use Task.sleep instead of idleWait — idleWait is interruptible by
                // incoming channel messages (including the error message we just posted),
                // which would cancel the backoff immediately.
                do {
                    try await Task.sleep(for: .seconds(backoff))
                } catch {
                    // Sleep cancelled (agent stopped) — fall through to loop guard
                }
            }
        }
        await toolContext.onSelfTerminate()
    }

    private func handleResponse(_ response: LLMResponse) async throws {
        // Post text to channel unless this agent's raw LLM output is suppressed.
        // Suppressed text is still stored in conversationHistory and visible in the inspector.
        if let text = response.text, !text.isEmpty, !configuration.suppressesRawTextToChannel {
            await toolContext.post(ChannelMessage(
                sender: .agent(configuration.role),
                content: text
            ))
        }

        // For Smith, treat text-only responses as an implicit message_user.
        // In mixed responses (text + tool calls), the text is internal narration
        // (e.g., "Great job, Brown!") not meant for the user — Smith uses
        // message_user explicitly when it wants to address the user.
        var implicitMessageSent = false
        var smithActionClaimPhrase: String?
        if configuration.role == .smith,
           response.toolCalls.isEmpty,
           let text = response.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            await toolContext.post(ChannelMessage(
                sender: .agent(configuration.role),
                recipientID: OrchestrationRuntime.userID,
                recipient: .user,
                content: text
            ))
            implicitMessageSent = true
            // Capture the matched phrase here, but defer the [System] correction
            // append until AFTER the assistant message lands in history below
            // (otherwise the next LLM turn sees "Your previous message said X"
            // before the assistant text containing X actually appears).
            smithActionClaimPhrase = Self.detectActionClaimWithoutToolCall(text: text)
        }

        let toolCalls = response.toolCalls
        if toolCalls.isEmpty {
            // A long real-time gap since the previous text-only response means this is a fresh
            // idle assessment (10-minute digest, scheduled wake, new inbound message), not a
            // tight loop iteration — reset so periodic idleness can never trip the breaker.
            let textOnlyNow = Date()
            if let last = lastTextOnlyResponseAt,
               textOnlyNow.timeIntervalSince(last) >= Self.textOnlyLoopGapSeconds {
                consecutiveTextOnlyResponses = 0
            }
            lastTextOnlyResponseAt = textOnlyNow
            consecutiveTextOnlyResponses += 1
            // Reset tool repetition tracker — a text-only response breaks any tool call streak.
            lastToolCallSignature = nil
            consecutiveIdenticalToolCalls = 0

            let hasText = response.text.map { !$0.isEmpty } ?? false

            // --- Empty STOP handling (no text AND no tool calls) ---
            // Distinct from text-only: the model produced NOTHING. For Brown, escalate
            // through a three-strike sequence rather than silently going idle.
            if !hasText {
                consecutiveEmptyResponses += 1
                let roleName = configuration.role.displayName

                if configuration.role == .brown {
                    if consecutiveEmptyResponses >= Self.maxConsecutiveEmptyResponses {
                        // Strike 3: terminate
                        await toolContext.post(ChannelMessage(
                            sender: .system,
                            content: "\(roleName) returned \(consecutiveEmptyResponses) consecutive empty responses (no text, no tool calls). The model appears unable to proceed. Terminating.",
                            metadata: ["isError": .bool(true), "agentRole": .string(configuration.role.rawValue)]
                        ))
                        await toolContext.onSelfTerminate()
                        isRunning = false
                        return
                    } else if consecutiveEmptyResponses == 2 {
                        // Strike 2: rebuild context from task state
                        await toolContext.post(ChannelMessage(
                            sender: .system,
                            content: "\(roleName) returned a second consecutive empty response. Attempting context rebuild from task state.",
                            metadata: ["isWarning": .bool(true), "agentRole": .string(configuration.role.rawValue)]
                        ))
                        let rebuilt = await rebuildContextFromTask()
                        if !rebuilt {
                            // No running task to rebuild from — fall back to aggressive
                            // prune and retry. If the model empties again, strike 3 fires.
                            forceAggressivePrune()
                        }
                        // rebuildContextFromTask sets hasUnprocessedInput on success;
                        // forceAggressivePrune does not (it's normally followed by a
                        // `continue` in the context-overflow path). Set it explicitly
                        // so the run loop retries immediately after the prune.
                        hasUnprocessedInput = true
                        return
                    } else {
                        // Strike 1: inject continuation prompt and retry immediately
                        await toolContext.post(ChannelMessage(
                            sender: .system,
                            content: "\(roleName) returned an empty response (no text, no tool calls). Injecting continuation prompt.",
                            metadata: ["isWarning": .bool(true), "agentRole": .string(configuration.role.rawValue)]
                        ))
                        conversationHistory.append(.user("You returned an empty response with no text and no tool calls. This is not acceptable — you must make progress on the task. Use your tools to continue working."))
                        hasUnprocessedInput = true
                        return
                    }
                }

                // Non-Brown agents: fall through to existing text-only handling below,
                // which will go idle (hasUnprocessedInput = false).
            } else {
                // Non-empty response resets the empty counter.
                consecutiveEmptyResponses = 0
            }

            // Text-only response — record and wait for new input.
            // Use `.assistant(from:)` so the response's `continuation`
            // (Anthropic thinking signatures / Gemini thoughtSignatures)
            // survives into the next turn. Manual construction silently
            // broke multi-turn thinking on Anthropic (thinkingBudget > 0)
            // and Gemini 2.5 (thinking on by default in Pro).
            if hasText, response.text != nil {
                conversationHistory.append(.assistant(from: response))
                pushLiveContext()

                if configuration.suppressesRawTextToChannel, !implicitMessageSent {
                    appendDiscardedTextWarning()
                }

                // Action-claim guard for Smith: when his text-only response asserted
                // a completed action but he made no tool call, append a [System]
                // correction AFTER the assistant message so the next LLM turn sees
                // (1) Smith's text, then (2) the system correction referring to it.
                // Observed in session BB94BA9C: user asked "terminate him", Smith
                // replied "Done. Brown has been terminated" without ever calling
                // `terminate_agent`. Brown kept running for two more minutes.
                if let phrase = smithActionClaimPhrase {
                    conversationHistory.append(.user("""
                        [System] Your previous message said "\(phrase)" but you made no tool call. \
                        The action was NOT performed — your text reaches the user as if it were \
                        message_user, but text alone cannot terminate an agent, fail a task, or \
                        message Brown. If you intended to act:
                        - Terminate an agent → call `terminate_agent`
                        - Mark a task failed / archived / completed → call `update_task` (status) or `manage_task_disposition`
                        - Send Brown instructions → call `message_brown`
                        - Schedule something → call `schedule_task_action`
                        Reply now with the correct tool call. Do not just claim it again.
                        """))
                    hasUnprocessedInput = true
                }
            } else if configuration.role != .brown {
                // Empty response from a non-Brown agent (Brown's three-strike path returns
                // earlier). Without an assistant message here, the still-open user turn stays
                // appendable: the next wake/digest/inbound injection merges into it and the
                // provider re-feeds the stale prompt back to the model — exactly how three of
                // four task-scoped wakes silently dropped on 2026-04-25. Append a synthetic
                // marker so each new injection starts a fresh turn.
                conversationHistory.append(.assistant(text: "(no response)"))
                pushLiveContext()
                Self.agentLogger.debug(
                    "Agent \(self.configuration.role.displayName, privacy: .public) returned an empty response; closing turn with synthetic marker."
                )
            }

            // Circuit breaker: if the model keeps returning text without tool calls,
            // it's likely degenerate (repetition loop or unable to use tools). Terminate.
            // Brown (tool-heavy worker) triggers quickly at 6; Smith (conversational orchestrator) at 30.
            let textOnlyLimit = configuration.role == .smith ? 30 : 6
            if consecutiveTextOnlyResponses >= textOnlyLimit {
                await toolContext.post(ChannelMessage(
                    sender: .system,
                    content: "Agent \(configuration.role.displayName) returned \(consecutiveTextOnlyResponses) consecutive text-only responses without calling any tools. Terminating — the model may be in a degenerate loop."
                ))
                await toolContext.onSelfTerminate()
                isRunning = false
                return
            }

            // For orchestrator agents (Smith), a text-only response means "nothing to do" —
            // go idle until new messages arrive. For worker agents (Brown), text with no
            // tool calls means the model is thinking aloud — inject a continuation prompt
            // so it keeps working.
            if configuration.role == .brown && hasText {
                conversationHistory.append(.user("Continue. Use your tools to make progress on the task."))
            } else {
                hasUnprocessedInput = false
            }
            return
        }

        consecutiveTextOnlyResponses = 0
        lastTextOnlyResponseAt = nil
        consecutiveEmptyResponses = 0

        // Cap tool calls before recording to history — every recorded tool call must have
        // a matching tool result, or the LLM API will error on the next request.
        let callsToExecute = Array(toolCalls.prefix(maxToolCallsPerIteration))
        if callsToExecute.count < toolCalls.count {
            await toolContext.post(ChannelMessage(
                sender: .system,
                content: "Rate limit: dropped \(toolCalls.count - callsToExecute.count) tool calls (max \(maxToolCallsPerIteration) per iteration)."
            ))
        }

        // Record the assistant message with only the calls we will execute, so that
        // subsequent tool results have a matching request in history. Build from
        // `response` via `.assistant(from:)` so reasoning AND provider continuation
        // (Anthropic thinking signatures, Gemini thoughtSignatures) flow through.
        //
        // Rate-limit truncation: when the rate-limit prefix differs from the
        // full response.toolCalls list, we rewrite content to the executed
        // subset. We MUST also drop the Gemini portion of the continuation
        // (the `geminiResponseParts`), because the Gemini encoder emits the
        // saved parts verbatim — bypassing message.content — and the parts
        // include the originally-emitted full set of functionCalls. A truncated
        // content with the full parts would mean Gemini sees N functionCall
        // parts on the wire but only M < N matching tool_result entries on
        // the next turn, and silently drops the unmatched results (the
        // original 0.0.22 regression class). Anthropic thinking blocks
        // (which live at the start of the turn, independent of toolCalls)
        // are safe to keep — they don't reference specific calls.
        var assistantTurn = LLMMessage.assistant(from: response)
        if callsToExecute.count < response.toolCalls.count {
            if let text = response.text, !text.isEmpty {
                assistantTurn.content = .mixed(text: text, toolCalls: callsToExecute)
            } else {
                assistantTurn.content = .toolCalls(callsToExecute)
            }
            // Clear Gemini parts (would replay full set verbatim) but keep
            // Anthropic thinking blocks (still valid).
            if let cont = assistantTurn.continuation,
               cont.geminiResponseParts != nil || cont.geminiThoughtSignatures != nil {
                assistantTurn.continuation = ProviderContinuation(
                    anthropicThinkingBlocks: cont.anthropicThinkingBlocks
                )
            }
        }
        conversationHistory.append(assistantTurn)
        // Note: do NOT call appendDiscardedTextWarning() here. Inserting a user message
        // between the assistant tool_use and the tool_result messages breaks the Anthropic
        // API requirement that tool_results immediately follow their tool_use. Mixed text
        // alongside tool calls is intentional narration, not a problem to warn about.

        var sentMessage = false
        var calledTaskComplete = false
        var calledCreateTask = false

        let taskLifecycleTools: Set<String> = [
            "task_acknowledged", "task_update", "task_complete", "request_help", "reply_to_user",
            "message_user", "message_brown"
        ]

        // Segment calls into contiguous runs of lifecycle vs approval-needing.
        // Each segment completes before the next starts, preserving ordering.
        // e.g. [task_acknowledged, file_read x10, task_complete] becomes:
        //   segment 0: lifecycle  [task_acknowledged]     → sequential
        //   segment 1: approval   [file_read x10]         → parallel
        //   segment 2: lifecycle  [task_complete]          → sequential
        struct CallSegment {
            let isLifecycle: Bool
            var calls: [LLMToolCall]
        }

        var segments: [CallSegment] = []
        for call in callsToExecute {
            let isLifecycle = taskLifecycleTools.contains(call.name)
            if let last = segments.last, last.isLifecycle == isLifecycle {
                segments[segments.count - 1].calls.append(call)
            } else {
                segments.append(CallSegment(isLifecycle: isLifecycle, calls: [call]))
            }
        }

        var executedCallIDs = Set<String>()

        for segment in segments {
            guard isRunning else { break }

            if segment.isLifecycle {
                // --- Lifecycle segment: execute sequentially, no approval ---
                for call in segment.calls {
                    guard isRunning else { break }
                    let result: String
                    if let tool = activeTools.first(where: { $0.name == call.name }) {
                        if let rejection = await rejectionResultIfUnavailable(call, tool: tool) {
                            result = rejection
                        } else {
                            result = await directExecute(call, tool: tool)
                        }
                    } else {
                        result = "Unknown tool: \(call.name)"
                        await toolContext.setToolExecutionStatus(call.id, false)
                    }
                    executedCallIDs.insert(call.id)
                    updatePostCallFlags(call: call, result: result, sentMessage: &sentMessage, calledTaskComplete: &calledTaskComplete, calledCreateTask: &calledCreateTask)
                    conversationHistory.append(.toolResult(Self.capToolResult(result), callID: call.id))
                    pushLiveContext()
                }
            } else if segment.calls.count > 1 && configuration.requiresToolApproval,
                      let evaluator = securityEvaluator {
                // --- Approval segment with multiple calls: parallel evaluation + execution ---
                let approvalSummaries = segment.calls.map {
                    Self.conciseToolCallSummary(name: $0.name, arguments: $0.arguments)
                }

                struct ParallelEntry: Sendable {
                    let batchIndex: Int
                    let call: LLMToolCall
                    let tool: any AgentTool
                    let siblings: String
                    let taskTitle: String?
                    let taskID: String?
                    let taskDescription: String?
                }

                let allTasks = await toolContext.taskStore.allTasks()
                let currentTask = allTasks.first { $0.assigneeIDs.contains(toolContext.agentID) && $0.status == .running }
                let parallelCount = segment.calls.count

                var entries: [ParallelEntry] = []
                // Calls rejected before Jones evaluation (unavailable for role / unknown tool).
                // Tracked alongside evaluated results so we can keep tool_result ordering aligned
                // with the assistant message's tool_use ordering.
                var preRejections: [(batchIndex: Int, callID: String, result: String)] = []
                for (batchIndex, call) in segment.calls.enumerated() {
                    guard isRunning else { break }
                    guard let tool = activeTools.first(where: { $0.name == call.name }) else { continue }
                    if let rejection = await rejectionResultIfUnavailable(call, tool: tool) {
                        preRejections.append((batchIndex: batchIndex, callID: call.id, result: rejection))
                        continue
                    }
                    let siblings = approvalSummaries.enumerated()
                        .compactMap { $0.offset != batchIndex ? $0.element : nil }
                        .joined(separator: "\n")
                    entries.append(ParallelEntry(
                        batchIndex: batchIndex, call: call, tool: tool, siblings: siblings,
                        taskTitle: currentTask?.title, taskID: currentTask?.id.uuidString,
                        taskDescription: currentTask?.description
                    ))
                    await postToolRequestToChannel(call, tool: tool, task: currentTask, parallelIndex: batchIndex, parallelCount: parallelCount, siblingCallSummaries: approvalSummaries.enumerated().compactMap { $0.offset != batchIndex ? $0.element : nil })
                }

                struct ParallelToolResult: Sendable {
                    let batchIndex: Int
                    let callID: String
                    let result: String
                    /// Wall-clock ms spent inside `tool.execute(...)`. Zero for denied
                    /// calls (which skip execute entirely). Does NOT include the Jones
                    /// security-evaluation LLM call — that gets its own UsageRecord.
                    let executionMs: Int
                }

                let role = configuration.role
                let roleName = configuration.role.displayName
                let ctx = toolContext
                let agentIDPrefix = String(id.uuidString.prefix(8))

                let jonesActiveCount = OSAllocatedUnfairLock(initialState: 0)
                let jonesCallback = ctx.onJonesProcessingStateChange

                // Evaluate + execute a single entry. Extracted so the sliding
                // window doesn't duplicate the task body.
                let evaluateEntry: @Sendable (ParallelEntry) async -> ParallelToolResult = { entry in
                    let toolDef = entry.tool.definition(for: role)
                    let toolParamDefs = AgentActor.formatToolParameterDefinitions(toolDef.parameters)

                    let shouldSignalStart = jonesActiveCount.withLock { count -> Bool in
                        count += 1
                        return count == 1
                    }
                    if shouldSignalStart { jonesCallback(true) }

                    let disposition = await evaluator.evaluate(
                        toolName: entry.call.name,
                        toolParams: entry.call.arguments,
                        toolDescription: toolDef.description,
                        toolParameterDefs: toolParamDefs,
                        taskTitle: entry.taskTitle,
                        taskID: entry.taskID,
                        taskDescription: entry.taskDescription,
                        siblingCalls: entry.siblings.isEmpty ? nil : entry.siblings,
                        agentRoleName: roleName,
                        toolCallID: entry.call.id
                    )

                    let shouldSignalEnd = jonesActiveCount.withLock { count -> Bool in
                        count -= 1
                        return count == 0
                    }
                    if shouldSignalEnd { jonesCallback(false) }

                    await AgentActor.postSecurityReviewToChannel(
                        disposition: disposition, call: entry.call, role: role, roleName: roleName, context: ctx
                    )

                    let result: String
                    var executionMs = 0
                    if disposition.approved {
                        let outcome = await AgentActor.runToolWithTimeout(entry.call, tool: entry.tool, context: ctx) { name, seconds in
                            AgentActor.stopLogger.warning("Tool '\(name, privacy: .public)' execution exceeded \(seconds, privacy: .public)s — cancelled (agent=\(agentIDPrefix, privacy: .public))")
                        }
                        result = outcome.result
                        executionMs = outcome.executionMs
                        // Mirror the sequential `directExecute` path: record the outcome on the
                        // shared tracker so Jones's recent-tool-calls context shows whether this
                        // approved call actually succeeded or failed. Without this, parallel
                        // batches of approval-needing calls (e.g., file_read fan-out) leave
                        // every entry tagged "[executed: not yet recorded]" and a legitimate
                        // retry-after-failure looks like a duplicate operation. A timeout-induced
                        // cancellation is also recorded as a failure.
                        await ctx.setToolExecutionStatus(entry.call.id, outcome.succeeded)
                        await AgentActor.postToolOutputToChannel(
                            result: result, call: entry.call, role: role, context: ctx
                        )
                    } else {
                        if let taskID = currentTask?.id {
                            let update = AgentActor.securityDenialUpdateMessage(
                                call: entry.call, disposition: disposition, isParallelBatch: true
                            )
                            await ctx.taskStore.addUpdate(id: taskID, message: update)
                        }
                        result = "Tool execution denied: \(disposition.message ?? "No reason given")"
                        // Denial is a domain-level failure outcome from Brown's perspective,
                        // even though no execution actually occurred — mark so retries are
                        // not flagged as duplicates of successful operations.
                        await ctx.setToolExecutionStatus(entry.call.id, false)
                    }

                    return ParallelToolResult(
                        batchIndex: entry.batchIndex, callID: entry.call.id,
                        result: result, executionMs: executionMs
                    )
                }

                // Sliding window: at most maxConcurrentEvaluations Jones calls in flight.
                let results: [ParallelToolResult] = await withTaskGroup(
                    of: ParallelToolResult.self,
                    returning: [ParallelToolResult].self
                ) { group in
                    var collected: [ParallelToolResult] = []
                    var iterator = entries.makeIterator()

                    // Seed with up to maxConcurrentEvaluations tasks.
                    for _ in 0..<min(Self.maxConcurrentEvaluations, entries.count) {
                        guard let entry = iterator.next() else { break }
                        group.addTask { await evaluateEntry(entry) }
                    }

                    // As each completes, add the next entry (if any).
                    for await result in group {
                        collected.append(result)
                        if let entry = iterator.next() {
                            group.addTask { await evaluateEntry(entry) }
                        }
                    }

                    return collected
                }

                struct MergedEntry {
                    let batchIndex: Int
                    let callID: String
                    let result: String
                    let executionMs: Int
                }
                var merged: [MergedEntry] = []
                for r in results {
                    merged.append(MergedEntry(batchIndex: r.batchIndex, callID: r.callID, result: r.result, executionMs: r.executionMs))
                }
                for r in preRejections {
                    merged.append(MergedEntry(batchIndex: r.batchIndex, callID: r.callID, result: r.result, executionMs: 0))
                }
                for r in merged.sorted(by: { $0.batchIndex < $1.batchIndex }) {
                    executedCallIDs.insert(r.callID)
                    turnToolExecutionMs += r.executionMs
                    turnToolResultChars += r.result.count
                    conversationHistory.append(.toolResult(Self.capToolResult(r.result), callID: r.callID))
                }
                pushLiveContext()
            } else {
                // --- Sequential approval path (single call or no evaluator) ---
                let approvalSummaries: [String] = segment.calls.count > 1
                    ? segment.calls.map { Self.conciseToolCallSummary(name: $0.name, arguments: $0.arguments) }
                    : []

                for (batchIndex, call) in segment.calls.enumerated() {
                    guard isRunning else { break }
                    let result: String
                    if let tool = activeTools.first(where: { $0.name == call.name }) {
                        if let rejection = await rejectionResultIfUnavailable(call, tool: tool) {
                            result = rejection
                        } else if configuration.requiresToolApproval {
                            let siblings = segment.calls.count > 1
                                ? approvalSummaries.enumerated().compactMap { $0.offset != batchIndex ? $0.element : nil }
                                : []
                            result = await executeWithApproval(call, tool: tool, parallelIndex: batchIndex, parallelCount: segment.calls.count, siblingCallSummaries: siblings)
                        } else {
                            result = await directExecute(call, tool: tool)
                        }
                    } else {
                        result = "Unknown tool: \(call.name)"
                        await toolContext.setToolExecutionStatus(call.id, false)
                    }
                    executedCallIDs.insert(call.id)
                    updatePostCallFlags(call: call, result: result, sentMessage: &sentMessage, calledTaskComplete: &calledTaskComplete, calledCreateTask: &calledCreateTask)
                    conversationHistory.append(.toolResult(Self.capToolResult(result), callID: call.id))
                    pushLiveContext()
                }
            }
        }

        // Safety: if any segment loop exited early (stop() during await), append placeholder
        // results for remaining tool_calls to maintain the API invariant.
        var appendedPlaceholders = false
        for call in callsToExecute where !executedCallIDs.contains(call.id) {
            conversationHistory.append(.toolResult("Tool execution cancelled (agent stopped)", callID: call.id))
            await toolContext.setToolExecutionStatus(call.id, false)
            appendedPlaceholders = true
        }
        if appendedPlaceholders { pushLiveContext() }

        // --- Repetition circuit breaker ---
        // Track consecutive identical tool calls (same name + same normalized arguments).
        // Any different tool call resets the counter. Text-only responses reset separately.
        if let firstCall = callsToExecute.first {
            let sig = Self.toolCallSignature(name: firstCall.name, arguments: firstCall.arguments)
            if sig == lastToolCallSignature {
                consecutiveIdenticalToolCalls += 1
            } else {
                lastToolCallSignature = sig
                consecutiveIdenticalToolCalls = 1
            }
        } else {
            lastToolCallSignature = nil
            consecutiveIdenticalToolCalls = 0
        }

        if consecutiveIdenticalToolCalls >= Self.maxConsecutiveIdenticalToolCalls {
            await toolContext.post(ChannelMessage(
                sender: .system,
                content: "Agent \(configuration.role.displayName) called \(callsToExecute.first?.name ?? "unknown") with identical arguments \(consecutiveIdenticalToolCalls) times in a row. Breaking loop — agent will idle until new input arrives."
            ))
            consecutiveIdenticalToolCalls = 0
            lastToolCallSignature = nil
            hasUnprocessedInput = false
            return
        }

        // run_task fires a detached restart — stop the run loop so we don't
        // race the restart and accidentally trigger it a second time.
        if calledCreateTask {
            hasUnprocessedInput = false
            return
        }

        // After completing a task (task_complete) OR escalating a blocker (request_help), stop and
        // wait for Smith — `awaitingTaskReview` means "parked, waiting on Smith" for both. Reset
        // when Smith's private reply (review_work feedback / provide_help) reaches Brown.
        // This takes priority over the sentMessage check since both tools also post a message.
        if calledTaskComplete {
            awaitingTaskReview = true
            hasUnprocessedInput = false
            return
        }

        // After sending an explicit message, stop and wait for a reply rather than continuing
        // to act. This prevents agents from looping by sending the same message repeatedly
        // before anyone has had a chance to respond.
        // Note: implicitMessageSent (Smith's raw text treated as message_user) does NOT
        // trigger this — when the LLM emits text alongside tool calls, the text is narration
        // ("let me check...") and the agent must continue to process tool results.
        if sentMessage {
            hasUnprocessedInput = false
            return
        }

        // Tool results have been appended; the LLM needs to see them on the next iteration.
        // hasUnprocessedInput stays true (it was true when we entered handleResponse).
    }

    /// Appends a warning to conversation history when an agent with suppressed text output
    /// returns non-empty text that was discarded. Nudges the LLM to use structured tools instead.
    private func appendDiscardedTextWarning() {
        conversationHistory.append(.user(
            "[System] Your text output was discarded — it is not visible to anyone. " +
            "Use task_update to communicate progress, or task_complete to deliver results."
        ))
    }

    /// Detects the specific failure mode where Smith's text-only response asserts an
    /// action was performed (terminated, paused, marked failed, etc.) but no tool call
    /// accompanies the response. Returns the matched phrase for inclusion in the
    /// `[System]` correction, or `nil` if no claim is detected.
    ///
    /// Intentionally narrow — we'd rather miss some phrasings than spam Smith with
    /// false-positive corrections every time he says "stopped" in another context.
    /// Pairs with the prompt rule (item 37 in `SmithBehavior.swift`'s scoring section);
    /// the runtime detector is the safety net when the model doesn't follow the prompt.
    nonisolated static func detectActionClaimWithoutToolCall(text: String) -> String? {
        // Patterns: an action verb in past tense followed (within ~80 chars) by an
        // agent or task target. Matches things like "Brown has been terminated",
        // "I've terminated Brown", "task is now marked failed", "Brown stopped",
        // "I paused him". Case-insensitive.
        let patterns: [String] = [
            // Verb-then-target ("I've paused him", "terminated Brown", "stopped the agent")
            #"(?i)\b(terminated|killed|paused|stopped|cancelled)\b[^.]{0,80}\b(brown|agent|him|her|them)\b"#,
            // Target-then-verb ("Brown has been terminated", "him paused")
            #"(?i)\b(brown|agent|him|her|them)\b[^.]{0,80}\b(terminated|killed|stopped|paused|cancelled)\b"#,
            // Task disposition phrasings ("marked the task failed", "set it failed")
            #"(?i)\b(marked|set|moved)\b[^.]{0,40}\b(task|it)\b[^.]{0,40}\b(failed|completed|cancelled|archived)\b"#,
            // Passive task-marked phrasings ("task is now marked failed")
            #"(?i)\b(task)\b[^.]{0,40}\bis\s+(?:now\s+)?marked\s+(?:as\s+)?(failed|completed|cancelled|archived)\b"#,
            // "Done." / "Done!" preamble plus an action verb in the same sentence
            #"(?i)\bdone\b[^.]{0,80}\b(terminated|killed|stopped|paused|marked|cancelled|archived)\b"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = regex.firstMatch(in: text, options: [], range: range),
               let r = Range(match.range, in: text) {
                let phrase = String(text[r])
                return phrase.count > 100 ? String(phrase.prefix(100)) + "…" : phrase
            }
        }
        return nil
    }

    /// Evaluates a tool call via SecurityEvaluator, posts channel messages, executes if approved.
    /// Used for sequential tool calls that require approval.
    private func executeWithApproval(_ call: LLMToolCall, tool: any AgentTool, parallelIndex: Int = 0, parallelCount: Int = 1, siblingCallSummaries: [String] = []) async -> String {
        let toolDef = tool.definition(for: configuration.role)
        let toolParameterDefs = Self.formatToolParameterDefinitions(toolDef.parameters)

        // Look up the current running task for context.
        let allTasks = await toolContext.taskStore.allTasks()
        let currentTask = allTasks.first { $0.assigneeIDs.contains(toolContext.agentID) && $0.status == .running }

        // Post tool_request to channel for UI visibility.
        await postToolRequestToChannel(call, tool: tool, task: currentTask, parallelIndex: parallelIndex, parallelCount: parallelCount, siblingCallSummaries: siblingCallSummaries)

        guard let evaluator = securityEvaluator else {
            assertionFailure("Brown requires tool approval but no SecurityEvaluator is configured")
            Self.agentLogger.error("Tool '\(call.name, privacy: .public)' denied — no SecurityEvaluator configured. This is a configuration bug.")
            return "Tool execution denied: No security evaluator is configured. Tool cannot be executed without approval."
        }

        let siblings = siblingCallSummaries.isEmpty ? nil : siblingCallSummaries.joined(separator: "\n")
        toolContext.onJonesProcessingStateChange(true)
        let disposition = await evaluator.evaluate(
            toolName: call.name,
            toolParams: call.arguments,
            toolDescription: toolDef.description,
            toolParameterDefs: toolParameterDefs,
            taskTitle: currentTask?.title,
            taskID: currentTask?.id.uuidString,
            taskDescription: currentTask?.description,
            siblingCalls: siblings,
            agentRoleName: configuration.role.displayName,
            toolCallID: call.id
        )
        toolContext.onJonesProcessingStateChange(false)

        // Post approval/denial status.
        await Self.postSecurityReviewToChannel(
            disposition: disposition, call: call, role: configuration.role,
            roleName: configuration.role.displayName, context: toolContext
        )

        if disposition.approved {
            let result = await directExecute(call, tool: tool)
            await Self.postToolOutputToChannel(
                result: result, call: call, role: configuration.role, context: toolContext
            )
            return result
        } else {
            if let task = currentTask {
                let update = Self.securityDenialUpdateMessage(
                    call: call, disposition: disposition, isParallelBatch: parallelCount > 1
                )
                await toolContext.taskStore.addUpdate(id: task.id, message: update)
            }
            // Mirror the parallel-approval path: record the denial as a failed outcome so
            // a retry of the same call is recognized as a legitimate response, not a
            // duplicate operation.
            await toolContext.setToolExecutionStatus(call.id, false)
            return "Tool execution denied: \(disposition.message ?? "No reason given")"
        }
    }

    private func directExecute(_ call: LLMToolCall, tool: any AgentTool) async -> String {
        let agentIDPrefix = String(id.uuidString.prefix(8))
        let outcome = await Self.runToolWithTimeout(call, tool: tool, context: toolContext) { name, seconds in
            Self.stopLogger.warning("Tool '\(name, privacy: .public)' execution exceeded \(seconds, privacy: .public)s — cancelled (agent=\(agentIDPrefix, privacy: .public))")
        }
        turnToolExecutionMs += outcome.executionMs
        turnToolResultChars += outcome.result.count
        await toolContext.setToolExecutionStatus(call.id, outcome.succeeded)
        return outcome.result
    }

    /// Rebuilds the per-turn `ToolAvailabilityContext` using current actor state.
    /// Availability can flip mid-turn (e.g. `hasAwaitingReviewTasks` changes after
    /// `task_complete` runs), so the dispatch-time check uses freshly read task state
    /// rather than the context captured at filter time.
    private func currentAvailabilityContext() async -> ToolAvailabilityContext {
        let activeTasks = await toolContext.taskStore.allTasks().filter { $0.disposition == .active }
        return ToolAvailabilityContext(
            lastDirectUserMessageAt: lastDirectUserMessageAt,
            agentRole: configuration.role,
            hasRunnableTasks: activeTasks.contains { $0.status.isRunnable },
            hasAwaitingReviewTasks: activeTasks.contains { $0.status == .awaitingReview }
        )
    }

    /// Returns a rejection result string if `tool` is not currently available, or `nil`
    /// to indicate the dispatch may proceed. Defense-in-depth against an LLM hallucinating
    /// a call to a tool that was excluded from this turn's tool definitions. Records the
    /// rejected call as a failure on the shared tracker so a retry isn't flagged as a
    /// duplicate of a successful operation.
    private func rejectionResultIfUnavailable(_ call: LLMToolCall, tool: any AgentTool) async -> String? {
        // Mirror the awaitingTaskReview override at the toolDefinitions filter site:
        // while Brown is awaiting review, no tool may execute, regardless of per-tool
        // `isAvailable`. Without this branch, a stale tool call enqueued before the
        // state flipped — or a future code path that hands Brown a tool list anyway —
        // could still reach `directExecute`.
        if configuration.role == .brown && awaitingTaskReview {
            Self.agentLogger.warning("Tool '\(call.name, privacy: .public)' rejected at execution time — Brown is awaitingTaskReview")
            await toolContext.setToolExecutionStatus(call.id, false)
            return "Tool '\(call.name)' is not available — task is awaiting review."
        }
        let context = await currentAvailabilityContext()
        if tool.isAvailable(in: context) { return nil }
        Self.agentLogger.warning("Tool '\(call.name, privacy: .public)' rejected at execution time — not available for role \(self.configuration.role.rawValue, privacy: .public)")
        await toolContext.setToolExecutionStatus(call.id, false)
        return "Tool '\(call.name)' is not currently available."
    }

    /// Wraps `tool.execute(...)` in a wall-clock timeout sourced from `tool.executionTimeout`.
    /// Returns the produced output text, the domain success flag, and the elapsed milliseconds.
    /// On timeout the tool's task is cancelled and a synthesized "Tool execution exceeded N s —
    /// cancelled" message is returned with `succeeded == false`.
    ///
    /// Cancellation is cooperative, and this is a *structured* task group: when the body returns
    /// after the timeout, the group implicitly awaits the cancelled tool task before this function
    /// returns. So a tool that never checks `Task.isCancelled` (or never hits an `await` on a
    /// cancellation-aware primitive) would still delay this call until it finishes on its own.
    /// Every in-tree tool avoids that: `BashTool`/`GhTool` go through `ProcessRunner` (which honors
    /// cancellation), and the in-process walkers (`glob`, `directory_tree`, `directory_listing`)
    /// check `Task.isCancelled` / `Task.checkCancellation()` in their loops. New long-running tools
    /// must do the same.
    ///
    /// `setToolExecutionStatus` is intentionally NOT called here — the parallel batch and
    /// directExecute paths each handle the tracker update at their own seam.
    /// `onToolExecutionStateChange(toolName, true/false)` IS handled here.
    ///
    /// `static` + parameterized so tests can exercise the timeout behavior without spinning
    /// up a full `AgentActor`.
    static func runToolWithTimeout(
        _ call: LLMToolCall,
        tool: any AgentTool,
        context: ToolContext,
        onTimeout: @Sendable (_ toolName: String, _ timeoutSeconds: Int) -> Void = { _, _ in }
    ) async -> (result: String, succeeded: Bool, executionMs: Int) {
        let timeout = tool.executionTimeout
        let timeoutSeconds = Int(timeout.components.seconds)
        let toolName = tool.name
        let start = Date()

        context.onToolExecutionStateChange(toolName, true)
        defer { context.onToolExecutionStateChange(toolName, false) }

        let outcome: ToolExecutionResult?
        do {
            outcome = try await withThrowingTaskGroup(of: ToolExecutionResult?.self) { group in
                group.addTask {
                    let args = try call.parsedArguments()
                    return try await tool.execute(arguments: args, context: context)
                }
                group.addTask {
                    // `try?` swallows the CancellationError thrown when the racing tool
                    // task wins; we never want the sleep itself to surface as a tool
                    // error. Returning `nil` is the timeout sentinel.
                    try? await Task.sleep(for: timeout)
                    return nil
                }
                let first = (try await group.next()) ?? nil
                group.cancelAll()
                return first
            }
        } catch {
            let executionMs = Int(Date().timeIntervalSince(start) * 1000)
            return ("Tool error: \(error.localizedDescription)", false, executionMs)
        }

        let executionMs = Int(Date().timeIntervalSince(start) * 1000)
        if let outcome {
            return (outcome.output, outcome.succeeded, executionMs)
        }
        onTimeout(toolName, timeoutSeconds)
        return (
            "Tool execution exceeded \(timeoutSeconds)s — cancelled. The tool ran past its wall-clock budget; nothing was returned. Adjust arguments to bound the work (e.g. narrower scope) and retry, or skip and proceed.",
            false,
            executionMs
        )
    }

    // MARK: - Channel posting helpers

    /// Posts a tool_request message to the channel for UI visibility.
    private func postToolRequestToChannel(_ call: LLMToolCall, tool: any AgentTool, task: AgentTask?, parallelIndex: Int, parallelCount: Int, siblingCallSummaries: [String]) async {
        let toolDef = tool.definition(for: configuration.role)
        let toolParameterDefs = Self.formatToolParameterDefinitions(toolDef.parameters)

        var metadata: [String: AnyCodable] = [
            "messageKind": .string("tool_request"),
            "requestID": .string(call.id),
            "agentID": .string(toolContext.agentID.uuidString),
            "tool": .string(call.name),
            "params": .string(call.arguments),
            "toolDescription": .string(toolDef.description),
            "toolParameters": .string(toolParameterDefs)
        ]
        if let task {
            metadata["taskTitle"] = .string(task.title)
            metadata["taskID"] = .string(task.id.uuidString)
            metadata["taskDescription"] = .string(task.description)
        }
        if parallelCount > 1 {
            metadata["parallelIndex"] = .int(parallelIndex)
            metadata["parallelCount"] = .int(parallelCount)
            if !siblingCallSummaries.isEmpty {
                metadata["siblingCalls"] = .string(siblingCallSummaries.joined(separator: "\n"))
            }
        }
        if call.name == "file_write", let args = Self.parseToolParams(call.arguments) {
            if case .string(let path) = args["path"] {
                metadata["fileWritePath"] = .string(path)
            }
            // Precompute the diff at post time and store ONLY the diff lines.
            // Storing the raw pre-edit file content here (as we used to) bloated
            // channel_log.json without bound: a single multi-MB file_write would
            // copy the full file into metadata, persisted forever. The diff is
            // proportional to the *change*, not the file size — a 1-line edit to
            // a 10,000-line file is only a few lines of output.
            //
            // We still have to read the old file off disk to compute the diff,
            // but the raw content is dropped immediately afterward.
            if case .string(let path) = args["path"],
               case .string(let newContent) = args["content"] {
                // File I/O + LCS diff computation run off the actor's executor to
                // avoid blocking the agent's serial queue on disk reads (up to 1 MB)
                // and O(m*n) diff generation.
                let diffJSON: String? = await Task.detached {
                    guard let oldContent = Self.readOldContentForDiff(path: path) else { return nil }
                    let diffLines = DiffGenerator.generate(old: oldContent, new: newContent)
                    guard !diffLines.isEmpty else { return nil }
                    // try? justified: [DiffLine] is trivially Codable (enum + String + Int);
                    // encoding cannot fail in practice. If it somehow does, omitting the
                    // diff metadata is the correct degradation (the tool output still renders).
                    guard let data = try? JSONEncoder().encode(diffLines) else { return nil }
                    return String(data: data, encoding: .utf8)
                }.value
                if let diffJSON {
                    metadata["fileWriteDiff"] = .string(diffJSON)
                }
            }
        }

        await toolContext.post(ChannelMessage(
            sender: .agent(configuration.role),
            content: Self.conciseToolCallSummary(name: call.name, arguments: call.arguments),
            metadata: metadata
        ))
    }

    /// Posts a security review status message to the channel. Static so it can be called from `withTaskGroup`.
    static func postSecurityReviewToChannel(disposition: SecurityDisposition, call: LLMToolCall, role: AgentRole, roleName: String, context: ToolContext) async {
        let statusContent: String
        let securityDisposition: String
        if disposition.approved && disposition.isAutoApproval {
            statusContent = "Auto-approved (WARN retry)"
            securityDisposition = "autoApproved"
        } else if disposition.approved {
            statusContent = "Jones → \(roleName): SAFE\(disposition.message.map { " \($0)" } ?? "")"
            securityDisposition = "approved"
        } else if disposition.isWarning {
            let warnSummary = disposition.message?.components(separatedBy: "\n").first ?? ""
            statusContent = "Jones → \(roleName): WARN: \(warnSummary)"
            securityDisposition = "warning"
        } else {
            statusContent = "Jones → \(roleName): UNSAFE: \(disposition.message ?? "no reason given")"
            securityDisposition = "denied"
        }
        var reviewMetadata: [String: AnyCodable] = [
            "requestID": .string(call.id),
            "securityDisposition": .string(securityDisposition),
            "agentRole": .string(role.rawValue)
        ]
        if let msg = disposition.message, !msg.isEmpty {
            reviewMetadata["dispositionMessage"] = .string(msg)
        }
        await context.post(ChannelMessage(
            sender: .system,
            content: statusContent,
            metadata: reviewMetadata
        ))
    }

    /// Posts tool output to the channel. Static so it can be called from `withTaskGroup`.
    ///
    /// The channel message stores only the display-truncated version of the output to avoid
    /// bloating the SwiftUI view layer with megabytes of data (e.g., binary blobs from osascript).
    static func postToolOutputToChannel(result: String, call: LLMToolCall, role: AgentRole, context: ToolContext) async {
        let trimmedResult = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedResult.isEmpty else { return }
        let truncated = AgentActor.truncateOutput(trimmedResult, maxLines: 4)
        let isTruncated = truncated != trimmedResult
        var outputMetadata: [String: AnyCodable] = [
            "requestID": .string(call.id),
            "messageKind": .string("tool_output"),
            "tool": .string(call.name)
        ]
        if isTruncated {
            outputMetadata["truncatedContent"] = .string(truncated)
            // Store a larger excerpt for "Show more" — cap at 10K to avoid bloating the UI.
            let expandedLimit = 10_000
            if trimmedResult.count > expandedLimit {
                let remaining = trimmedResult.count - expandedLimit
                outputMetadata["expandedContent"] = .string(
                    String(trimmedResult.prefix(expandedLimit)) + "\n… (\(remaining) more characters, see conversation history)"
                )
            } else {
                outputMetadata["expandedContent"] = .string(trimmedResult)
            }
        }
        await context.post(ChannelMessage(
            sender: .agent(role),
            content: isTruncated ? truncated : trimmedResult,
            metadata: outputMetadata
        ))
    }

    /// Tool result strings used for post-call control flow. Keep in sync with tool return values.
    private func updatePostCallFlags(call: LLMToolCall, result: String, sentMessage: inout Bool, calledTaskComplete: inout Bool, calledCreateTask: inout Bool) {
        if call.name == "message_user" && result == "Message sent to user." { sentMessage = true }
        if call.name == "review_work" && (result.contains("accepted and marked COMPLETE") || result.hasPrefix("Changes requested")) { sentMessage = true }
        if call.name == "message_brown" && result == "Message sent to Brown." { sentMessage = true }
        if call.name == "reply_to_user" && result == "Reply sent to user." { sentMessage = true }
        if call.name == "task_complete" && result.hasPrefix("Task submitted for review:") { calledTaskComplete = true }
        // request_help parks Brown identically to task_complete — it hands off to Smith and must
        // wait. Reuses the same control flag so the run loop sets `awaitingTaskReview` and idles.
        if call.name == "request_help" && result.hasPrefix("Help requested for task:") { calledTaskComplete = true }
        if call.name == "run_task" && result.contains("System is restarting") { calledCreateTask = true }
        if call.name == "create_task" && result.contains("System is restarting") { calledCreateTask = true }

        if configuration.role == .brown {
            let isSuccessfulTaskCommunication: Bool
            switch call.name {
            case "task_acknowledged":
                isSuccessfulTaskCommunication = result.hasPrefix("Task acknowledged:") || result.hasPrefix("Task continuing:")
                if isSuccessfulTaskCommunication { taskAcknowledged = true }
            case "task_update":
                isSuccessfulTaskCommunication = result == "Update sent to Agent Smith."
            case "task_complete":
                isSuccessfulTaskCommunication = result.hasPrefix("Task submitted for review:")
            default:
                isSuccessfulTaskCommunication = false
            }
            if isSuccessfulTaskCommunication {
                lastTaskCommunicationAt = Date()
                toolCallsSinceTaskCommunication = 0
                brownSilenceNudgeArmed = true
            } else {
                toolCallsSinceTaskCommunication += 1
            }
        }
    }

    /// Brown-only: if it's been too long since Brown's last task communication, inject a
    /// system-style user message instructing him to call task_update. Fires at most once per
    /// silence period (re-armed when Brown actually communicates).
    private func checkBrownSilenceNudge() {
        guard configuration.role == .brown, brownSilenceNudgeArmed else { return }
        // Don't nudge while Brown is awaiting review. The whole point of that state is
        // that Brown should be idle until Smith responds; the nudge would otherwise
        // bypass the `drainPendingMessages` awaiting-review gate by setting
        // `hasUnprocessedInput = true` directly, waking Brown to resume work he's
        // already submitted for review (observed in session BB94BA9C — Brown's
        // 15-minute hard-ceiling nudge fired at 19:08 and he started running
        // xcodebuild + file reads despite already being in awaitingTaskReview).
        guard !awaitingTaskReview else { return }
        guard let last = lastTaskCommunicationAt else { return }
        let elapsed = Date().timeIntervalSince(last)
        let drifting = elapsed >= Self.brownSilenceNudgeMinSeconds
            && toolCallsSinceTaskCommunication >= Self.brownSilenceNudgeMinToolCalls
        let hardCeiling = elapsed >= Self.brownSilenceNudgeHardCeilingSeconds
        guard drifting || hardCeiling else { return }

        let minutes = Int(elapsed / 60)
        conversationHistory.append(.user("""
            [System] You have made \(toolCallsSinceTaskCommunication) tool calls and gone \(minutes) minute(s) without sending a task_update.

            Smith and the user are blind to your progress until you do. Your next action MUST be a task_update tool call with a 1–2 sentence summary of:
            1. What you have established or completed since your last update.
            2. What you are about to try next.

            After sending the update, continue your work normally.
            """))
        brownSilenceNudgeArmed = false
        hasUnprocessedInput = true
        pushLiveContext()
    }

    // MARK: - Wake / sleep helpers

    /// Cancels the current idle sleep, causing the run loop to re-evaluate immediately.
    private func interruptIdleSleep() {
        idleSleepTask?.cancel()
    }

    /// Sleeps for up to `maxDuration` seconds, or until interrupted by a new message
    /// or the earliest scheduled wake (whichever comes first).
    private func idleWait(maxDuration: TimeInterval? = nil) async {
        var duration = maxDuration ?? pollInterval
        // Skip the wake-clamp during task review: elapsed wakes are held in the queue,
        // so a wake whose `wakeAt` is in the past would otherwise tight-loop us at 0.1s
        // intervals doing no useful work.
        if let earliest = scheduledWakes.first, !awaitingTaskReview {
            let untilWake = max(0, earliest.wakeAt.timeIntervalSinceNow)
            duration = min(duration, untilWake)
        }
        if configuration.role == .smith, smithDigestProvider != nil, let last = lastSmithDigestAt {
            let untilDigest = max(0, Self.smithDigestIntervalSeconds - Date().timeIntervalSince(last))
            duration = min(duration, untilDigest)
        }
        duration = max(0.1, duration)

        let task = Task<Void, Never> {
            do { try await Task.sleep(for: .seconds(duration)) } catch { }
        }
        idleSleepTask = task
        // withTaskCancellationHandler ensures that if the run loop task itself is
        // cancelled (e.g., via stop()), we immediately cancel the inner sleep rather
        // than waiting for the full duration.
        await withTaskCancellationHandler(
            operation: { await task.value },
            onCancel: { task.cancel() }
        )
        idleSleepTask = nil
    }

    /// Returns how many seconds remain in the post-message debounce window, or 0 if settled.
    private func debounceTimeRemaining() -> TimeInterval {
        guard let last = lastChannelMessageAt else { return 0 }
        return max(0, messageDebounceInterval - Date().timeIntervalSince(last))
    }

    /// Fires every scheduled wake whose deadline has arrived.
    ///
    /// Wakes are partitioned into two groups:
    ///   - **auto-run wakes** (the wake's imperative was rendered by `TaskActionKind.run`
    ///     and it carries a `taskID`): the runtime executes `restartForNewTask` directly
    ///     via `onAutoRunTask`. Smith never sees the imperative — it learns about the new
    ///     run when its fresh process boots with `resumingTaskID` set. This is by design:
    ///     scheduling a task to run at time T is fully mechanical, so no LLM judgment is
    ///     needed and weak local models (gemma3:27b et al.) can't fail to execute by
    ///     asking for confirmation.
    ///   - **smith-driven wakes** (everything else — pause, stop, summarize, plus any
    ///     auto-run wake that fires alongside another auto-run in the same batch
    ///     since `restartForNewTask` is single-target): injected as a combined `[System: ...]`
    ///     user-role marker so Smith can address them in order.
    ///
    /// During `awaitingTaskReview`, elapsed wakes are held in the queue rather than dropped.
    /// They fire on the next loop iteration after review completes.
    func checkScheduledWake() async {
        let now = Date()
        let due = scheduledWakes.filter { $0.wakeAt <= now }
        guard !due.isEmpty else { return }
        guard !awaitingTaskReview else {
            // Hold elapsed wakes through review — they fire on the next loop iteration
            // after `drainPendingMessages` flips `awaitingTaskReview` back to false.
            return
        }
        scheduledWakes.removeAll { $0.wakeAt <= now }

        // Promote any `.scheduled` task referenced by a fired wake to `.pending` so the
        // imperative ("Call run_task on <id>…") will be accepted — `run_task` rejects
        // `.scheduled` status by design (see `AgentTask.Status.isRunnable`). Without this,
        // the task stays in `.scheduled` after fire time and Smith reads `list_tasks`
        // status as "still scheduled," concludes the timer hasn't fired, and waits forever.
        var promotedTaskIDs: Set<UUID> = []
        for wake in due {
            guard let taskID = wake.taskID, !promotedTaskIDs.contains(taskID) else { continue }
            promotedTaskIDs.insert(taskID)
            await toolContext.taskStore.promoteScheduledToPending(id: taskID)
        }

        // Partition wakes. If exactly one auto-run wake fires in this batch, drive it
        // through the runtime directly. If multiple auto-runs fire concurrently, fall
        // back to Smith-driven for ALL of them — `restartForNewTask` is single-target
        // and serializing them would clobber each other (last-one-wins).
        let autoRunCandidates = due.filter(Self.wakeIsAutoRunRunTask)
        let runDirectly: [ScheduledWake]
        let smithWakes: [ScheduledWake]
        if autoRunCandidates.count == 1, let only = autoRunCandidates.first, onAutoRunTask != nil {
            runDirectly = [only]
            smithWakes = due.filter { $0.id != only.id }
        } else {
            runDirectly = []
            smithWakes = due
        }

        for wake in runDirectly {
            if let taskID = wake.taskID {
                await onAutoRunTask?(taskID)
            }
        }

        // Inject the system message ONLY for wakes Smith still has to interpret. If
        // every fired wake was auto-run, we skip the LLM round-trip entirely.
        if !smithWakes.isEmpty {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            let lines = smithWakes.map { wake -> String in
                let timeStr = formatter.string(from: wake.wakeAt)
                let taskFragment = wake.taskID.map { " (linked task: \($0.uuidString))" } ?? ""
                return "  • [\(timeStr)] \(wake.instructions)\(taskFragment)"
            }
            let header = smithWakes.count == 1
                ? "[System: A timer has fired. You must immediately perform the following actions.]"
                : "[System: \(smithWakes.count) timers have fired. You must immediately perform the following actions.]"
            conversationHistory.append(.user("""
                \(header)

                You must:
                \(lines.joined(separator: "\n"))

                Execute each instruction in order. If a step has already been done or is no longer appropriate (the user changed plans, the task was already started, etc.), skip that step and move on to the next. Do NOT schedule a new timer unless the user explicitly asked you to follow up again.
                """))
            hasUnprocessedInput = true
            pushLiveContext()
        }

        // Log to the timer-event history regardless of dispatch path so the View → Timers
        // pane shows every fire, including the auto-run ones.
        if let primary = due.first {
            onWakeFired?(primary, due)
        }

        // Re-schedule any recurring wakes for their next occurrence. The new wake inherits the
        // chain's `originalID` so the timers UI can group fires across the series.
        for wake in due {
            guard let recurrence = wake.recurrence,
                  let next = recurrence.nextOccurrence(after: wake.wakeAt) else { continue }
            let nextWake = ScheduledWake(
                wakeAt: next,
                instructions: wake.instructions,
                taskID: wake.taskID,
                recurrence: recurrence,
                originalID: wake.originalID,
                previousFireAt: wake.wakeAt,
                survivesTaskTermination: wake.survivesTaskTermination
            )
            scheduledWakes.append(nextWake)
            onWakeScheduled?(nextWake)
        }
        scheduledWakes.sort { $0.wakeAt < $1.wakeAt }
    }

    /// Smith-only: if the digest interval has elapsed, ask the runtime-supplied provider for a
    /// brief Brown-activity summary since the last digest, append it as a `[System: ...]` user
    /// message, and reset the digest clock. Skipped silently if no provider is set or if the
    /// provider returns nil (no fresh activity to report).
    private func checkSmithDigest() async {
        guard configuration.role == .smith, let provider = smithDigestProvider else { return }
        let now = Date()
        let last = lastSmithDigestAt ?? now
        // First call after start: just record `now` and wait a full interval.
        if lastSmithDigestAt == nil {
            lastSmithDigestAt = now
            return
        }
        guard now.timeIntervalSince(last) >= Self.smithDigestIntervalSeconds else { return }
        guard !awaitingTaskReview else {
            // Skip during review — Smith is actively reading Brown's deliverable.
            lastSmithDigestAt = now
            return
        }
        lastSmithDigestAt = now
        guard let digest = await provider(last), !digest.isEmpty else { return }
        conversationHistory.append(.user("""
            [System: Brown activity digest — past \(Int(Self.smithDigestIntervalSeconds / 60)) minute(s)]

            \(digest)

            This is an automatic summary so you can supervise without waking on every Brown action. Act only if something looks wrong (Brown stuck, off-track, repeating failures). If everything looks fine, do nothing.
            """))
        hasUnprocessedInput = true
        pushLiveContext()
    }

    /// Notifies the UI layer that the conversation history has changed.
    private func pushLiveContext() {
        onContextChanged?(conversationHistory)
    }

    /// Caps the turn record count and strips contextSnapshot from older turns.
    private func pruneOldTurnSnapshots() {
        // Drop oldest records when exceeding the hard cap.
        if llmTurns.count > Self.maxTurnRecords {
            llmTurns.removeFirst(llmTurns.count - Self.maxTurnRecords)
        }
        // Strip heavy snapshots from turns outside the recent window.
        let stripCount = llmTurns.count - Self.recentSnapshotWindow
        guard stripCount > 0 else { return }
        for i in 0..<stripCount where !llmTurns[i].contextSnapshot.isEmpty {
            llmTurns[i].stripContextSnapshot()
        }
    }

    // MARK: - Auto-memory context (Smith)

    /// Marker embedded in Smith's user messages when auto-memory context has been attached.
    /// Used to detect existing context in the current conversation history (post-pruning) so
    /// we don't re-attach the same kind of background to consecutive user messages.
    private static let autoMemoryContextMarker = "[AUTO_MEMORY_CONTEXT]"

    private static let autoMemoryContextDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    /// Smith-only: searches semantic memory and prior tasks for the latest pending user message
    /// and appends the results to that message before it enters Smith's LLM context.
    ///
    /// Skipped if there are no user messages in the pending queue, the latest user query is empty,
    /// the conversation already contains the marker (background still in scope), or the search
    /// returns nothing.
    private func injectAutoMemoryContextIfNeeded() async {
        // Find the most recent user-originated pending message — that's the one we react to.
        // If multiple user messages arrived in a burst, we attach context only to the latest
        // one (most recent intent) and rely on the marker to suppress further injections.
        guard let userMessage = pendingChannelMessages.last(where: { msg in
            if case .user = msg.sender { return true }
            return false
        }) else { return }

        let query = userMessage.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        // Skip if a prior auto-context is still present in the conversation history (post-pruning).
        if conversationHasAutoMemoryContext() { return }

        // Capture the target message ID before the await — we re-locate by ID afterward
        // because the actor may process other isolated methods during the suspend, and a
        // raw index could become stale if `pendingChannelMessages` is mutated.
        let targetMessageID = userMessage.id

        // Memory search failure is non-fatal — Smith just doesn't get the auto-context this time.
        let results: SemanticSearchResults
        do {
            results = try await toolContext.memoryStore.searchAll(
                query: query,
                memoryLimit: 3,
                taskLimit: 3
            )
        } catch {
            return
        }

        guard !results.isEmpty else { return }

        // Re-check the marker — another path on this actor may have added a marker-bearing
        // user message into the conversation while we were awaiting the search.
        if conversationHasAutoMemoryContext() { return }

        // Re-locate the target message by ID. If it's no longer in the pending queue
        // (e.g. drained by an interleaved code path), skip silently.
        guard let currentIdx = pendingChannelMessages.firstIndex(where: { $0.id == targetMessageID }) else {
            return
        }

        let block = formatAutoMemoryContextBlock(results: results)

        // Mutate the agent's local copy of the pending message so the appended block ends up
        // in the formatted text passed to the LLM. The original ChannelMessage in the channel
        // log (and thus the UI transcript) is unaffected — only Smith's LLM view changes.
        var mutated = pendingChannelMessages[currentIdx]
        mutated.content = mutated.content + "\n\n" + block
        pendingChannelMessages[currentIdx] = mutated

        // Post a memory_searched banner so the auto-search appears in the UI transcript like
        // a manually-invoked one. memory_searched is filtered out in `receiveChannelMessage`,
        // so this banner won't loop back into Smith's pending queue. Result entries are
        // formatted with the same `\u{1E}` separator used by `SearchMemoryTool` so the UI
        // renders them with the standard expandable layout.
        let memoryEntries = results.memories.map { result -> String in
            let pct = String(format: "%.0f%%", result.similarity * 100)
            let tagText = result.memory.tags.isEmpty ? "" : " [tags: \(result.memory.tags.joined(separator: ", "))]"
            return "\(pct) — \(result.memory.content)\(tagText)"
        }
        let taskEntries = results.taskSummaries.map { result -> String in
            let pct = String(format: "%.0f%%", result.similarity * 100)
            return "\(pct) — \(result.summary.title) (id: \(result.summary.id.uuidString))\n\(result.summary.summary)"
        }
        var bannerMetadata: [String: AnyCodable] = [
            "messageKind": .string("memory_searched"),
            "searchQuery": .string(query),
            "memoryCount": .int(results.memories.count),
            "taskCount": .int(results.taskSummaries.count),
            // Marks this as Smith's AUTOMATIC search-on-the-user's-message (vs an explicit
            // `search_memory` call). The query equals the user message shown directly above, so
            // the UI suppresses the redundant query preview for these.
            "autoSearch": .bool(true)
        ]
        if !memoryEntries.isEmpty {
            bannerMetadata["memoryResults"] = .string(memoryEntries.joined(separator: "\u{1E}"))
        }
        if !taskEntries.isEmpty {
            bannerMetadata["taskResults"] = .string(taskEntries.joined(separator: "\u{1E}"))
        }
        await toolContext.post(ChannelMessage(
            sender: .system,
            content: query,
            metadata: bannerMetadata
        ))
    }

    /// Returns true if any user message in the current conversation history contains the
    /// auto-memory marker, indicating context was already attached and is still in scope.
    private func conversationHasAutoMemoryContext() -> Bool {
        for msg in conversationHistory where msg.role == .user {
            if case .text(let text) = msg.content,
               text.contains(Self.autoMemoryContextMarker) {
                return true
            }
        }
        return false
    }

    /// Formats the auto-attached memory + prior tasks block. Layout mirrors `SearchMemoryTool`'s
    /// output so Smith sees a familiar shape, with an explicit framing note that the user did
    /// not author this section.
    private func formatAutoMemoryContextBlock(results: SemanticSearchResults) -> String {
        var lines: [String] = []
        lines.append(Self.autoMemoryContextMarker)
        lines.append("*System note: relevant memories and prior tasks were auto-attached based on the user's message above. Consider this background before creating a task or answering. The user did not write any of the text inside this block.*")

        if !results.memories.isEmpty {
            lines.append("")
            lines.append("## Relevant Memories")
            for (index, result) in results.memories.enumerated() {
                let tagText = result.memory.tags.isEmpty ? "" : " [tags: \(result.memory.tags.joined(separator: ", "))]"
                lines.append("\(index + 1). (similarity: \(String(format: "%.2f", result.similarity))) \(result.memory.content)\(tagText)")
            }
        }

        if !results.taskSummaries.isEmpty {
            lines.append("")
            lines.append("## Relevant Prior Tasks")
            lines.append("*These are summaries only — use `get_task_details` with the `task_ids` parameter (max 10) to fetch full details if a prior task seems directly relevant.*")
            for (index, result) in results.taskSummaries.enumerated() {
                let dateStr = Self.autoMemoryContextDateFormatter.string(from: result.summary.createdAt)
                lines.append("\(index + 1). (similarity: \(String(format: "%.2f", result.similarity)), status: \(result.summary.status.rawValue), date: \(dateStr), task_id: \(result.summary.id.uuidString)) **\(result.summary.title)**: \(result.summary.summary)")
            }
        }

        lines.append("[/AUTO_MEMORY_CONTEXT]")
        return lines.joined(separator: "\n")
    }

    private func drainPendingMessages() {
        // Drain when there's anything to drain — pending channel messages OR attachments
        // staged via `view_attachment` (which arrive with no associated channel message
        // but still need to land in the conversation history for the next LLM turn).
        guard !pendingChannelMessages.isEmpty || !pendingStagedAttachments.isEmpty else { return }

        // When awaiting task review, only wake if a private message addressed to this
        // agent arrived (Smith sending revision feedback). Other messages (system banners,
        // public notifications) are still drained into history but don't trigger a new LLM call.
        if awaitingTaskReview {
            let hasPrivateMessage = pendingChannelMessages.contains { $0.recipientID == id }
            if hasPrivateMessage {
                awaitingTaskReview = false
                hasUnprocessedInput = true
            }
            // else: drain messages into history below, but leave hasUnprocessedInput as-is
        } else {
            // Separate task_complete messages from the batch so they get their own LLM turn.
            // This prevents the review trigger from being buried in a merged text blob.
            let hasTaskComplete = pendingChannelMessages.contains { msg in
                if case .string("task_complete") = msg.metadata?["messageKind"] { return true }
                return false
            }
            let hasOtherMessages = pendingChannelMessages.contains { msg in
                if case .string("task_complete") = msg.metadata?["messageKind"] { return false }
                return true
            }

            if hasTaskComplete && hasOtherMessages {
                // Split: defer task_complete messages, drain everything else now.
                let taskCompleteMessages = pendingChannelMessages.filter { msg in
                    if case .string("task_complete") = msg.metadata?["messageKind"] { return true }
                    return false
                }
                pendingChannelMessages.removeAll { msg in
                    if case .string("task_complete") = msg.metadata?["messageKind"] { return true }
                    return false
                }
                deferredMessages.append(contentsOf: taskCompleteMessages)
            }

            // Lifecycle and agent_online messages are informational — drain them into
            // history for context but don't trigger a new LLM call. Only messages that
            // require Smith's action (user messages, task_complete, errors) should wake it.
            let nonWakingKinds: Set<String> = ["task_lifecycle", "task_acknowledged", "agent_online"]
            let hasActionableMessage = pendingChannelMessages.contains { msg in
                if case .string(let kind) = msg.metadata?["messageKind"],
                   nonWakingKinds.contains(kind) {
                    return false
                }
                return true
            }
            if hasActionableMessage {
                hasUnprocessedInput = true
            }
        }

        // Collect all images across pending messages
        var allImages: [LLMImageContent] = []
        var allTextParts: [String] = []

        for message in pendingChannelMessages {
            let senderLabel: String
            switch message.sender {
            case .user:
                senderLabel = "USER (\(message.sender.displayName))"
            case .agent:
                senderLabel = "AGENT \(message.sender.displayName)"
            case .system:
                senderLabel = "SYSTEM"
            }
            let formatted = "[\(senderLabel)]: \(message.content)"

            let imageAttachments = message.attachments.filter(\.isImage)
            for attachment in imageAttachments {
                guard let data = attachment.data else { continue }
                // Downscale to a 1024px long-edge JPEG/PNG before injection. Saves vision
                // tokens significantly for phone screenshots / camera photos without losing
                // enough detail to answer typical "what's in this image" questions. The
                // downscaler returns the original bytes when the image is already smaller
                // and in a provider-friendly format, so cheap inputs stay cheap.
                let resized = ImageDownscaler.downscale(data, sourceMimeType: attachment.mimeType)
                // Skip injection for formats no provider accepts (e.g. image/svg+xml,
                // unrecognized formats where decode failed and the fallback returned
                // source bytes). The agent still sees the file path and id via the
                // markdown reference line below; for SVG specifically Brown can call
                // file_read which returns the SVG XML content as text.
                guard ImageDownscaler.isProviderInjectable(mimeType: resized.mimeType) else { continue }
                allImages.append(LLMImageContent(data: resized.data, mimeType: resized.mimeType))
            }

            var textParts = [formatted]
            // Surface every attachment as a markdown reference so the agent can quote the
            // `id=<UUID>` into a downstream tool call (`create_task`, `task_update`,
            // `task_complete`, etc.). Image content is also injected as image blocks above
            // — the markdown line is a forwarding handle and a `file://` link Brown can
            // pass to `file_read` for non-image content. The URL provider is sync so this
            // path stays sync; when no provider is wired (tests), the link is degraded to
            // a `#` anchor and the agent still has the `id=` substring to forward.
            for attachment in message.attachments {
                let url = toolContext.attachmentURLProvider(attachment.id, attachment.filename)
                let urlString = url.map { "file://" + $0.path(percentEncoded: false) } ?? "#"
                textParts.append("[\(attachment.filename)](\(urlString)) \(attachment.mimeType) · \(attachment.formattedSize) · id=\(attachment.id.uuidString)")
            }

            allTextParts.append(textParts.joined(separator: "\n"))
        }
        pendingChannelMessages.removeAll()

        // Drain any attachments staged via `view_attachment`. Image attachments at the
        // requested detail tier go in as image content blocks; non-image attachments
        // become markdown reference lines. Dedupe by (id, detail) so a model that calls
        // view_attachment twice in a row doesn't double-inject. Stage list is cleared
        // unconditionally — leaving entries across drains creates leaks under retries.
        if !pendingStagedAttachments.isEmpty {
            var seen: Set<String> = []
            var stagedTextParts: [String] = ["[Staged for this turn via view_attachment]"]
            for entry in pendingStagedAttachments {
                let key = "\(entry.attachment.id.uuidString)|\(String(describing: entry.detail))"
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                let attachment = entry.attachment
                if attachment.isImage, let data = attachment.data {
                    let resized = ImageDownscaler.downscale(
                        data,
                        maxLongEdge: entry.detail.maxLongEdge,
                        sourceMimeType: attachment.mimeType
                    )
                    if ImageDownscaler.isProviderInjectable(mimeType: resized.mimeType) {
                        allImages.append(LLMImageContent(data: resized.data, mimeType: resized.mimeType))
                    }
                }
                let url = toolContext.attachmentURLProvider(attachment.id, attachment.filename)
                let urlString = url.map { "file://" + $0.path(percentEncoded: false) } ?? "#"
                stagedTextParts.append("[\(attachment.filename)](\(urlString)) \(attachment.mimeType) · \(attachment.formattedSize) · id=\(attachment.id.uuidString)")
            }
            allTextParts.append(stagedTextParts.joined(separator: "\n"))
            pendingStagedAttachments.removeAll()
        }

        let combinedText = allTextParts.joined(separator: "\n\n")
        let images: [LLMImageContent]? = allImages.isEmpty ? nil : allImages

        // If the last history entry is already a user message (e.g. a prior LLM call failed
        // before producing an assistant response), merge into it to maintain the strict
        // user/assistant alternation that some model APIs require.
        if let lastIndex = conversationHistory.indices.last,
           conversationHistory[lastIndex].role == .user,
           case .text(let existingText) = conversationHistory[lastIndex].content {
            let merged = existingText + "\n\n" + combinedText
            // Combine images from both the existing message and new messages
            let existingImages = conversationHistory[lastIndex].images
            let mergedImages: [LLMImageContent]? = {
                let combined = (existingImages ?? []) + (images ?? [])
                return combined.isEmpty ? nil : combined
            }()
            conversationHistory[lastIndex] = mergedImages.map { .user(merged, images: $0) } ?? .user(merged)
        } else {
            conversationHistory.append(images.map { .user(combinedText, images: $0) } ?? .user(combinedText))
        }
        pushLiveContext()
    }

    /// Formats tool parameter definitions from a JSON Schema parameters dictionary into a human-readable string.
    static func formatToolParameterDefinitions(_ parameters: [String: AnyCodable]) -> String {
        guard case .dictionary(let properties) = parameters["properties"] else {
            return ""
        }
        var lines: [String] = []
        for (name, value) in properties.sorted(by: { $0.key < $1.key }) {
            var parts = ["- parameter name: \(name)"]
            if case .dictionary(let paramDict) = value {
                if case .string(let desc) = paramDict["description"] {
                    parts.append("- parameter description: \(desc)")
                }
            }
            lines.append(parts.joined(separator: "\n"))
        }
        return lines.enumerated()
            .map { "tool parameter \($0.offset + 1):\n\($0.element)" }
            .joined(separator: "\n")
    }

    /// Formats a tool call as a concise one-liner for channel display, e.g. `"bash: ls -la ~/"`.
    /// Produces a short human-readable description for a tool call.
    /// For `file_write`, returns just `file_write <path>` — the view layer renders rich formatting
    /// using the structured metadata fields (`fileWritePath`, `fileWriteDiff`).
    private static func conciseToolCallSummary(name: String, arguments: String) -> String {
        guard let data = arguments.data(using: .utf8) else {
            return "\(name): \(arguments)"
        }
        let dict: [String: AnyCodable]
        do {
            dict = try JSONDecoder().decode([String: AnyCodable].self, from: data)
        } catch {
            // Malformed JSON from the LLM — fall back to raw arguments string.
            return "\(name): \(arguments)"
        }

        // file_write gets a compact one-liner; the view layer adds rich formatting.
        if name == "file_write", case .string(let path) = dict["path"] {
            return "file_write \(path)"
        }

        // For single-argument tools, just show the value directly
        if dict.count == 1, let value = dict.values.first {
            return "\(name): \(Self.anyCodableToString(value))"
        }

        // For multi-argument tools, show key=value pairs
        let pairs = dict.sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\(Self.anyCodableToString($0.value))" }
            .joined(separator: ", ")
        return "\(name): \(pairs)"
    }

    private static func anyCodableToString(_ value: AnyCodable) -> String {
        switch value {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return String(b)
        case .null: return "null"
        case .array, .dictionary:
            do {
                let data = try JSONEncoder().encode(value)
                return String(data: data, encoding: .utf8) ?? String(describing: value)
            } catch {
                return String(describing: value)
            }
        }
    }

    /// JSON encoder with sorted keys for deterministic argument normalization.
    private static let sortedEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    /// Computes a deduplication signature for a tool call: "toolName|hash(normalizedArgs)".
    /// Arguments are decoded and re-encoded with sorted keys so that JSON key order doesn't matter.
    private static func toolCallSignature(name: String, arguments: String) -> String {
        if let data = arguments.data(using: .utf8),
           let dict = try? JSONDecoder().decode([String: AnyCodable].self, from: data),
           let normalized = try? sortedEncoder.encode(dict),
           let normalizedString = String(data: normalized, encoding: .utf8) {
            return "\(name)|\(normalizedString.hashValue)"
        }
        return "\(name)|\(arguments.hashValue)"
    }

    /// Maximum characters for a tool result stored in conversation history.
    /// Prevents massive outputs (e.g., binary blobs, multi-MB command output) from blowing up LLM context.
    private static let maxToolResultCharacters = 50_000

    /// Maximum characters per argument value in security denial task updates.
    private static let maxArgCharsForUpdate = 50

    static func securityDenialUpdateMessage(
        call: LLMToolCall,
        disposition: SecurityDisposition,
        isParallelBatch: Bool
    ) -> String {
        let label = disposition.isWarning ? "WARN" : "UNSAFE"
        let reason = disposition.message ?? "no reason given"
        let batchNote = isParallelBatch ? " (part of parallel batch)" : ""

        // Truncate each argument value to keep updates readable.
        let truncatedArgs: String
        do {
            guard let data = call.arguments.data(using: .utf8) else {
                throw NSError(domain: "AgentActor", code: 0, userInfo: [NSLocalizedDescriptionKey: "Non-UTF8 arguments"])
            }
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "AgentActor", code: 0, userInfo: [NSLocalizedDescriptionKey: "Arguments not a JSON object"])
            }
            let pairs = dict.map { key, value in
                let raw = String(describing: value)
                let capped = raw.count > maxArgCharsForUpdate
                    ? String(raw.prefix(maxArgCharsForUpdate)) + "…"
                    : raw
                return "\"\(key)\": \"\(capped)\""
            }
            truncatedArgs = pairs.joined(separator: ", ")
        } catch {
            let raw = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            truncatedArgs = raw.count > maxArgCharsForUpdate
                ? String(raw.prefix(maxArgCharsForUpdate)) + "…"
                : raw
        }

        return """
            Tool call "\(call.name)"\(batchNote) execution denied by security agent:
            - Arguments: \(truncatedArgs)
            - Security response: \(label) \(reason)
            """
    }

    /// Caps a tool result string for conversation history, preserving the head and noting truncation.
    static func capToolResult(_ result: String) -> String {
        guard result.count > maxToolResultCharacters else { return result }
        let remaining = result.count - maxToolResultCharacters
        return String(result.prefix(maxToolResultCharacters)) + "\n\n[Output truncated — \(remaining) more characters omitted]"
    }

    /// Truncates multi-line output to a limited number of lines, appending an ellipsis indicator if truncated.
    private static let maxOutputCharacters = 500

    private static func truncateOutput(_ text: String, maxLines: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        var result = trimmed
        var didTruncate = false

        // Truncate by line count
        if lines.count > maxLines {
            result = lines.prefix(maxLines).joined(separator: "\n")
            result += "\n… (\(lines.count - maxLines) more lines)"
            didTruncate = true
        }

        // Truncate by character count
        if result.count > maxOutputCharacters {
            let remaining = trimmed.count - maxOutputCharacters
            result = String(result.prefix(maxOutputCharacters)) + "… (\(remaining) more characters)"
            didTruncate = true
        }

        return didTruncate ? result : trimmed
    }

    /// Parses a JSON string into an AnyCodable dictionary for structural comparison.
    private static func parseToolParams(_ json: String) -> [String: AnyCodable]? {
        guard let data = json.data(using: .utf8) else { return nil }
        do {
            return try JSONDecoder().decode([String: AnyCodable].self, from: data)
        } catch {
            // Malformed JSON — return nil so comparison falls through to normal evaluation.
            return nil
        }
    }

    /// Reads the current contents of `path` for diff computation in
    /// `postToolRequestToChannel`. Returns `nil` when the file can't be diffed:
    /// - Path doesn't exist → `""` (treat as new-file creation, all-added diff)
    /// - File is larger than `maxDiffCaptureBytes` → `nil` (skip diff entirely)
    /// - File exists but the read fails → `nil` (skip diff entirely)
    ///
    /// The raw content returned here is consumed once to compute the diff and
    /// then thrown away — only the resulting `[DiffLine]` is persisted into
    /// channel metadata.
    private static func readOldContentForDiff(path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        let fileSize: Int
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: expanded)
            fileSize = (attrs[.size] as? NSNumber)?.intValue ?? 0
        } catch {
            // File doesn't exist — treat as a new-file write. The diff will
            // then be all-added lines from the new content.
            return ""
        }
        guard fileSize <= Self.maxDiffCaptureBytes else {
            return nil
        }
        do {
            return try String(contentsOfFile: expanded, encoding: .utf8)
        } catch {
            return nil
        }
    }


    /// Estimated-token threshold above which `pruneHistoryIfNeeded` triggers a rebuild
    /// or sliding-window prune. 80% of the input budget to leave headroom for estimator
    /// inaccuracy.
    ///
    /// The output reservation is clamped to at most half the context window before
    /// being subtracted. Some user-saved configs land in a malformed state (e.g. an
    /// LM Studio config observed in production carried `maxOutputTokens=131072` with
    /// `maxContextTokens=64000`); without the clamp, `contextLimit - maxTokens` goes
    /// negative and the threshold collapses below the empty-conversation baseline,
    /// putting the rebuild loop in a tight cycle.
    private var pruneThresholdTokens: Int {
        let contextLimit = configuration.llmConfig.contextWindowSize
        let outputReservation = min(configuration.llmConfig.maxTokens, contextLimit / 2)
        let inputBudget = contextLimit - outputReservation
        return inputBudget * 4 / 5
    }

    /// Input-budget companion to `pruneThresholdTokens`. Used by the non-Brown
    /// sliding-window prune which needs the full input budget (not just 80% of it)
    /// to size its kept window.
    private var inputBudgetTokens: Int {
        let contextLimit = configuration.llmConfig.contextWindowSize
        let outputReservation = min(configuration.llmConfig.maxTokens, contextLimit / 2)
        return contextLimit - outputReservation
    }

    /// Prunes conversation history when approaching the context window limit.
    ///
    /// The available input budget is `contextWindowSize - maxTokens` (the output reservation).
    /// Pruning triggers at 80% of that budget to leave headroom for estimation inaccuracy.
    ///
    /// **Brown** uses task-state rebuild: replaces the entire conversation with a fresh task
    /// instruction synthesized from the task's current state (description, progress updates,
    /// memories, prior tasks) plus the last complete tool call/result exchange for continuity.
    /// This avoids the fragile tool-pair stitching problem and preserves all meaningful context.
    ///
    /// **Non-Brown agents** use a sliding-window prune that keeps ~35% of recent messages.
    private func pruneHistoryIfNeeded() async {
        // Use actual token count from the last LLM response when available, plus a
        // character-based estimate for messages added since that response. This is far
        // more accurate than estimating the entire history at ~3 chars/token.
        // Skip cached usage when stale (set after pruning, before the next LLM call).
        let estimatedTokens: Int
        if !lastUsageStale, let lastUsage = llmTurns.last?.usage {
            // The provider told us exactly how many input tokens the last request used.
            // We only need to estimate tokens for messages appended since that response
            // (new tool results, user messages, etc.) plus the output tokens from that
            // response (which become part of the conversation history going forward).
            let messagesSinceLast = conversationHistory.count - lastTurnMessageCount
            let deltaChars: Int
            if messagesSinceLast > 0 {
                deltaChars = conversationHistory.suffix(messagesSinceLast).reduce(0) {
                    $0 + $1.estimatedCharacterCount
                }
            } else {
                deltaChars = 0
            }
            estimatedTokens = lastUsage.inputTokens + lastUsage.outputTokens + deltaChars / 3
        } else {
            // No prior LLM response — fall back to pure character estimate.
            // ~3 characters per token as a conservative estimate.
            // Include tool definitions and per-turn suffix overhead (not stored in history
            // but sent with every API call and counted against the context window).
            estimatedTokens = (conversationHistory.reduce(0) {
                $0 + $1.estimatedCharacterCount
            } + apiOverheadChars) / 3
        }

        guard estimatedTokens > pruneThresholdTokens else { return }

        // Capture last known input tokens before reset for analytics.
        pendingPreResetTokens = llmTurns.last?.usage?.inputTokens

        if configuration.role == .brown {
            // Brown rebuilds from task state — clean, no tool-pair stitching issues.
            let rebuilt = await rebuildContextFromTask()
            if !rebuilt {
                // No running task — fall back to aggressive prune as a last resort.
                forceAggressivePrune()
                return
            }

            // Rebuild-loop guard: increment the counter for every prune-driven rebuild
            // and terminate if it exceeds the bound. The counter resets on a successful
            // LLM turn — see the reset alongside `consecutiveErrors` /
            // `consecutiveContextOverflows` in `runLoop`. Without this guard, a rebuilt
            // context that still exceeds the threshold puts the loop in a tight cycle.
            consecutivePruneRebuilds += 1
            if consecutivePruneRebuilds >= Self.maxConsecutivePruneRebuilds {
                let roleName = configuration.role.displayName
                await toolContext.post(ChannelMessage(
                    sender: .system,
                    content: "Agent \(roleName) stopped: context still exceeds the prune threshold after \(Self.maxConsecutivePruneRebuilds) rebuild attempts. The model's context window is too small for this task envelope (system prompt + tool definitions + memories + prior tasks + progress). Switch Brown to a model with a larger context window or trim the task description.",
                    metadata: ["isError": .bool(true), "agentRole": .string(configuration.role.rawValue)]
                ))
                isRunning = false
            }
            return
        }

        // Non-Brown sliding-window prune (Smith doesn't use tool calls the same way).
        pruneNonBrownHistory(inputBudget: inputBudgetTokens)
    }

    /// Sliding-window prune for non-Brown agents. Keeps ~35% of recent messages.
    private func pruneNonBrownHistory(inputBudget: Int) {
        // Need at least a system prompt + two messages for pruning to make sense.
        guard conversationHistory.count > 2 else { return }

        let targetTokens = inputBudget * 7 / 20
        var keptTokens = 0
        var keepFromIndex = conversationHistory.count

        for i in stride(from: conversationHistory.count - 1, through: 1, by: -1) {
            let msgTokens = conversationHistory[i].estimatedCharacterCount / 3
            if keptTokens + msgTokens > targetTokens {
                break
            }
            keptTokens += msgTokens
            keepFromIndex = i
        }

        // If we couldn't fit anything, still keep the most recent message.
        if keepFromIndex >= conversationHistory.count {
            keepFromIndex = conversationHistory.count - 1
        }

        // If all messages appeared to fit (zero/underestimated token counts), force-prune
        // the oldest half to prevent unbounded growth despite the token threshold being exceeded.
        if keepFromIndex == 1 {
            keepFromIndex = max(2, conversationHistory.count / 2)
        }

        // Don't split tool call/result pairs — back up past any orphaned tool results.
        while keepFromIndex > 1, conversationHistory[keepFromIndex].role == .tool {
            keepFromIndex -= 1
        }

        // If the tool walk-back collapsed to index 1, force a minimal prune from index 2
        // so we always make forward progress against the context limit.
        if keepFromIndex <= 1 {
            guard conversationHistory.count > 2 else { return }
            keepFromIndex = 2
        }

        let prunedCount = keepFromIndex - 1
        guard prunedCount > 0 else { return }

        var newHistory = [conversationHistory[0]]  // System prompt
        newHistory.append(.user("[System: \(prunedCount) earlier messages were pruned to stay within context limits. Continue from the recent context below.]"))
        newHistory.append(contentsOf: conversationHistory[keepFromIndex...])
        conversationHistory = newHistory
        lastTurnMessageCount = conversationHistory.count
        lastUsageStale = true
        pushLiveContext()

        let roleName = configuration.role.displayName
        let ctx = toolContext
        Task.detached {
            await ctx.post(ChannelMessage(
                sender: .system,
                content: "Context pruned for \(roleName): removed \(prunedCount) old messages."
            ))
        }
    }

    /// Detects whether an error is a context overflow (the request exceeded the model's context window).
    /// Matches the error body patterns from OpenAI-compatible APIs (DeepSeek, Mistral, etc.).
    private static func isContextOverflowError(_ error: Error) -> Bool {
        guard let providerError = error as? LLMProviderError,
              case .httpError(let statusCode, let body, _) = providerError else {
            return false
        }
        // HTTP 400 with body indicating the request exceeded the model's context window.
        // Each pattern matches a substantial, provider-specific substring to avoid false
        // positives. Unmatched 400s are logged by logUnhandled400 so we can add new patterns.
        //
        // Known formats:
        // - OpenAI/DeepSeek/Mistral: "This model's maximum context length is N tokens"
        // - OpenAI error code: "context_length_exceeded"
        // - Anthropic: "prompt is too long: N tokens"
        // - Generic: "Please reduce the length of the messages"
        if statusCode == 400 {
            let lower = body.lowercased()
            return lower.contains("maximum context length is")
                || lower.contains("context_length_exceeded")
                || lower.contains("reduce the length of the messages")
                || lower.contains("prompt is too long:")
        }
        return false
    }

    /// Emergency prune for non-Brown agents: keeps system prompt and the most recent 20%
    /// of messages. Brown uses `rebuildContextFromTask` instead.
    private func forceAggressivePrune() {
        guard conversationHistory.count > 3 else { return }

        // Keep only the most recent ~20% of messages (by count, not tokens)
        let keepCount = max(4, conversationHistory.count / 5)
        var keepFromIndex = conversationHistory.count - keepCount

        // Don't split tool call/result pairs
        while keepFromIndex > 1, conversationHistory[keepFromIndex].role == .tool {
            keepFromIndex -= 1
        }
        keepFromIndex = max(1, keepFromIndex)

        let prunedCount = keepFromIndex - 1
        guard prunedCount > 0 else { return }

        var newHistory = [conversationHistory[0]]  // System prompt
        newHistory.append(.user("[System: \(prunedCount) earlier messages were aggressively pruned after a context overflow error. Continue from the recent context below.]"))
        newHistory.append(contentsOf: conversationHistory[keepFromIndex...])
        conversationHistory = newHistory
        lastTurnMessageCount = conversationHistory.count
        lastUsageStale = true
        // The pruned slice may or may not have included Brown's last task_update;
        // either way, post-prune counts start fresh against the kept slice.
        if configuration.role == .brown {
            lastTaskCommunicationAt = Date()
            toolCallsSinceTaskCommunication = 0
            brownSilenceNudgeArmed = true
        }
        pushLiveContext()

        let roleName = configuration.role.displayName
        let ctx = toolContext
        Task.detached {
            await ctx.post(ChannelMessage(
                sender: .system,
                content: "Aggressively pruned \(prunedCount) messages for \(roleName) (no running task for rebuild)."
            ))
        }
    }

    /// Rebuilds Brown's conversation history from the current running task's data.
    ///
    /// Completely replaces the conversation history with:
    /// 1. The original system prompt
    /// 2. A synthesized task instruction built from the task's current state (title, description,
    ///    all progress updates, relevant memories/prior tasks)
    /// 3. The last complete assistant + tool-result exchange from the old history (for continuity)
    ///
    /// This is far more efficient than pruning because task updates are a compressed log
    /// of accomplishments (~1 line each) vs the verbose tool call/result pairs they replaced.
    /// It also eliminates tool-pair stitching bugs that can cause API errors.
    ///
    /// - Returns: `true` if a running task was found and context was rebuilt; `false` otherwise.
    private func rebuildContextFromTask() async -> Bool {
        let allTasks = await toolContext.taskStore.allTasks()
        guard let task = allTasks.first(where: { $0.status == .running }) else {
            return false
        }

        // Extract the last complete tool exchange before clearing history.
        let lastExchange = extractLastToolExchange()

        // Post a task update so the rebuild is visible in the task's progress log.
        await toolContext.taskStore.addUpdate(
            id: task.id,
            message: "Context cleared due to size limits — rebuilding from task state and continuing work."
        )

        // Rebuild conversation: system prompt + fresh task instruction.
        var parts: [String] = []

        if let memories = task.relevantMemories, !memories.isEmpty {
            let memoryLines = memories.map { "- \($0.content) (similarity: \(String(format: "%.2f", $0.similarity)))" }
            parts.append("Relevant memories:\n\(memoryLines.joined(separator: "\n"))")
        }
        if let priorTasks = task.relevantPriorTasks, !priorTasks.isEmpty {
            let taskLines = priorTasks.map { priorTask in
                "- \(priorTask.title): \(priorTask.summary) (similarity: \(String(format: "%.2f", priorTask.similarity))) — task_id: \(priorTask.taskID.uuidString)"
            }
            parts.append("Relevant prior task summaries (call `get_task_details(task_ids: [...])` with up to 10 IDs at once if you need full details):\n\(taskLines.joined(separator: "\n"))")
        }

        parts.append("""
            Task: "\(task.title)"
            Task ID: \(task.id.uuidString)

            \(task.description)
            """)

        if !task.updates.isEmpty {
            let history = task.updates.map { "- \($0.message)" }.joined(separator: "\n")
            parts.append("Progress so far:\n\(history)")
        }

        if let brownContext = task.lastBrownContext {
            parts.append("Last known working state:\n\(brownContext)")
        }

        parts.append("""
            Your conversation history was cleared because it exceeded the model's context window. \
            The task progress above reflects your work so far. Continue working on this task from where you left off. \
            Do not repeat work that the progress updates show is already done. \
            IMPORTANT: This task is already acknowledged and running — do NOT call `task_acknowledged` again.
            """)

        let instruction = parts.joined(separator: "\n\n")

        conversationHistory = [
            conversationHistory[0],  // System prompt
            .user(instruction)
        ]

        // Append the last complete tool exchange so Brown has immediate continuity
        // with what it just did. This is always a valid sequence: assistant (with toolCalls)
        // followed by all its matching tool result messages.
        //
        // Guard against infinite rebuild loops: if the base history plus the last exchange
        // would still exceed the prune threshold, drop the exchange. The task's progress
        // updates already capture what was accomplished.
        if !lastExchange.isEmpty {
            let baseChars = conversationHistory.reduce(0) { $0 + $1.estimatedCharacterCount }
            let exchangeChars = lastExchange.reduce(0) { $0 + $1.estimatedCharacterCount }
            let estimatedTokens = (baseChars + exchangeChars + apiOverheadChars) / 3

            if estimatedTokens <= pruneThresholdTokens {
                conversationHistory.append(contentsOf: lastExchange)
            }
        }

        lastTurnMessageCount = conversationHistory.count
        llmTurns.removeAll()
        lastUsageStale = true
        hasUnprocessedInput = true
        pushLiveContext()

        // Reset Brown's silence-nudge counters: the rebuilt history shows zero tool
        // calls since the (synthetic) task acknowledgement, so post-rebuild counts
        // must start from zero too. Without this the next tool turn can immediately
        // trip the nudge and accuse Brown of N tool calls whose history no longer
        // exists in its view.
        if configuration.role == .brown {
            lastTaskCommunicationAt = Date()
            toolCallsSinceTaskCommunication = 0
            brownSilenceNudgeArmed = true
        }

        let ctx = toolContext
        let prunedLabel = configuration.role.displayName
        Task.detached {
            await ctx.post(ChannelMessage(
                sender: .system,
                content: "Context rebuilt for \(prunedLabel) from task state."
            ))
        }

        return true
    }

    /// Extracts the last complete assistant + tool-result exchange from conversation history.
    ///
    /// Walks backward to find the last assistant message that contains tool calls, then
    /// collects all consecutive `.tool` result messages that follow it. Returns the
    /// complete sequence (assistant + tool results) or an empty array if none found.
    private func extractLastToolExchange() -> [LLMMessage] {
        // Find the last assistant message with tool calls.
        var assistantIndex: Int?
        for i in stride(from: conversationHistory.count - 1, through: 0, by: -1) {
            let msg = conversationHistory[i]
            guard msg.role == .assistant else { continue }
            switch msg.content {
            case .toolCalls, .mixed:
                assistantIndex = i
            default:
                continue
            }
            break
        }

        guard let aIdx = assistantIndex else { return [] }

        // Collect the assistant message and all consecutive tool results after it.
        var exchange = [conversationHistory[aIdx]]
        var nextIdx = aIdx + 1
        while nextIdx < conversationHistory.count, conversationHistory[nextIdx].role == .tool {
            exchange.append(conversationHistory[nextIdx])
            nextIdx += 1
        }

        // Only return if we have at least one tool result (a complete pair).
        return exchange.count >= 2 ? exchange : []
    }

    /// Logs HTTP 400 errors that were NOT classified as context overflow, so we can
    /// detect patterns that may need specific handling in the future.
    private static let agentLogger = Logger(subsystem: "com.agentsmith", category: "AgentActor")
    private static let stopLogger = Logger(subsystem: "com.agentsmith", category: "Stop")

    private static func logUnhandled400(_ error: Error) {
        guard let providerError = error as? LLMProviderError,
              case .httpError(let statusCode, let body, let url) = providerError,
              statusCode == 400 else {
            return
        }
        agentLogger.warning(
            "Unhandled HTTP 400 (not context overflow): url=\(url?.absoluteString ?? "unknown", privacy: .public) body=\(body.prefix(500), privacy: .public)"
        )
    }

}
