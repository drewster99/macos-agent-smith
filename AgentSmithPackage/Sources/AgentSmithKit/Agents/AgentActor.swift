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
    /// True once `refreshActiveTools()` has run at least once, i.e. `activeTools` reflects the
    /// registry's scoped verdict rather than the unscoped construction-time placeholder. Used by
    /// `toolNames` so a scoped worker never reports the unscoped roster in the pre-first-refresh
    /// window (which for Brown would include `bash`).
    private var hasRefreshedActiveTools = false
    /// Per-agent tool registry + availability gate. Rebuilt each turn from the candidate
    /// set (built-ins + dynamic MCP tools); `activeTools` is its `availableTools()`.
    private var toolRegistry = ToolRegistry()
    /// When true (Brown only), this agent's tools are security-scoped per task: candidates are
    /// seeded *disabled* and only `approvedToolNames` (plus forced lifecycle tools) are
    /// available. When false (Smith/Security Agent), every candidate is seeded approved (no scoping).
    private var toolScopingEnabled = false
    /// The current security-approved tool names (the scoping verdict). Drives `isApproved`.
    private var approvedToolNames: Set<String> = []
    /// Whether the worker has acknowledged its task yet — gates which forced lifecycle tools
    /// are exposed. Acknowledgement itself is a runtime action (no tool); once done, the post-ack
    /// tools `task_update` / `task_complete` / `request_help` become available.
    private var taskAcknowledged = false
    /// Fingerprint of the candidate set at the last scoping. A change (MCP added/removed/
    /// redefined) triggers a fresh stateless re-scope at the next turn boundary.
    private var lastScopedFingerprint: String?
    /// Global per-tool availability policy (user-set in Settings). Overrides the automatic scoping
    /// verdict: `.never` strips a tool, `.always` adds it. Empty = no global overrides.
    private var globalToolPolicy: [String: ToolPolicy] = [:]
    /// Per-task user overrides keyed by tool name (`true` = force on, `false` = force off). Applied
    /// AFTER the global policy (so they win) and re-applied every refresh, so a re-scope can't
    /// clobber the user's choice.
    private var userToolOverrides: [String: Bool] = [:]
    /// Whether Security Agent pre-flight scoping is active for this worker. When false, the base approved set
    /// is "every current candidate" (no scoping verdict, no mid-task re-scope); global policy and
    /// per-task overrides still apply on top.
    private var preflightScopingActive = true
    /// Whether the per-tool-call security evaluation (Security Agent SAFE/WARN/UNSAFE/ABORT) is active. When
    /// false, Brown's approved tools execute without per-call review. Live-toggleable from Settings.
    /// When true (Smith), the Security Agent gates ONLY open-world (network-egress) tool calls —
    /// `web_fetch` / `web_search` / `instant_answer` — while local read-only and messaging tools run
    /// un-reviewed. This is the egress filter: Smith is unscoped and holds the user's memories and
    /// file-read, so an injected instruction to fetch `https://attacker/?d=<secret>` would otherwise
    /// be an unreviewed exfiltration channel. Brown instead reviews ALL tools via `requiresToolApproval`.
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

    /// The task title stamped (as `senderTaskTitle` metadata) on this agent's channel
    /// messages, so the UI can label a worker by WHAT it's working on instead of a bare
    /// "Brown" — the only disambiguator once multiple workers run concurrently.
    private var channelTaskTitle: String?

    /// Sets the task title stamped on this agent's channel messages (worker spawns).
    public func setChannelTaskTitle(_ title: String?) {
        channelTaskTitle = title
    }
    private var isRunning = false
    private var runTask: Task<Void, Never>?

    /// Bounded FIFO of recently-ingested channel-message IDs, used to dedupe delivery. Guards
    /// against a pending-user-message drain (`acceptChannelMessage`) redelivering a message
    /// that the live subscription already accepted, or a post-crash replay double-appending.
    private var recentIngestedMessageIDs: [UUID] = []
    private static let recentIngestedMessageIDCap = 256

    /// Fired from `drainPendingMessages` with the `ChannelMessage.id`s of user-sender messages
    /// at the moment they are incorporated into the conversation for a turn. The runtime uses
    /// this to remove the matching entries from its persisted pending-user-message buffer — so a
    /// buffered message is dropped from durable storage only once Smith has actually taken it
    /// in, not merely accepted it into the volatile pending queue (which would lose it if Smith
    /// were torn down or the app crashed before the run loop processed it).
    private var onInboundUserMessagesIncorporated: (@Sendable ([UUID]) -> Void)?

    /// Direct security evaluator for tool approval. The Security Agent role runs as this
    /// lightweight evaluator rather than a full agent actor with a separate approval gate.
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

    /// Attachments staged by `attach_file` for injection into the next user turn.
    /// Drained by `drainPendingMessages` — image bytes (downscaled) become content blocks
    /// in the assembled LLM message; text/document refs are appended to the message body.
    /// Cleared after each drain so a stage that doesn't get a turn (rare) doesn't leak
    /// across runs.
    private var pendingStagedAttachments: [(attachment: Attachment, detail: AttachmentDetail)] = []

    /// Detail tier requested by `attach_file`. Controls which downscale variant gets
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

    /// The currently sleeping idle task. Cancelling it wakes the agent early.
    private var idleSleepTask: Task<Void, Never>?

    /// Seconds of channel silence required before processing new messages.
    private let messageDebounceInterval: TimeInterval

    /// Timestamp of the most recent direct message from the user to this agent.
    /// Used to gate availability of the `reply_to_user` tool.
    private var lastDirectUserMessageAt: Date?

    /// Tracks consecutive LLM errors for exponential backoff. Reset by any successful turn.
    ///
    /// Retry shape — attempt budget, backoff curve, transient/permanent classification, and
    /// `Retry-After` handling — comes from `LLMRetryPolicy`, shared with the summarizer, the
    /// security evaluator, tool scoping, and the validators. The per-class backoff caps this
    /// once carried (120s transient / 1800s rate-limited) are gone: a server-directed
    /// `Retry-After` is still honored uncapped, which is what actually paces a real rate limit,
    /// and everything else now uses the shared 15s ceiling.
    private var consecutiveErrors = 0
    private static let maxConsecutiveErrors = LLMRetryPolicy.maxAttempts
    /// A server-supplied `Retry-After` is always honored, but one at or above this is flagged
    /// in the transcript as unusually long so a multi-hour/day wait doesn't look like a hang
    /// and the user can intervene.
    private static let ridiculousRetryAfterSeconds = LLMRetryPolicy.ridiculousRetryAfterSeconds

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

    /// The model's true maximum output-token limit, learned from a backend rejection
    /// ("max_tokens (X) exceeds model's maximum output tokens (Y)"). Once set, every send
    /// this run clamps its output cap to it so the agent stops re-hitting the same 400.
    /// `nil` until learned; the persisted catalog override (written via the runtime callback)
    /// clamps future runs at provider-construction time.
    private var learnedMaxOutputCeiling: Int?

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

    /// Content of the synthetic assistant message appended when a non-Brown agent returns an empty
    /// completion (no text, no tool calls). It is a structural TURN BOUNDARY in `conversationHistory`
    /// — it stops the next injection from merging into the still-open user turn and re-feeding a
    /// stale prompt (the 2026-04-25 "wakes silently dropped" bug) — NOT a user-facing message, so it
    /// is never posted to the channel. It stays visible in the raw conversation history / inspector.
    ///
    /// Because the marker lives in the model's own context, the model can PARROT it back as literal
    /// text on a later turn. Such a response is semantically "nothing to say", so it is treated as
    /// an empty response (see `handleResponse`): not counted as real text and never posted, which
    /// also keeps the parrot from reinforcing itself in the channel.
    public static let emptyResponseTurnMarker = "(no response)"

    /// Tracks consecutive identical tool calls (same name + same normalized arguments).
    /// Catches degenerate loops where the LLM repeatedly calls the same tool with the same
    /// arguments (e.g. task_update spam). Any different tool call or text-only response resets.
    /// Threshold of 4 is safely above the WARN retry case (max 2 identical calls).
    private var lastToolCallSignature: String?
    private var consecutiveIdenticalToolCalls = 0
    private static let maxConsecutiveIdenticalToolCalls = 4

    /// Per-tool failures since that tool's last success. Complements the identical-call
    /// breaker above, which resets on any text-only turn or different call — the 2026-07-08
    /// zombie Brown failed `task_complete` 13 times over 14 minutes with narration turns
    /// and successful `file_read`s interleaved, so no *consecutive* rule could catch it.
    /// A tool that fails this many times without a single success is a loop regardless of
    /// what happens in between. Warned once per streak; the streak resets only when the
    /// same tool finally succeeds.
    private var toolFailureStreaks: [String: Int] = [:]
    private var toolFailureWarnedTools: Set<String> = []
    private static let toolFailureStreakWarnThreshold = 5
    private static let toolFailureStreakStopThreshold = 10

    /// Brown-only. Counts the `Continue.` continuation nudges injected since the worker last
    /// made forward progress, and bounds them.
    ///
    /// A text-only Brown turn does not go idle — it gets a synthetic "Continue. Use your tools"
    /// user turn and the run loop immediately spins again (see `handleResponse`). That is right
    /// for a worker thinking aloud mid-task and wrong for a worker that has genuinely run out of
    /// work: narrating is the one thing it can do forever, so "keep nudging" has no natural end.
    ///
    /// The three existing breakers all miss this shape, because each is reset by the other's
    /// signal: the text-only breaker resets on ANY tool call, the identical-call breaker resets
    /// on ANY text-only turn, and the failure-streak breaker only counts failures. A worker
    /// alternating narration with a succeeding read-only call defeats all three indefinitely —
    /// 2026-07-27 measured 58 text-only turns and 23 byte-identical `get_task_details` calls
    /// over 19 minutes before the text-only breaker happened to catch a clean run of six.
    ///
    /// So this counter deliberately does NOT reset on just any tool call. Progress means a tool
    /// call whose signature DIFFERS from the previous one (`lastToolCallSignature`), or genuinely
    /// new input arriving from outside. Re-reading the same thing and narrating about it is not
    /// progress no matter how it is interleaved.
    ///
    /// Hitting the cap idles the worker rather than terminating it — "you have nothing to do" is
    /// answered by waiting, and the silence nudge, a scheduled wake, or any inbound message can
    /// still wake it. This is defense in depth: with the `resumesParkedWorker` fix a finished
    /// worker should stay parked and never reach this path at all.
    private var continuationNudgesSinceProgress = 0
    /// Must stay ABOVE `textOnlyResponseLimit(for: .brown)`, which terminates on unrelieved
    /// narration. Below it, this cap would fire first and silently convert that termination into
    /// an idle — the two breakers are meant to cover different shapes, not race.
    static let maxContinuationNudgesSinceProgress = 10

    /// Consecutive text-only responses tolerated before the agent is treated as degenerate and
    /// terminated. Brown is a tool-heavy worker, so unrelieved narration is diagnostic quickly;
    /// Smith is conversational and legitimately answers many turns with prose alone.
    static func textOnlyResponseLimit(for role: AgentRole) -> Int {
        role == .smith ? 30 : 6
    }

    /// Brown-only: whether the queued-message handover has already run for this worker.
    ///
    /// Queued messages are delivered ONCE, on the turn after the briefing — see
    /// `deliverQueuedTaskMessagesIfDue`.
    private var hasDeliveredQueuedTaskMessages = false

    /// Brown-only: time of the most recent task communication (first-turn acknowledgement,
    /// task_update, or task_complete). Used by the silence nudge. Initialized when the run loop starts.
    private var lastTaskCommunicationAt: Date?
    /// Brown-only: tool calls Brown has executed since his last task communication.
    /// Reset on acknowledgement and every successful task_update/task_complete.
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

    /// Smith-only: pulls notifications the broker has queued for this agent (reminders, summaries,
    /// external messages), returning their delivery text. Drained once per run-loop iteration — Smith
    /// no longer polls scheduled wakes; the `WakeScheduler` fires them into the broker, which holds
    /// them here until Smith drains. Nil in agents/tests without a broker.
    private var drainNotifications: (@Sendable () async -> [String])?

    private var maxToolCallsPerIteration: Int
    /// Maximum concurrent Security Agent evaluations for ONE agent's tool batch, enforced as a
    /// sliding window rather than a fan-out.
    ///
    /// This is per AGENT, not global: with `maxConcurrentWorkers` Browns live, the ceiling across
    /// the app is this times that, before the validator's own concurrent evaluations are counted.
    /// Raised 8 → 20 on 2026-07-26. The original cap of 5 (later 8) came from Ollama returning
    /// "too many concurrent requests"; if a backend starts refusing again, this is the first knob
    /// to turn back down.
    private static let maxConcurrentEvaluations = 20

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

    /// External / asynchronous `.user` injections (`appendUserMessage`) are queued here rather
    /// than appended straight to `conversationHistory`. The run loop is the SOLE writer of
    /// `conversationHistory`; it drains this queue at the top of the loop — a boundary where the
    /// previous turn is always complete — so an injection can never land between an assistant
    /// `tool_calls` message and its `tool_result`s. A concurrent writer (e.g. the
    /// TaskValidationCoordinator informing Smith while he was parked in a long `save_memory`
    /// call) splicing here was the cause of the "tool_call_id did not have response messages" 400s.
    private var pendingInjectedMessages: [LLMMessage] = []

    /// A `/clear` that arrived mid-tool-turn is deferred to the run loop boundary (see
    /// `resetConversationHistory`) so it can't wipe an in-flight assistant `tool_calls` turn and
    /// orphan the results appended after it.
    private var pendingResetRequested = false
    private var pendingResetOrientation: String?

    /// True for exactly the span of `handleResponse` — from just before the assistant turn is
    /// appended, through the last `tool_result`. A tool turn is NOT one atomic actor entry: the
    /// assistant `tool_calls` message and its results are appended across several actor entries
    /// separated by `await`s (each tool executes at a suspension point). At any of those
    /// suspensions a reentrant external writer (`resetConversationHistory`, `compactConversationHistory`)
    /// could wipe or splice the history and orphan the results appended when the loop resumes.
    /// `lastTurnAwaitsToolResults` is too narrow to catch this — mid-segment the last message is a
    /// `.tool` result, not an open assistant — so those writers gate on THIS flag instead. The run
    /// loop is sequential (one `handleResponse` at a time, never nested), so a plain bool suffices.
    private var isProcessingToolTurn = false

    /// When true, the agent acknowledges its assigned task on its first turn — as a runtime
    /// side effect, WITHOUT an LLM round-trip and WITHOUT a callable tool. Acknowledgement moves
    /// the task to `.running`, bumps the ack counter, and privately notifies Smith.
    private var acknowledgesTaskOnFirstTurn = false

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
        // Single-writer invariant: enqueue, never splice directly (see `pendingInjectedMessages`).
        // The run loop drains this at a turn boundary; `pushLiveContext` happens on drain.
        pendingInjectedMessages.append(.user(text))
        hasUnprocessedInput = true
        // Wake an idle loop so the injection is drained and processed promptly rather than waiting
        // out the poll interval — parity with `ingestChannelMessage`. A no-op mid-tool-turn (the
        // idle sleep task is nil), so it can't disturb an in-flight turn.
        interruptIdleSleep()
    }

    /// Same as `appendUserMessage(_:)` but also injects image attachments as inline
    /// image content for the LLM. Non-image attachments should already be referenced in
    /// the text body via `[filename](file://…) … id=<UUID>` markdown lines so the agent
    /// can quote the id forward downstream. Used by the seed-Brown briefing path so a
    /// task created with attached files reaches Brown's first LLM turn with the bytes intact.
    /// Stages attachments for injection into the next user turn. Called by the
    /// `attach_file` tool so Brown can pull a previously-known attachment into his
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
        // Briefing-time injection is the most context-expensive moment in Brown's lifetime —
        // every reset re-pays the image cost — so the helper's standard downscale applies. It
        // also emits a `file://` reference line per attachment (parity with the channel-drain
        // path, which the old briefing code lacked — it silently dropped non-image attachments)
        // and gates image bytes on the model's vision capability.
        let assembled = AttachmentInjection.assemble(
            attachments,
            modelSupportsVision: configuration.supportsVision,
            modelSupportsDocuments: configuration.supportsDocuments,
            urlProvider: toolContext.attachmentURLProvider
        )
        var body = text
        if !assembled.referenceLines.isEmpty {
            body += "\n" + assembled.referenceLines.joined(separator: "\n")
        }
        if assembled.images.isEmpty && assembled.documents.isEmpty {
            pendingInjectedMessages.append(.user(body))
        } else {
            pendingInjectedMessages.append(.user(body, images: assembled.images, documents: assembled.documents))
        }
        hasUnprocessedInput = true
        interruptIdleSleep()
    }

    /// True when the last message is an assistant carrying `tool_calls` whose `tool_result`s
    /// haven't been appended yet — splicing anything after it would orphan the tool call.
    private var lastTurnAwaitsToolResults: Bool {
        guard let last = conversationHistory.last else { return false }
        switch last.content {
        case .toolCalls: return true
        case .mixed(_, let calls): return !calls.isEmpty
        default: return false
        }
    }

    /// Drains queued external injections into `conversationHistory`. Called by the run loop at
    /// the top of the iteration, where the previous turn is complete. The tool-results guard is
    /// belt-and-suspenders: at the loop top the last message is never an unanswered assistant
    /// tool-call, but if that ever changes, defer to the next iteration rather than splice.
    ///
    /// Package-internal (not private) so white-box tests can simulate the loop-boundary drain
    /// deterministically without spinning the whole run loop; the only production caller is the
    /// run loop.
    func drainPendingInjectedMessages() {
        guard !pendingInjectedMessages.isEmpty, !lastTurnAwaitsToolResults else { return }
        conversationHistory.append(contentsOf: pendingInjectedMessages)
        pendingInjectedMessages.removeAll()
        // Ensure the just-drained messages are actually processed this iteration — matters for
        // the deferred path, where the enqueue's `hasUnprocessedInput` may already be consumed.
        hasUnprocessedInput = true
        // An injected message (spawn briefing, send-back feedback, amended task) is new material
        // to act on, so the continuation-nudge budget starts over.
        continuationNudgesSinceProgress = 0
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

    /// Arranges for this agent to acknowledge its assigned task on its first turn, bypassing the
    /// LLM. Cleared after it runs.
    public func setAcknowledgesTaskOnFirstTurn() {
        acknowledgesTaskOnFirstTurn = true
    }

    /// Enables per-task security scoping for this agent (Brown), seeding the initial approved
    /// set from the runtime's pre-start scoping pass. After this, only approved + forced
    /// lifecycle tools are available; mid-task candidate changes trigger a fresh stateless
    /// re-scope at the turn boundary.
    public func enableToolScoping(approvedNames: Set<String>) {
        toolScopingEnabled = true
        approvedToolNames = approvedNames
    }

    /// Sets the global per-tool availability policy (user Settings). Takes effect next refresh.
    public func setGlobalToolPolicy(_ policy: [String: ToolPolicy]) {
        globalToolPolicy = policy
    }

    /// Sets the per-task user tool overrides. Takes effect next refresh.
    public func setUserToolOverrides(_ overrides: [String: Bool]) {
        userToolOverrides = overrides
    }

    /// Whether Security Agent pre-flight scoping is active (false ⇒ base set is all candidates, no re-scope).
    public func setPreflightScopingActive(_ active: Bool) {
        preflightScopingActive = active
    }


    /// The last few user-role messages, concatenated, for the Security Agent's context when this
    /// agent has no task to describe (Smith). The motivating request may be many turns back — a
    /// delayed "create a task to do X when the current one finishes" — so a window is passed, not
    /// just the latest. System-injected nudges are skipped so the model sees real user intent.
    private func recentUserMessagesForEvaluation(limit: Int = 4) -> String? {
        var texts: [String] = []
        for msg in conversationHistory.reversed() where msg.role == .user {
            guard case .text(let text) = msg.content else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("[System") || trimmed.hasPrefix("Continue.") { continue }
            texts.append(trimmed)
            if texts.count >= limit { break }
        }
        guard !texts.isEmpty else { return nil }
        return texts.reversed().joined(separator: "\n---\n")
    }

    /// Applies built-in defaults, global tool policy, then per-task user overrides, on top of a base approved set.
    /// Order is deliberate: policy `.always`/`.never` override the automatic verdict; per-task
    /// overrides then override the globals. Forced lifecycle tools are handled separately (above all).
    private func resolveEffectiveApproved(base: Set<String>, candidates: Set<String>) -> Set<String> {
        var result = base
        for (name, policy) in ToolPolicy.builtInDefaults where candidates.contains(name) {
            switch policy {
            case .never: result.remove(name)
            case .always: result.insert(name)
            case .default: break
            }
        }
        for name in candidates {
            switch globalToolPolicy[name] {
            case .never: result.remove(name)
            case .always: result.insert(name)
            case .default, .none: break
            }
        }
        for (name, enabled) in userToolOverrides where candidates.contains(name) {
            if enabled { result.insert(name) } else { result.remove(name) }
        }
        return result
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

    /// Smith-only: registers the closure used to assemble periodic Brown-activity digests.
    /// Idempotent — replaces any prior provider.
    public func setSmithDigestProvider(_ provider: @escaping @Sendable (Date) async -> String?) {
        smithDigestProvider = provider
    }

    /// Smith-only: wires the notification-drain source (the broker's pending queue for this agent).
    /// Once set, the run loop drains queued notifications each iteration instead of polling wakes.
    public func setDrainNotifications(_ handler: @escaping @Sendable () async -> [String]) {
        drainNotifications = handler
    }

    /// Wakes the agent from an idle sleep so it can drain freshly-queued notifications immediately
    /// rather than at its next scheduled tick. Called by the broker's enqueue nudge.
    public func wakeFromIdle() {
        interruptIdleSleep()
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

        runTask = Task { [weak self] in
            guard let self else { return }
            await self.runLoop()
        }
    }

    /// Awaits `operation`, but gives up after `seconds` and returns `false` WITHOUT
    /// structurally awaiting it past the deadline. Needed because `withTaskGroup`
    /// awaits every child at scope exit — so an observer parked in a
    /// cancellation-ignoring `await` (e.g. `await runTask.value` for a run loop wedged
    /// inside a hung MCP/LLM call) would hang the very timeout it's meant to enforce.
    /// Here the observer and the timer are unstructured tasks; we resume on whichever
    /// finishes first and abandon the loser.
    private static func completesWithin(
        seconds: Double,
        _ operation: @escaping @Sendable () async -> Void
    ) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            @Sendable func resumeOnce(with value: Bool) {
                let shouldResume = resumed.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if shouldResume { continuation.resume(returning: value) }
            }
            Task {
                await operation()
                resumeOnce(with: true)
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                resumeOnce(with: false)
            }
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
            // Only on THIS path. A first `stop()` that timed out set `runTask = nil` while
            // abandoning a run loop that may still be registering evaluations, and the later
            // `terminateAgent` → `stop()` arrives here — so this is where those orphans get swept.
            //
            // Deliberately NOT above the guard: on a healthy stop that would run BEFORE
            // `task.cancel()` and delete entries for evaluations still genuinely in flight, so the
            // agent would be blocked on security while the meter said nothing was happening. The
            // post-teardown sweep below covers the normal path, after the loop has actually gone.
            await securityEvaluator?.clearInFlightEvaluations(forAgentInstanceID: id)
            Self.stopLogger.notice("AgentActor.stop no runTask — early return role=\(role, privacy: .public) agent=\(agentID, privacy: .public)")
            return
        }
        task.cancel()
        Self.stopLogger.notice("AgentActor.stop task.cancel called role=\(role, privacy: .public) agent=\(agentID, privacy: .public)")

        // Wait for the run loop to actually exit, but never block on it past a grace
        // period. `withTaskGroup` is unusable here: it awaits EVERY child at scope exit,
        // so the `await task.value` child hangs the whole group when the run loop is
        // parked in a cancellation-ignoring `await` (a hung MCP/LLM call) — which
        // silently wedged `stop()`, and with it every Escape/Pause/Stop path. The helper
        // abandons the observer if the timer wins, so stop always returns. `isRunning =
        // false` above guarantees the abandoned run loop breaks out as soon as its stuck
        // await finally returns.
        let cleanExit = await Self.completesWithin(seconds: 5) { _ = await task.value }
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
        toolContext.onSecurityAgentProcessingStateChange(false)
        // Swept a second time: the run loop is ABANDONED rather than stopped when the 5s wait
        // expires, and the parallel batch keeps seeding evaluations as earlier ones land, so the
        // pre-cancel sweep above can be overtaken by registrations made while we waited.
        await securityEvaluator?.clearInFlightEvaluations(forAgentInstanceID: id)

        // Drop UI/runtime observer callbacks now that the agent has shut down.
        // Releases the strong references those closures hold against the app
        // layer's view model so a stopped agent can be deinitialized cleanly.
        onTurnRecorded = nil
        onContextChanged = nil
        smithDigestProvider = nil
        drainNotifications = nil
    }

    /// Resets the conversation to `[system prompt]` plus an optional orientation turn —
    /// the user-facing `/clear` (and toolbar trashcan). The orientation is injected as an
    /// unprocessed user turn (no immediate LLM call): it rides along with the next real
    /// input so the agent knows the current task state without re-greeting the user.
    /// Pending/deferred channel messages are deliberately KEPT — undelivered user input
    /// must never be a casualty of a display-adjacent action.
    public func resetConversationHistory(orientation: String?) {
        // Single-writer: a `/clear` that arrives mid-tool-turn (reentrant, while the run loop is
        // parked in a tool `await`) would wipe the in-flight assistant `tool_calls` and orphan the
        // tool results appended when the turn resumes — the same 400 class as the injection splice.
        // Gate on `isProcessingToolTurn`, NOT `lastTurnAwaitsToolResults`: mid-segment (after the
        // first of several results is appended) the last message is a `.tool` result, so the
        // narrower predicate would miss it and let a 2-call turn orphan its tail. Defer to the run
        // loop's next boundary, where the turn is complete. Undelivered channel input is untouched.
        guard !isProcessingToolTurn else {
            pendingResetOrientation = orientation
            pendingResetRequested = true
            return
        }
        performReset(orientation: orientation)
    }

    private func performReset(orientation: String?) {
        pendingPreResetTokens = llmTurns.last?.usage?.inputTokens
        conversationHistory = [.system(configuration.systemPrompt)]
        // Drop queued injections that belonged to the pre-clear context.
        pendingInjectedMessages.removeAll()
        if let orientation, !orientation.isEmpty {
            conversationHistory.append(.user(orientation))
        }
        lastTurnMessageCount = conversationHistory.count
        toolFailureStreaks.removeAll()
        toolFailureWarnedTools.removeAll()
        lastToolCallSignature = nil
        consecutiveIdenticalToolCalls = 0
        continuationNudgesSinceProgress = 0
        pushLiveContext()
    }

    /// Applies a `/clear` that was deferred because it arrived mid-tool-turn. Called by the run
    /// loop at the top of the iteration, where the previous turn is complete.
    private func applyDeferredHistoryReset() {
        guard pendingResetRequested else { return }
        pendingResetRequested = false
        let orientation = pendingResetOrientation
        pendingResetOrientation = nil
        performReset(orientation: orientation)
    }

    /// Result of a `compactConversationHistory` splice attempt.
    public enum CompactionOutcome: Sendable, Equatable {
        /// History was spliced. Carries the message counts before and after.
        case compacted(before: Int, after: Int)
        /// History is already at or below the compaction floor — nothing worth splicing.
        case tooSmall
        /// A tool turn is in flight (the run loop is parked between an assistant `tool_calls`
        /// message and its results). Splicing now could drop the in-flight assistant turn and
        /// orphan the results appended when the loop resumes — the same 400 class the
        /// single-writer invariant exists to prevent. The caller should retry once Smith is idle.
        case toolTurnInFlight
    }

    /// Full before/after message arrays from the most recent compaction, stashed only when
    /// `compactConversationHistory(…, captureSnapshots: true)` requested it (compaction-diff
    /// debugging). Read-and-cleared by `takeLastCompactionSnapshots()`. Nil the rest of the time
    /// so the debug artifact never lingers in a normal run's memory.
    private var lastCompactionSnapshots: (before: [LLMMessage], after: [LLMMessage])?

    /// Splices the conversation down to `[system prompt] + [summary marker] + recent
    /// tail` — the user-facing `/compact`. The summary text is produced by the caller
    /// (runtime → summarizer LLM); this method is a deterministic actor-local splice.
    /// The tail start skips leading `.tool` results so a tool_use/tool_result pair is
    /// never separated (both halves land in the compacted region together).
    ///
    /// When `captureSnapshots` is true, stashes the exact pre- and post-splice histories for
    /// `takeLastCompactionSnapshots()`. Capturing HERE (not from a caller-side snapshot) is what
    /// makes a compaction-diff accurate: the caller's earlier snapshot goes stale across its
    /// summarizer `await`, during which the agent may append more turns.
    public func compactConversationHistory(
        summaryText: String,
        keepingRecentTurns: Int,
        captureSnapshots: Bool = false
    ) -> CompactionOutcome {
        // Single-writer: never splice while the run loop is mid-tool-turn. The caller reaches this
        // after an `await` (its summarizer LLM call), by which point Smith may have started a new
        // tool turn; splicing then could orphan results appended when that turn resumes.
        guard !isProcessingToolTurn else { return .toolTurnInFlight }

        let count = conversationHistory.count
        // system + summary + tail must actually shrink the history to be worth it.
        guard count > keepingRecentTurns + 3 else { return .tooSmall }

        var tailStart = max(1, count - keepingRecentTurns)
        while tailStart < count, conversationHistory[tailStart].role == .tool {
            tailStart += 1
        }

        var compacted: [LLMMessage] = [conversationHistory[0]]
        compacted.append(.user("""
            [Context compacted at the user's request. Summary of the conversation so far:]
            \(summaryText)
            """))
        compacted.append(contentsOf: conversationHistory[tailStart...])
        guard compacted.count < count else { return .tooSmall }

        if captureSnapshots {
            lastCompactionSnapshots = (before: conversationHistory, after: compacted)
        }
        pendingPreResetTokens = llmTurns.last?.usage?.inputTokens
        conversationHistory = compacted
        lastTurnMessageCount = conversationHistory.count
        pushLiveContext()
        return .compacted(before: count, after: compacted.count)
    }

    /// Returns and clears the snapshots stashed by the most recent `captureSnapshots: true`
    /// compaction. Nil if none is pending.
    public func takeLastCompactionSnapshots() -> (before: [LLMMessage], after: [LLMMessage])? {
        defer { lastCompactionSnapshots = nil }
        return lastCompactionSnapshots
    }

    /// Marks the agent stopped WITHOUT cancelling or awaiting run-loop exit. For teardown
    /// paths that can execute inside the agent's own run task (`onSelfTerminate` → runtime
    /// → back here): calling full `stop()` there would await `runTask.value` — the very
    /// task making the call — deadlocking until the 5 s grace timeout on every legitimate
    /// self-terminate, and `task.cancel()` would self-cancel the remaining teardown. The
    /// flag alone is enough: the run loop re-checks `isRunning` at every boundary.
    public func markTerminated() {
        isRunning = false
    }

    /// Liveness lease check — the dead-man's switch against zombie agents. Returns true
    /// while the runtime still tracks this agent as current. On false, quietly stops the
    /// run loop (fault-logged, no channel post): correctness must not depend on `stop()`
    /// having been called on every teardown path — the 2026-07-08 incident had a full
    /// agent generation escape tracking during interleaved restarts and act on a live
    /// user message 35 minutes later. Quiet by design: during a normal `stopAll` the
    /// registries are cleared before agents are awaited, so an in-flight turn can trip
    /// this while being shut down — expected, and `stop()` lands moments later.
    private func verifyLivenessLease() async -> Bool {
        guard isRunning else { return false }
        if await toolContext.isAgentCurrent() { return true }
        let role = configuration.role.rawValue
        let agentID = id.uuidString.prefix(8)
        Self.stopLogger.fault("Zombie tripwire: agent no longer registered with runtime — self-stopping role=\(role, privacy: .public) agent=\(agentID, privacy: .public)")
        isRunning = false
        return false
    }

    /// Injects a channel message into the agent's pending queue.
    ///
    /// Delivery rules:
    /// - Private messages (recipientID != nil) are only delivered to the named recipient.
    /// - Public messages are delivered to everyone except the sender's own role.
    /// - System messages are always delivered.
    public func receiveChannelMessage(_ message: ChannelMessage) {
        // Buffer-origin messages are the UI-echo copies posted by
        // `OrchestrationRuntime.sendUserMessage`. They are delivered to the agent EXCLUSIVELY
        // through the runtime's pending-user-message drain (`acceptChannelMessage`), never the
        // live subscription — otherwise a message posted for the UI while Smith is running
        // would be delivered twice (once here, once by the drain).
        if case .bool(true) = message.metadata?["bufferOrigin"] { return }
        _ = ingestChannelMessage(message)
    }

    /// Delivery path used by `OrchestrationRuntime.drainPendingUserMessages()`. Runs the same
    /// acceptance filters as `receiveChannelMessage` and returns whether the message was
    /// accepted into the pending queue. Returns `false` when the agent is not running (so the
    /// drain leaves the message buffered for the next start) or when the message was already
    /// ingested (idempotent). Unlike the live subscription, this path intentionally delivers
    /// `bufferOrigin` messages — that is the whole point of the drain.
    @discardableResult
    public func acceptChannelMessage(_ message: ChannelMessage) -> Bool {
        ingestChannelMessage(message)
    }

    /// Wires the incorporation callback (see `onInboundUserMessagesIncorporated`). Set by the
    /// runtime on the Smith agent so buffered user messages leave the persisted buffer only
    /// once they've been taken into the conversation.
    public func setOnInboundUserMessagesIncorporated(_ handler: @escaping @Sendable ([UUID]) -> Void) {
        onInboundUserMessagesIncorporated = handler
    }

    /// Shared acceptance logic for both the live subscription and the pending-user-message
    /// drain. Returns `true` only when the message was appended to `pendingChannelMessages`
    /// (i.e. actually accepted for processing), so callers can tie queue removal to acceptance
    /// rather than to a fire-and-forget channel post.
    ///
    /// Delivery rules:
    /// - Private messages (recipientID != nil) are only delivered to the named recipient.
    /// - Public messages are delivered to everyone except the sender's own role.
    @discardableResult
    private func ingestChannelMessage(_ message: ChannelMessage) -> Bool {
        guard isRunning else { return false }

        if let recipientID = message.recipientID {
            // Private message — only the intended recipient receives it.
            guard recipientID == id else { return false }
        } else {
            // Public message — ignore our own role to avoid echo loops.
            if case .agent(let role) = message.sender, role == configuration.role {
                return false
            }
        }

        // Drop UI-only notification messages that no agent needs to process.
        if let kind = message.kind {
            switch kind {
            case .taskCreated, .memorySaved, .memorySearched:
                return false
            default:
                break
            }
        }

        // Drop error messages — they are for the UI only. Feeding them back into
        // agent conversation history wastes tokens and creates a death spiral when
        // the error is a context overflow (each retry adds the error text, growing
        // the context further).
        if case .bool(true) = message.metadata?["isError"] {
            return false
        }

        // Optional per-agent content filter — drops messages that shouldn't trigger a wake.
        if let filter = configuration.messageAcceptFilter, !filter(message) { return false }

        // Idempotency: never append the same channel message twice. Protects against a drain
        // redelivery racing the live subscription and against a post-crash replay.
        if recentIngestedMessageIDs.contains(message.id) { return false }
        recentIngestedMessageIDs.append(message.id)
        if recentIngestedMessageIDs.count > Self.recentIngestedMessageIDCap {
            recentIngestedMessageIDs.removeFirst(recentIngestedMessageIDs.count - Self.recentIngestedMessageIDCap)
        }

        // Track when the user sends a direct message to this agent (for reply_to_user availability)
        if case .user = message.sender, message.recipientID == id {
            lastDirectUserMessageAt = Date()
        }

        // Smith only: a task_update or task_complete from Brown is fresh signal — reset the
        // digest clock so we don't fire an auto-digest seconds later that would just summarize
        // what Smith already saw via this message.
        if configuration.role == .smith,
           let kind = message.kind,
           kind == .taskUpdate || kind == .taskComplete {
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
        return true
    }

    /// Hands over messages Smith addressed to this worker's task before the worker existed —
    /// on the turn AFTER the briefing, never folded into it.
    ///
    /// The distinction is the point. A queued message is a MESSAGE, not task content: it comes
    /// from Smith, it may ask for something, and it should arrive the way any other message from
    /// Smith arrives. Appending it to the briefing instead made it read as part of the task
    /// description — and the briefing's own framing ("instructions about this task") invites a
    /// task-focused worker to discard anything that isn't task work. Delivering it a turn later
    /// also means the worker has already oriented on the task before being asked anything.
    ///
    /// Runs at most once per worker: the drain is read-and-clear, and the flag stops a second
    /// pass even if the drain came back empty. A worker is one task — `performSpawnBrown` is the
    /// only site constructing a Brown — so every task gets a fresh actor and a fresh flag.
    ///
    /// Called at the TOP of the run loop, ahead of `drainPendingInjectedMessages`, so the message
    /// it enqueues reaches context in the SAME iteration; enqueuing after that drain sent the next
    /// LLM turn out without it and delivered only on the turn after. Being ahead of the
    /// `hasUnprocessedInput` idle guard also means an idle worker is woken by the handover
    /// (`appendUserMessage` sets the flag) rather than sleeping through it.
    private func deliverQueuedTaskMessagesIfDue() async {
        guard configuration.role == .brown, !hasDeliveredQueuedTaskMessages else { return }
        // "After the briefing turn" means literally that — at least one LLM turn has completed,
        // so the worker has seen the task before it sees anything said about it.
        guard !llmTurns.isEmpty else { return }
        guard let task = await toolContext.taskStore.taskForAgent(agentID: toolContext.agentID) else { return }

        let queued = await toolContext.taskStore.takePendingWorkerMessages(taskID: task.id)
        hasDeliveredQueuedTaskMessages = true
        guard !queued.isEmpty else { return }

        let formatter = ISO8601DateFormatter()
        let attachments = queued.flatMap(\.attachments)
        let rendered = queued.map {
            Self.orchestratorMessageEnvelope("(sent \(formatter.string(from: $0.queuedAt)), before you started) \($0.text)")
        }
        appendUserMessage(rendered.joined(separator: "\n\n"), attachments: attachments)
    }

    /// How a message from Smith is presented to a worker.
    ///
    /// A worker used to receive `[AGENT Smith]: <text>` — the same shape as every other line of
    /// transcript, saying nothing about who Smith is, that the message is directed AT the worker,
    /// or what the worker may do about it. A message asking for something therefore read as
    /// supervisor commentary and was acted on only when it happened to be task work. Naming the
    /// sender's ROLE and the one channel back makes both explicit at the point of reading.
    ///
    /// Used by the live path (`drainPendingMessages`) and the queued path
    /// (`deliverQueuedTaskMessagesIfDue`) so a message looks identical to the worker whether it
    /// arrived while the worker was running or was held from before it started.
    static func orchestratorMessageEnvelope(_ body: String) -> String {
        "IMPORTANT INFORMATION FROM AGENT SMITH (TASK ORCHESTRATOR) - IF YOU NEED HELP, CALL `request_help`: \(body)"
    }

    /// Whether the agent is currently running.
    public var running: Bool {
        isRunning
    }

    /// The agent's LIVE tool names — the registry's currently-available set (security-scoped,
    /// forced-lifecycle, plus present MCP tools), NOT the static configured roster. A scoped
    /// worker's usable set changes at runtime, so the frozen `configuration.toolNames` would
    /// misreport it (e.g. showing `bash` to a worker that was never granted it).
    ///
    /// Before the first refresh, `activeTools` is still the unscoped construction placeholder, so
    /// reporting it would leak the ungranted roster; in that window a scoped agent reports its
    /// approved scoped names and an unscoped agent (Smith) its configured roster. Never empty.
    public var toolNames: [String] {
        if hasRefreshedActiveTools {
            return activeTools.map(\.name)
        }
        return toolScopingEnabled ? approvedToolNames.sorted() : configuration.toolNames
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
            // Unscoped agents (Smith/Security Agent): every candidate approved → activeTools == all
            // candidates, identical to the pre-registry behavior.
            toolRegistry.rebuild(candidates: candidates, defaultApproved: true)
            activeTools = toolRegistry.availableTools()
            hasRefreshedActiveTools = true
            publishActiveToolNamesIfChanged()
            return
        }

        // Scoped agent (Brown): candidates start disabled; only the security-approved set and
        // forced lifecycle tools are available.
        toolRegistry.rebuild(candidates: candidates, defaultApproved: false)

        // Pre-flight scoping ON: re-scope from scratch if the candidate set changed (content
        // fingerprint, so a silent redefinition counts). The first refresh just records the
        // fingerprint — the runtime already scoped this set before the worker started.
        // Pre-flight scoping OFF: the base approved set is simply every current candidate.
        let candidateNames = Set(candidates.map(\.name))
        let fingerprint = toolRegistry.candidateFingerprint
        if preflightScopingActive {
            if let last = lastScopedFingerprint, last != fingerprint {
                await rescopeToolsStateless()
            }
        } else {
            approvedToolNames = candidateNames
        }
        lastScopedFingerprint = fingerprint

        // Layer global policy + per-task overrides on top of the base verdict, then force lifecycle.
        let resolved = resolveEffectiveApproved(base: approvedToolNames, candidates: candidateNames)
        toolRegistry.applyApproval(approvedNames: resolved)
        applyForcedLifecycleFlags()
        activeTools = toolRegistry.availableTools()
        hasRefreshedActiveTools = true
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
    /// acknowledgement itself is a runtime action (no tool), so once it has happened the
    /// post-ack tools `task_update` / `task_complete` / `request_help` become available.
    /// `reply_to_user` is forced throughout but remains gated by its own `isAvailable(in:)`
    /// context check (user-has-messaged) at the definition/dispatch sites. Forcing is a
    /// deliberate security bypass applied ONLY to these trusted built-ins.
    private func applyForcedLifecycleFlags() {
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
        // Light the Security Agent card while it re-scopes (a real Security Agent LLM call).
        // `defer`-paired for the reason the deleted per-call brackets were: a stranded "true" here
        // shows the gatekeeper busy forever, and this is now the ONLY user of this signal.
        toolContext.onSecurityAgentProcessingStateChange(true)
        defer { toolContext.onSecurityAgentProcessingStateChange(false) }
        let result = await evaluator.scopeTools(
            candidateTools: toolRegistry.candidateTools,
            taskTitle: task.title,
            taskID: task.id.uuidString,
            taskDescription: task.renderedDescriptionWithTemplateInputs()
        )
        guard result.succeeded else { return }
        // Only act when the *approved* set actually changed. A candidate-set change that
        // leaves Brown's usable tools identical (e.g. a new MCP tool that Security Agent blocks) must
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
            // Liveness lease at every loop tick, BEFORE wake-firing and message drains: an
            // orphaned agent must not fire scheduled wakes (which can drive restartForNewTask
            // on the live runtime) any more than it may run LLM turns.
            guard await verifyLivenessLease() else { break }

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

            // A `/clear` that arrived while a tool turn was open was deferred to here (the turn
            // is now complete), so it can't orphan tool results.
            applyDeferredHistoryReset()
            // Queue the handover BEFORE the injected-message drain below, so it lands in this
            // iteration's context rather than the next one. Enqueuing after the drain meant the
            // very next LLM turn went out WITHOUT the message and only the turn after that saw
            // it — a wasted turn, and delivery one turn later than "the turn after the briefing".
            await deliverQueuedTaskMessagesIfDue()
            // Injected messages first: a spawn briefing enqueued before `start()` must precede
            // any channel message that raced in, so it stays Brown's first context entry.
            drainPendingInjectedMessages()
            drainPendingMessages()
            await drainQueuedNotifications()
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

            // First-turn task acknowledgement: run the mandatory acknowledgement for its side
            // effects (task → running, ack counter, Smith notification) WITHOUT paying for an
            // LLM round-trip, and WITHOUT it being a callable tool. It is a runtime action the
            // app performs, not a call the model made — so nothing is recorded in the
            // conversation (appending a fabricated assistant `functionCall` both wastes context
            // tokens and produces a history that providers like Gemini 2.5 reject — their
            // thinking mode requires a `thought_signature` on every replayed function call, and
            // a call the model never made has none). Brown starts already-acknowledged
            // (`taskAcknowledged`); its continuation context comes from the briefing, and pruning
            // already rebuilds Brown this way — [system, instruction] with no ack turn.
            if acknowledgesTaskOnFirstTurn {
                acknowledgesTaskOnFirstTurn = false
                await performTaskAcknowledgement()
                if configuration.role == .brown {
                    lastTaskCommunicationAt = Date()
                    toolCallsSinceTaskCommunication = 0
                    brownSilenceNudgeArmed = true
                    taskAcknowledged = true
                    continuationNudgesSinceProgress = 0
                }
                pushLiveContext()
                continue
            }

            do {
                let activeTasks = await toolContext.taskStore.allTasks().filter { $0.disposition == .active }
                let hasRunnableTasks = activeTasks.contains { $0.status.isRunnable }
                // Gate on `.awaitingHelp` (a Brown blocked on a help request) only — NOT `.awaitingReview`,
                // which is now a user-owned validator-error park with its worker already gone; letting it
                // gate would disable notify_brown / provide_help across unrelated running workers.
                let hasAwaitingReview = activeTasks.contains { $0.status == .awaitingHelp }
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

                // Liveness lease: don't burn an LLM call (or act on its result) if the
                // runtime has already moved on without this agent.
                guard await verifyLivenessLease() else { break }

                let messagesForLLM = conversationHistory

                let llmStartTime = Date()
                // Clamp this turn's output cap to any limit we've learned from a prior
                // rejection. Passed as a per-call override so we don't have to rebuild the
                // provider mid-run; nil leaves the provider's configured cap untouched.
                let outputCapOverride = learnedMaxOutputCeiling.map {
                    min(configuration.llmConfig.maxTokens, $0)
                }
                let response = try await provider.send(
                    messages: messagesForLLM,
                    tools: toolDefinitions,
                    overrides: LLMCallOverrides(maxOutputTokens: outputCapOverride)
                )
                let llmLatencyMs = Int(Date().timeIntervalSince(llmStartTime) * 1000)
                guard isRunning else { break }
                // Re-check the lease after the (possibly minutes-long) LLM call, BEFORE any
                // tool executes. This is the exact window the 2026-07-08 zombie acted in.
                guard await verifyLivenessLease() else { break }

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
                // Brown is bound to its own task via assigneeIDs; that's the attribution.
                // Smith is not — its cost is attributed AFTER handleResponse to whichever task
                // this turn's tool calls acted on (see `smithTurnTargetTaskID`), so that Smith's
                // supervision of a specific task lands on that task rather than a status-based
                // guess. That derivation needs the id of any task CREATED this turn, so snapshot
                // the existing ids first — but only when the turn actually creates one.
                let brownTaskAtCallTime = configuration.role == .smith
                    ? nil
                    : await toolContext.taskStore.taskForAgent(agentID: id)
                let preCreateTaskIDs: Set<UUID>? = (configuration.role == .smith
                    && response.toolCalls.contains { $0.name == "create_task" })
                    ? Set(await toolContext.taskStore.allTasks().map(\.id))
                    : nil

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

                // Attribute this turn's cost. Brown → its bound task. Smith → the task its tool
                // calls acted on this turn (nil when it did none — that's genuine orchestration
                // overhead, bucketed separately in the spending dashboard).
                let recordTaskID: UUID?
                if configuration.role == .smith {
                    recordTaskID = await smithTurnTargetTaskID(response: response, preCreateTaskIDs: preCreateTaskIDs)
                } else {
                    recordTaskID = brownTaskAtCallTime?.id
                }

                // Persist usage record for analytics — with tool execution stats now
                // folded in from handleResponse.
                if let usageStore {
                    await UsageRecorder.record(
                        response: response,
                        context: LLMCallContext(
                            agentRole: configuration.role,
                            taskID: recordTaskID,
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

                // Max output-token limit exceeded: the backend rejected the request because
                // our configured output cap is larger than the model actually allows, and it
                // told us the real ceiling. Learn it, persist it as a catalog override (so
                // future provider builds clamp to it and the UI shows it), and retry this turn
                // immediately with the clamped cap — backoff won't help a fixed config limit.
                if let reportedLimit = (error as? LLMProviderError)?.reportedMaxOutputTokenLimit {
                    let priorCeiling = learnedMaxOutputCeiling ?? configuration.llmConfig.maxTokens
                    // Only treat as recoverable when this actually tightens the cap; otherwise
                    // we'd loop forever if the backend keeps rejecting even at the stated limit.
                    if reportedLimit < priorCeiling {
                        learnedMaxOutputCeiling = reportedLimit
                        toolContext.onLearnedModelOutputLimit(
                            configuration.llmConfig.providerID,
                            configuration.llmConfig.model,
                            reportedLimit
                        )
                        consecutiveErrors = 0
                        await toolContext.post(ChannelMessage(
                            sender: .system,
                            content: "\(configuration.role.displayName): model '\(configuration.llmConfig.model)' caps output at \(reportedLimit) tokens — clamped and retrying. Saved as a model override."
                        ))
                        continue  // Retry immediately with the clamped output cap.
                    }
                }

                // Log unhandled 400 errors so we can detect patterns that need specific handling.
                Self.logUnhandled400(error)

                consecutiveErrors += 1
                consecutiveContextOverflows = 0  // Reset overflow counter on non-overflow errors

                // Pull the HTTP status and any server-supplied Retry-After off the error. Unwrap
                // the optional to a concrete LLMProviderError first so the case-match is
                // unambiguous (matching an enum case against an optional is subtle).
                var httpStatus: Int? = nil
                if let providerError = error as? LLMProviderError,
                   case .httpError(let statusCode, _, _, _) = providerError {
                    httpStatus = statusCode
                }

                // Shared classification — the same call every other LLM caller makes. It also
                // recovers a delay stated in the error BODY rather than the Retry-After header
                // (Gemini/Google use a google.rpc.RetryInfo `"retryDelay": "34s"`).
                let classification = LLMRetryPolicy.classify(error)
                let serverRetryAfter: TimeInterval?
                if case .transient(let retryAfter) = classification { serverRetryAfter = retryAfter } else { serverRetryAfter = nil }

                // Surface persistent HTTP 4xx (config/payload problems retrying won't fix — bad
                // API key, unsupported parameter, DeepSeek's reasoning_content replay demand) and
                // rate limits on the first occurrence: the former never recovers, the latter can
                // impose a long wait that should read as deliberate, not a silent hang. Transient
                // classes with NO server-directed wait (a brief 5xx/network blip) fall back to the
                // >=5-consecutive gate so they don't spam the transcript — but a server-supplied
                // Retry-After on ANY status (a 503/408 asking for a long wait) is surfaced on the
                // first occurrence too, so the honored delay never reads as a silent hang. See the
                // `serverRetryAfter` clause in `shouldSurfaceNow`.
                let isPersistentClientError = classification == .permanent
                let isRateLimited = httpStatus == 429

                // Honor a server-supplied Retry-After (e.g. on a 429) over our own guess: the
                // server knows when its window resets. Floored at 1s so a `Retry-After: 0`
                // can't spin a tight retry loop, and honored with NO upper cap — a multi-hour
                // limit means we wait multiple hours, which is the point (a suspiciously long
                // one is flagged below). Otherwise the shared exponential backoff.
                let backoff = LLMRetryPolicy.delay(attempt: consecutiveErrors, retryAfter: serverRetryAfter)

                let shouldSurfaceNow = consecutiveErrors >= 5
                    || (isPersistentClientError && consecutiveErrors == 1)
                    || (isRateLimited && consecutiveErrors == 1)
                    // Any server-directed wait (e.g. 503/408 + Retry-After), so honoring a long
                    // delay is announced and the ridiculous-wait flag is reachable — never silent.
                    || (serverRetryAfter != nil && consecutiveErrors == 1)

                if shouldSurfaceNow {
                    // A 402 is out of credits / a billing block, not a transient fault. The generic
                    // "error (n/50): HTTP 402: {raw json}" frame buries the one thing the user needs
                    // to know, so say it plainly.
                    var content = httpStatus == 402
                        ? Self.outOfCreditsMessage(role: configuration.role, model: configuration.llmConfig.model)
                        : "Agent \(configuration.role.displayName) error (\(consecutiveErrors)/\(Self.maxConsecutiveErrors)): \(error.localizedDescription)"
                    // Only claim a retry when one is actually coming — the stop below fires at
                    // the cap, and immediately for a permanent error. State the wait both
                    // relatively and as a wall-clock time so a long wait reads clearly, and flag
                    // a suspiciously long server-directed delay.
                    if !isPersistentClientError, consecutiveErrors < Self.maxConsecutiveErrors {
                        let retryAt = Date().addingTimeInterval(backoff)
                        content += " — retrying in \(Self.formatRetryDelay(backoff)) (at \(Self.formatRetryClock(retryAt)))"
                        if let serverRetryAfter {
                            if serverRetryAfter >= Self.ridiculousRetryAfterSeconds {
                                content += "; server Retry-After asked for an unusually long wait — honoring it, but you may want to check the provider or switch this agent's model"
                            } else {
                                content += ", per server Retry-After"
                            }
                        }
                    }
                    await toolContext.post(ChannelMessage(
                        sender: .system,
                        content: content,
                        metadata: ["isError": .bool(true), "agentRole": .string(configuration.role.rawValue)]
                    ))
                }

                // A permanent failure — bad key, exhausted credits, unknown model, malformed
                // request — cannot be retried into success. Stop now with the real reason.
                // This classification used to be computed and then ignored for retry purposes:
                // it gated only the log message, so an out-of-credits 402 was retried 50 times
                // across ~90 minutes while the account sat empty. Telling the user promptly and
                // stopping is strictly more useful than continuing to hammer a billing block.
                if isPersistentClientError {
                    await toolContext.post(ChannelMessage(
                        sender: .system,
                        content: "Agent \(configuration.role.displayName) stopped — this error cannot be resolved by retrying: \(error.localizedDescription)",
                        metadata: ["isError": .bool(true), "agentRole": .string(configuration.role.rawValue)]
                    ))
                    isRunning = false
                    break
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
        // Mark the whole append span in-flight so a reentrant `/clear` or `/compact` (which arrive
        // as external actor calls at any of this method's `await` suspension points) defers rather
        // than wiping/splicing history and orphaning results appended when this method resumes.
        // Sequential run loop → never nested → a plain bool is correct. The `defer` clears it on
        // every exit path (normal, thrown, self-terminate).
        isProcessingToolTurn = true
        defer { isProcessingToolTurn = false }

        // The model can PARROT the synthetic empty-turn marker from its own history back as literal
        // text. Such a response is "nothing to say": never post it, and treat it as empty below.
        // Trim-tolerant so a whitespace-padded echo is caught too.
        let isEmptyMarkerEcho = response.text?.trimmingCharacters(in: .whitespacesAndNewlines) == Self.emptyResponseTurnMarker

        // Post text to channel unless this agent's raw LLM output is suppressed.
        // Suppressed text is still stored in conversationHistory and visible in the inspector.
        if let text = response.text, !text.isEmpty,
           !isEmptyMarkerEcho,
           !configuration.suppressesRawTextToChannel {
            await toolContext.post(ChannelMessage(
                sender: .agent(configuration.role),
                content: text,
                metadata: channelTaskTitle.map { ["senderTaskTitle": .string($0)] }
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
           !isEmptyMarkerEcho,
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

            // A parroted empty-turn marker (see `isEmptyMarkerEcho`) is semantically an empty
            // response — treat it as empty so it isn't recorded as a real text turn (and re-appended
            // as content that primes the echo further).
            let hasText = (response.text.map { !$0.isEmpty } ?? false) && !isEmptyMarkerEcho

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
                        - Send Brown instructions → call `notify_brown`
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
                conversationHistory.append(.assistant(from: LLMResponse(text: Self.emptyResponseTurnMarker)))
                pushLiveContext()
                Self.agentLogger.debug(
                    "Agent \(self.configuration.role.displayName, privacy: .public) returned an empty response; closing turn with synthetic marker."
                )
            }

            // Circuit breaker: if the model keeps returning text without tool calls,
            // it's likely degenerate (repetition loop or unable to use tools). Terminate.
            if consecutiveTextOnlyResponses >= Self.textOnlyResponseLimit(for: configuration.role) {
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
            // so it keeps working, up to `maxContinuationNudgesSinceProgress` of them without
            // forward progress. Past that the worker is narrating in place, and the honest
            // answer to "nothing left to do" is to idle, not to be nudged again.
            //
            // A PARKED worker is never nudged, no matter how it got woken. `awaitingTaskReview`
            // means the work is submitted and control belongs to the validator; the run loop
            // hands a parked Brown an EMPTY tool list (see the `toolDefinitions` override), so
            // "Continue. Use your tools to make progress" asks for something it structurally
            // cannot do — every such turn is guaranteed to come back as text and buy nothing.
            // Idling is the correct response, and it costs one wasted turn instead of ten.
            if configuration.role == .brown && hasText && !awaitingTaskReview {
                continuationNudgesSinceProgress += 1
                if continuationNudgesSinceProgress >= Self.maxContinuationNudgesSinceProgress {
                    await toolContext.post(ChannelMessage(
                        sender: .system,
                        content: "Agent \(configuration.role.displayName) has been nudged to continue \(continuationNudgesSinceProgress) times without making progress. Going idle — the agent will resume when new input arrives.",
                        metadata: ["isWarning": .bool(true), "agentRole": .string(configuration.role.rawValue)]
                    ))
                    Self.agentLogger.warning(
                        "Agent \(self.configuration.role.displayName, privacy: .public) hit the continuation-nudge cap (\(self.continuationNudgesSinceProgress, privacy: .public)) without progress — idling."
                    )
                    continuationNudgesSinceProgress = 0
                    hasUnprocessedInput = false
                    return
                }
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
            // Clear the Gemini continuation (it would replay the full functionCall
            // set verbatim) but keep the Anthropic thinking blocks (still valid).
            // Rebuilding from only `anthropicThinkingBlocks` drops both Gemini fields;
            // when there were none to begin with the rebuilt continuation is identical.
            if let cont = assistantTurn.continuation {
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
        // Set when a tool's declared effect restarts the runtime; the loop must then stop.
        var triggeredRuntimeRestart = false

        // Segment calls into contiguous runs of lifecycle vs approval-needing.
        // Each segment completes before the next starts, preserving ordering.
        // e.g. [task_update, file_read x10, task_complete] becomes:
        //   segment 0: lifecycle  [task_update]           → sequential
        //   segment 1: approval   [file_read x10]         → parallel
        //   segment 2: lifecycle  [task_complete]          → sequential
        struct CallSegment {
            let isLifecycle: Bool
            var calls: [LLMToolCall]
        }

        var segments: [CallSegment] = []
        for call in callsToExecute {
            let isLifecycle = Self.taskLifecycleTools.contains(call.name)
            if let last = segments.last, last.isLifecycle == isLifecycle {
                segments[segments.count - 1].calls.append(call)
            } else {
                segments.append(CallSegment(isLifecycle: isLifecycle, calls: [call]))
            }
        }

        var executedCallIDs = Set<String>()

        toolSegments: for segment in segments {
            guard isRunning else { break }

            if segment.isLifecycle {
                // --- Lifecycle segment: execute sequentially, one at a time ---
                // These route through the Security Agent like everything else. They used to skip
                // it entirely ("no approval"), which was the last hole in the chokepoint — and the
                // quietest one, since a bypassed call also posted no tool_request and so never
                // appeared in the transcript as a call at all. `taskLifecycleTools` are pre-cleared
                // in `autoApprovedToolsByRole`, so routing them costs a recorded auto-approval
                // rather than an LLM round-trip; the sequencing and the `task_complete` break
                // below are unchanged, because a lifecycle segment still runs its calls in order.
                for call in segment.calls {
                    guard isRunning else { break }
                    let result: String
                    let succeeded: Bool
                    let executedTool = activeTools.first(where: { $0.name == call.name })
                    if let tool = executedTool {
                        if let rejection = await rejectionResultIfUnavailable(call, tool: tool) {
                            result = rejection
                            succeeded = false
                        } else {
                            let outcome = await executeWithApproval(call, tool: tool)
                            result = outcome.result
                            succeeded = outcome.succeeded
                        }
                    } else {
                        result = "Unknown tool: \(call.name)"
                        succeeded = false
                        await toolContext.setToolExecutionStatus(call.id, false)
                        recordToolOutcome(name: call.name, succeeded: false)
                    }
                    executedCallIDs.insert(call.id)
                    updatePostCallFlags(call: call, tool: executedTool, succeeded: succeeded, sentMessage: &sentMessage, calledTaskComplete: &calledTaskComplete, triggeredRuntimeRestart: &triggeredRuntimeRestart)
                    conversationHistory.append(.toolResult(Self.capToolResult(result), callID: call.id))
                    pushLiveContext()
                    if calledTaskComplete { break toolSegments }
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
                // Same justification context the sequential path supplies. Computed here, once,
                // because it is actor-isolated and the evaluations below run in a task group.
                // Always nil in practice today — this path requires `requiresToolApproval`, which
                // only Brown sets, and Brown always has a running task — but the two paths must
                // not disagree about what the evaluator is told, or opening this path to Smith
                // later would quietly drop the context behind exactly its egress calls.
                let agentContext = currentTask == nil ? recentUserMessagesForEvaluation() : nil

                var entries: [ParallelEntry] = []
                // Calls rejected before Security Agent evaluation (unavailable for role / unknown tool).
                // Tracked alongside evaluated results so we can keep tool_result ordering aligned
                // with the assistant message's tool_use ordering.
                var preRejections: [(batchIndex: Int, callID: String, toolName: String, result: String)] = []
                for (batchIndex, call) in segment.calls.enumerated() {
                    guard isRunning else { break }
                    guard let tool = activeTools.first(where: { $0.name == call.name }) else {
                        // Unknown / hallucinated tool: return a real error to the model, matching the
                        // sequential path. Previously this bare `continue` left the call to the generic
                        // "cancelled (agent stopped)" backfill, which implies a transient shutdown and
                        // misleads the model into retrying a tool that doesn't exist.
                        preRejections.append((batchIndex: batchIndex, callID: call.id, toolName: call.name, result: "Unknown tool: \(call.name)"))
                        continue
                    }
                    if let rejection = await rejectionResultIfUnavailable(call, tool: tool) {
                        preRejections.append((batchIndex: batchIndex, callID: call.id, toolName: call.name, result: rejection))
                        continue
                    }
                    let siblings = approvalSummaries.enumerated()
                        .compactMap { $0.offset != batchIndex ? $0.element : nil }
                        .joined(separator: "\n")
                    entries.append(ParallelEntry(
                        batchIndex: batchIndex, call: call, tool: tool, siblings: siblings,
                        taskTitle: currentTask?.title, taskID: currentTask?.id.uuidString,
                        taskDescription: currentTask?.renderedDescriptionWithTemplateInputs()
                    ))
                    await postToolRequestToChannel(call, tool: tool, task: currentTask, parallelIndex: batchIndex, parallelCount: parallelCount, siblingCallSummaries: approvalSummaries.enumerated().compactMap { $0.offset != batchIndex ? $0.element : nil })
                }

                struct ParallelToolResult: Sendable {
                    let batchIndex: Int
                    let callID: String
                    let toolName: String
                    let result: String
                    /// Whether the call executed successfully (false for denials, failures,
                    /// timeouts). Carried out of the @Sendable evaluation closure so the merge
                    /// loop — back on the actor — can feed `recordToolOutcome`; without this,
                    /// Brown (the only role with per-call approval) escaped the failure-streak
                    /// breaker on every multi-call segment (fresh-Opus review finding).
                    let succeeded: Bool
                    /// Wall-clock ms spent inside `tool.execute(...)`. Zero for denied
                    /// calls (which skip execute entirely). Does NOT include the Security Agent
                    /// security-evaluation LLM call — that gets its own UsageRecord.
                    let executionMs: Int
                }

                let role = configuration.role
                let roleName = configuration.role.displayName
                let ctx = toolContext
                let sanctionedDirectories = [toolContext.taskEvidenceDirectory, toolContext.taskTemporaryDirectory].compactMap { $0?.path }
                let taskTitleForChannel = channelTaskTitle
                let agentIDPrefix = String(id.uuidString.prefix(8))

                let agentInstanceID = id

                // Evaluate + execute a single entry. Extracted so the sliding
                // window doesn't duplicate the task body.
                let evaluateEntry: @Sendable (ParallelEntry) async -> ParallelToolResult = { entry in
                    let toolDef = entry.tool.definition(for: role)
                    let toolParamDefs = AgentActor.formatToolParameterDefinitions(toolDef.parameters)

                    // Same as the sequential path: the evaluator registers each call itself, so
                    // there is no batch-wide counter to keep edge-triggered here any more. Each
                    // call appears and disappears individually, which is also what lets a row say
                    // WHICH of a parallel batch is under review.
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
                            callerRole: role,
                            toolGroupDescription: SecurityEvaluator.toolGroupDescription(for: entry.tool),
                            agentContext: agentContext,
                            sanctionedDirectories: sanctionedDirectories,
                            toolCallID: entry.call.id,
                            evaluatingForAgentID: agentInstanceID
                        )

                    await AgentActor.postSecurityReviewToChannel(
                        disposition: disposition, callID: entry.call.id,
                        agentInstanceID: agentInstanceID, roleName: roleName,
                        agentRoleValue: role.rawValue, post: { await ctx.post($0) }
                    )

                    let result: String
                    var executionMs = 0
                    var succeeded = false
                    if disposition.approved {
                        let outcome = await AgentActor.runToolWithTimeout(entry.call, tool: entry.tool, context: ctx) { name, seconds in
                            AgentActor.stopLogger.warning("Tool '\(name, privacy: .public)' execution exceeded \(seconds, privacy: .public)s — cancelled (agent=\(agentIDPrefix, privacy: .public))")
                        }
                        result = outcome.result
                        executionMs = outcome.executionMs
                        succeeded = outcome.succeeded
                        // Mirror the sequential `directExecute` path: record the outcome on the
                        // shared tracker so Security Agent's recent-tool-calls context shows whether this
                        // approved call actually succeeded or failed. Without this, parallel
                        // batches of approval-needing calls (e.g., file_read fan-out) leave
                        // every entry tagged "[executed: not yet recorded]" and a legitimate
                        // retry-after-failure looks like a duplicate operation. A timeout-induced
                        // cancellation is also recorded as a failure.
                        await ctx.setToolExecutionStatus(entry.call.id, outcome.succeeded)
                        await AgentActor.postToolOutputToChannel(
                            result: result, call: entry.call, role: role, context: ctx,
                            taskTitle: taskTitleForChannel, executionMs: executionMs
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
                        toolName: entry.call.name, result: result,
                        succeeded: succeeded, executionMs: executionMs
                    )
                }

                // Sliding window: at most maxConcurrentEvaluations Security Agent calls in flight.
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
                    let toolName: String
                    let result: String
                    let succeeded: Bool
                    let executionMs: Int
                }
                var merged: [MergedEntry] = []
                for r in results {
                    merged.append(MergedEntry(batchIndex: r.batchIndex, callID: r.callID, toolName: r.toolName, result: r.result, succeeded: r.succeeded, executionMs: r.executionMs))
                }
                for r in preRejections {
                    merged.append(MergedEntry(batchIndex: r.batchIndex, callID: r.callID, toolName: r.toolName, result: r.result, succeeded: false, executionMs: 0))
                }
                for r in merged.sorted(by: { $0.batchIndex < $1.batchIndex }) {
                    executedCallIDs.insert(r.callID)
                    turnToolExecutionMs += r.executionMs
                    turnToolResultChars += r.result.count
                    recordToolOutcome(name: r.toolName, succeeded: r.succeeded)
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
                    // Carry the tool's real outcome, exactly as the lifecycle branch does. Today
                    // no park-triggering tool reaches this branch (they are all in
                    // `taskLifecycleTools`), but hardcoding `false` here would silently break
                    // the handoff park the moment one of them stopped being a lifecycle tool.
                    let succeeded: Bool
                    let executedTool = activeTools.first(where: { $0.name == call.name })
                    if let tool = executedTool {
                        if let rejection = await rejectionResultIfUnavailable(call, tool: tool) {
                            result = rejection
                            succeeded = false
                        } else {
                            // No unevaluated branch: every call goes through the Security Agent.
                            let siblings = segment.calls.count > 1
                                ? approvalSummaries.enumerated().compactMap { $0.offset != batchIndex ? $0.element : nil }
                                : []
                            let outcome = await executeWithApproval(call, tool: tool, parallelIndex: batchIndex, parallelCount: segment.calls.count, siblingCallSummaries: siblings)
                            result = outcome.result
                            succeeded = outcome.succeeded
                        }
                    } else {
                        result = "Unknown tool: \(call.name)"
                        succeeded = false
                        await toolContext.setToolExecutionStatus(call.id, false)
                        recordToolOutcome(name: call.name, succeeded: false)
                    }
                    executedCallIDs.insert(call.id)
                    updatePostCallFlags(call: call, tool: executedTool, succeeded: succeeded, sentMessage: &sentMessage, calledTaskComplete: &calledTaskComplete, triggeredRuntimeRestart: &triggeredRuntimeRestart)
                    conversationHistory.append(.toolResult(Self.capToolResult(result), callID: call.id))
                    pushLiveContext()
                    // Mirrors the lifecycle branch: once control has been handed off, nothing
                    // further in this turn should run. A no-op today (the lifecycle branch
                    // already breaks when it sets the flag, so it cannot arrive here already
                    // set) — it is here so the invariant holds wherever the flag gets set.
                    if calledTaskComplete { break toolSegments }
                }
            }
        }

        // Safety: if any segment loop exited early (stop() during await), append placeholder
        // results for remaining tool_calls to maintain the API invariant.
        var appendedPlaceholders = false
        for call in callsToExecute where !executedCallIDs.contains(call.id) {
            let cancellationReason = calledTaskComplete
                ? "Tool not executed because the preceding lifecycle handoff parked the agent."
                : "Tool execution cancelled (agent stopped)"
            conversationHistory.append(.toolResult(cancellationReason, callID: call.id))
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
                // A call that differs from the last one is the tool-side definition of forward
                // progress. Repeating the SAME call deliberately does not clear the nudge budget
                // — narrate-then-re-read-the-same-thing is the loop shape this bounds.
                continuationNudgesSinceProgress = 0
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

        // --- Per-tool failure-streak circuit breaker ---
        // Catches the loop the identical-call breaker can't: a tool failing over and over
        // with varying arguments and narration/successful other tools interleaved. Warn
        // once mid-streak so the model can change course; if it still can't land a single
        // success, break the loop the same way as above (idle until new input).
        if let worst = toolFailureStreaks.max(by: { $0.value < $1.value }) {
            if worst.value >= Self.toolFailureStreakStopThreshold {
                await toolContext.post(ChannelMessage(
                    sender: .system,
                    content: "Agent \(configuration.role.displayName)'s calls to \(worst.key) have failed \(worst.value) times without a single success. Breaking loop — agent will idle until new input arrives.",
                    metadata: ["isError": .bool(true)]
                ))
                toolFailureStreaks[worst.key] = nil
                toolFailureWarnedTools.remove(worst.key)
                hasUnprocessedInput = false
                return
            }
            if worst.value >= Self.toolFailureStreakWarnThreshold, !toolFailureWarnedTools.contains(worst.key) {
                toolFailureWarnedTools.insert(worst.key)
                conversationHistory.append(.user("""
                    [System] Your calls to `\(worst.key)` have now failed \(worst.value) times without a single success. \
                    STOP retrying the same approach. Re-read the most recent error text carefully and either change \
                    your approach or report the blocker\(configuration.role == .brown ? " via request_help" : ""). \
                    After \(Self.toolFailureStreakStopThreshold) failures without a success you will be stopped.
                    """))
                pushLiveContext()
            }
        }

        // run_task fires a detached restart — stop the run loop so we don't
        // race the restart and accidentally trigger it a second time.
        if triggeredRuntimeRestart {
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
    /// Used for sequential tool calls that require approval. Returns the tool's outcome alongside
    /// its result — a denial is a failure, so post-call control flow never reads it as success.
    private func executeWithApproval(_ call: LLMToolCall, tool: any AgentTool, parallelIndex: Int = 0, parallelCount: Int = 1, siblingCallSummaries: [String] = []) async -> (result: String, succeeded: Bool) {
        let toolDef = tool.definition(for: configuration.role)
        let toolParameterDefs = Self.formatToolParameterDefinitions(toolDef.parameters)

        // Look up the current running task for context.
        let allTasks = await toolContext.taskStore.allTasks()
        let currentTask = allTasks.first { $0.assigneeIDs.contains(toolContext.agentID) && $0.status == .running }

        // Post tool_request to channel for UI visibility.
        await postToolRequestToChannel(call, tool: tool, task: currentTask, parallelIndex: parallelIndex, parallelCount: parallelCount, siblingCallSummaries: siblingCallSummaries)

        guard let evaluator = securityEvaluator else {
            // Every tool call routes here now, so this is a reachable runtime state rather than a
            // programmer error, and it must DENY rather than trap: a crash on a missing evaluator
            // would be a worse outcome than a refused tool call, and an `assertionFailure` here
            // would take the process down in debug for a condition we already handle correctly.
            Self.agentLogger.error("Tool '\(call.name, privacy: .public)' denied — no SecurityEvaluator configured. Nothing runs unreviewed.")
            return ("Tool execution denied: No security evaluator is configured. Tool cannot be executed without approval.", false)
        }

        let siblings = siblingCallSummaries.isEmpty ? nil : siblingCallSummaries.joined(separator: "\n")
        // With no task to describe (Smith's egress calls), give the Security Agent the recent user
        // request(s) as the justification context instead — that is what the call must be consistent with.
        let agentContext = currentTask == nil ? recentUserMessagesForEvaluation() : nil
        // Smith's read-only filesystem reads are auto-approved by the evaluator (no LLM), but still
        // routed through it so they're visible and centrally gated. Brown is fully evaluated.
        // The worker's task-scoped working dirs — writes here are expected, not suspicious.
        let sanctionedDirectories = [toolContext.taskEvidenceDirectory, toolContext.taskTemporaryDirectory].compactMap { $0?.path }
        // No "security is busy" signal is raised here. This scope cannot tell a real LLM
        // evaluation from an auto-approved fast path, so bracketing `evaluate()` from outside
        // produced a second, wider answer to a question the evaluator was already answering — and
        // the two disagreed on screen. `SecurityEvaluator` registers the call itself; passing our
        // id is what lets a reader work out WHICH agent is blocked.
        let disposition = await evaluator.evaluate(
                toolName: call.name,
                toolParams: call.arguments,
                toolDescription: toolDef.description,
                toolParameterDefs: toolParameterDefs,
                taskTitle: currentTask?.title,
                taskID: currentTask?.id.uuidString,
                taskDescription: currentTask?.renderedDescriptionWithTemplateInputs(),
                siblingCalls: siblings,
                agentRoleName: configuration.role.displayName,
                callerRole: configuration.role,
                toolGroupDescription: SecurityEvaluator.toolGroupDescription(for: tool),
                agentContext: agentContext,
                sanctionedDirectories: sanctionedDirectories,
                toolCallID: call.id,
                evaluatingForAgentID: id
            )

        // Post approval/denial status.
        await Self.postSecurityReviewToChannel(
            disposition: disposition, callID: call.id, agentInstanceID: id,
            roleName: configuration.role.displayName,
            agentRoleValue: configuration.role.rawValue, post: { await toolContext.post($0) }
        )

        if disposition.approved {
            let outcome = await directExecute(call, tool: tool)
            await Self.postToolOutputToChannel(
                result: outcome.result, call: call, role: configuration.role, context: toolContext,
                taskTitle: channelTaskTitle, executionMs: outcome.executionMs
            )
            return (outcome.result, outcome.succeeded)
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
            recordToolOutcome(name: call.name, succeeded: false)
            return ("Tool execution denied: \(disposition.message ?? "No reason given")", false)
        }
    }

    /// Acknowledges the agent's assigned task as a runtime side effect: bumps the ack counter,
    /// moves the task to `.running`, and privately notifies Smith whether this is a fresh start
    /// or a continuation. Formerly the `task_acknowledged` tool; now a first-turn runtime action
    /// with no model-callable surface. The ack counter is authoritative across respawns,
    /// rejections, and crash recovery (a `count == 1` post-increment is a fresh ack).
    private func performTaskAcknowledgement() async {
        guard let task = await toolContext.taskStore.taskForAgent(agentID: toolContext.agentID) else { return }
        guard task.status.isRunnable || task.status == .running else { return }

        let newAckCount = await toolContext.taskStore.incrementAcknowledgmentCount(id: task.id)
        let isContinuation = newAckCount > 1
        await toolContext.taskStore.updateStatus(id: task.id, status: .running)

        guard let smithID = await toolContext.agentIDForRole(.smith) else { return }
        let content = isContinuation
            ? "Continuing task '\(task.title)' — working on revisions."
            : "Task '\(task.title)' acknowledged. Beginning work."
        await toolContext.post(ChannelMessage(
            sender: .agent(configuration.role),
            recipientID: smithID,
            recipient: .agent(.smith),
            content: content,
            metadata: ["messageKind": .kind(isContinuation ? .taskContinuing : .taskAcknowledged)]
        ))
    }


    /// Runs an ALREADY-APPROVED call. Its only caller is `executeWithApproval`, which has posted
    /// the tool_request and the verdict itself — hence no visibility posting here. It carried a
    /// `postVisibility` flag for the old un-evaluated path, which no longer exists.
    private func directExecute(_ call: LLMToolCall, tool: any AgentTool) async -> (result: String, succeeded: Bool, executionMs: Int) {

        let agentIDPrefix = String(id.uuidString.prefix(8))
        let outcome = await Self.runToolWithTimeout(call, tool: tool, context: toolContext) { name, seconds in
            Self.stopLogger.warning("Tool '\(name, privacy: .public)' execution exceeded \(seconds, privacy: .public)s — cancelled (agent=\(agentIDPrefix, privacy: .public))")
        }
        turnToolExecutionMs += outcome.executionMs
        turnToolResultChars += outcome.result.count
        await toolContext.setToolExecutionStatus(call.id, outcome.succeeded)
        recordToolOutcome(name: call.name, succeeded: outcome.succeeded)
        return (outcome.result, outcome.succeeded, outcome.executionMs)
    }

    /// Tools whose "failure" is the CALLEE's exit status, not a tool malfunction — bash
    /// returns .failure for any non-zero exit, so a legitimate fix-the-failing-test loop
    /// (`swift test` → exit 1, edit, retest…) or `grep -q` misses would trip the streak
    /// breaker and idle the agent mid-task (fresh-Opus review finding). Exempt from
    /// streak counting; the identical-call breaker still covers true bash loops.
    private static let toolFailureStreakExemptTools: Set<String> = ["bash"]

    /// Feeds the per-tool failure-streak breaker (`toolFailureStreaks`). A success wipes
    /// that tool's streak and re-arms its warning; a failure increments it.
    private func recordToolOutcome(name: String, succeeded: Bool) {
        if succeeded {
            toolFailureStreaks[name] = nil
            toolFailureWarnedTools.remove(name)
        } else if !Self.toolFailureStreakExemptTools.contains(name) {
            toolFailureStreaks[name, default: 0] += 1
        }
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
            hasAwaitingReviewTasks: activeTasks.contains { $0.status == .awaitingHelp }
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
            "messageKind": .kind(.toolRequest),
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
            metadata["taskDescription"] = .string(task.renderedDescriptionWithTemplateInputs())
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

        if let channelTaskTitle {
            metadata["senderTaskTitle"] = .string(channelTaskTitle)
        }
        await toolContext.post(ChannelMessage(
            sender: .agent(configuration.role),
            content: Self.conciseToolCallSummary(name: call.name, arguments: call.arguments),
            metadata: metadata
        ))
    }

    /// Posts a security review status message to the channel. Static so it can be called from
    /// `withTaskGroup`. Takes a `post` closure rather than a `ToolContext` so the SAME poster
    /// serves every caller on the security path — per-agent tool calls (via the agent's context)
    /// and acceptance-validator evidence calls (via the validation channel) — so an auto-approval
    /// is surfaced identically no matter who made the call. `agentRoleValue` stamps the reviewed
    /// agent's role for callers that have one (nil for validators, which aren't an `AgentRole`).
    /// `agentInstanceID` identifies WHICH agent's call this verdict is about. `agentRole` is not
    /// enough: two workers share a role, and a tool call id is provider data that can repeat across
    /// them, so a reader joining a verdict to its request needs the pair to land on the right row.
    static func postSecurityReviewToChannel(
        disposition: SecurityDisposition,
        callID: String,
        agentInstanceID: UUID,
        roleName: String,
        agentRoleValue: String?,
        post: @Sendable (ChannelMessage) async -> Void
    ) async {
        let statusContent: String
        let securityDisposition: String
        if disposition.approved && disposition.isAutoApproval {
            statusContent = "Auto-approved\(disposition.message.map { " (\($0))" } ?? "")"
            securityDisposition = "autoApproved"
        } else if disposition.approved {
            statusContent = "Security Agent → \(roleName): SAFE\(disposition.message.map { " \($0)" } ?? "")"
            securityDisposition = "approved"
        } else if disposition.isWarning {
            let warnSummary = disposition.message?.components(separatedBy: "\n").first ?? ""
            statusContent = "Security Agent → \(roleName): WARN: \(warnSummary)"
            securityDisposition = "warning"
        } else {
            statusContent = "Security Agent → \(roleName): UNSAFE: \(disposition.message ?? "no reason given")"
            securityDisposition = "denied"
        }
        var reviewMetadata: [String: AnyCodable] = [
            "requestID": .string(callID),
            "agentID": .string(agentInstanceID.uuidString),
            "securityDisposition": .string(securityDisposition)
        ]
        if let agentRoleValue { reviewMetadata["agentRole"] = .string(agentRoleValue) }
        if let msg = disposition.message, !msg.isEmpty {
            reviewMetadata["dispositionMessage"] = .string(msg)
        }
        await post(ChannelMessage(
            sender: .system,
            content: statusContent,
            metadata: reviewMetadata
        ))
    }

    /// Posts tool output to the channel. Static so it can be called from `withTaskGroup`.
    ///
    /// The channel message stores only the display-truncated version of the output to avoid
    /// bloating the SwiftUI view layer with megabytes of data (e.g., binary blobs from osascript).
    static func postToolOutputToChannel(result: String, call: LLMToolCall, role: AgentRole, context: ToolContext, taskTitle: String? = nil, executionMs: Int? = nil) async {
        await postToolOutputToChannel(
            result: result,
            call: call,
            sender: .agent(role),
            post: { await context.post($0) },
            taskTitle: taskTitle,
            executionMs: executionMs,
            agentInstanceID: context.agentID
        )
    }

    /// `executionMs` is the tool's own wall-clock RUN time, as measured by `runToolWithTimeout`.
    /// Published because it is NOT derivable from the transcript: the request→output gap also
    /// contains the Security Agent's review, and the age of the request message keeps growing
    /// after the call returns. The live inspector displayed that age, so a call that had long
    /// since finished read as one that never did. Nil for post paths that execute no tool of their
    /// own, and absent rather than zero — a duration nobody measured must not render as "0 ms".
    static func postToolOutputToChannel(
        result: String,
        call: LLMToolCall,
        sender: ChannelMessage.Sender,
        post: @Sendable (ChannelMessage) async -> Void,
        taskTitle: String? = nil,
        taskID: UUID? = nil,
        executionMs: Int? = nil,
        agentInstanceID: UUID
    ) async {
        let trimmedResult = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedResult.isEmpty else { return }
        let truncated = AgentActor.truncateOutput(trimmedResult, maxLines: 4)
        let isTruncated = truncated != trimmedResult
        var outputMetadata: [String: AnyCodable] = [
            "requestID": .string(call.id),
            "messageKind": .kind(.toolOutput),
            "agentID": .string(agentInstanceID.uuidString),
            "tool": .string(call.name)
        ]
        if let executionMs {
            outputMetadata["executionMs"] = .int(executionMs)
        }
        if let taskTitle {
            outputMetadata["senderTaskTitle"] = .string(taskTitle)
        }
        if let taskID {
            outputMetadata["taskID"] = .string(taskID.uuidString)
        }
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
        await post(ChannelMessage(
            sender: sender,
            content: isTruncated ? truncated : trimmedResult,
            metadata: outputMetadata,
            taskID: taskID
        ))
    }

    /// Tools executed sequentially with no security approval, as one contiguous segment. Kept
    /// as a named constant (rather than a literal inside the run loop) because
    /// `handoffLifecycleTools` must stay a subset of it — see `parkingToolsAreLifecycleTools`.
    static let taskLifecycleTools: Set<String> = [
        "task_update", "task_complete", "request_help", "reply_to_user",
        "message_user", "notify_brown"
    ]

    /// Smith tools that ACT ON a specific task, identified by a `task_id` argument. A Smith turn
    /// that calls one of these is doing work FOR that task, so its cost is attributed there — not
    /// to a status-based guess. `create_task` is handled separately (it has no `task_id`; its
    /// target is the task it just created). Read-only tools (`get_task_details`, `list_tasks`)
    /// are deliberately absent: looking is orchestration, not acting on a task.
    static let smithTaskActionTools: Set<String> = [
        "provide_help", "edit_task", "set_template_inputs",
        "set_acceptance_criteria", "manage_steps", "run_task", "update_task",
        "amend_task", "manage_task_disposition", "schedule_task_action"
    ]

    /// The task a Smith turn should be billed to: the FIRST task its tool calls acted on, in
    /// tool-call order. `create_task` resolves to the task created this turn (`preCreateTaskIDs`
    /// is the id set captured just before the tools ran; the sole new id is the created task).
    /// Returns nil when the turn acted on no task — genuine orchestration overhead.
    private func smithTurnTargetTaskID(response: LLMResponse, preCreateTaskIDs: Set<UUID>?) async -> UUID? {
        for call in response.toolCalls {
            if call.name == "create_task" {
                if let preCreateTaskIDs {
                    let created = await toolContext.taskStore.allTasks().filter { !preCreateTaskIDs.contains($0.id) }
                    // Attribute ONLY when exactly one task appeared this turn. `allTasks()` bookends
                    // an `await handleResponse`, during which the runtime (auto-advance clone, a
                    // wake, a second create_task) could add another task — so >1 new task means the
                    // diff is ambiguous and we must not guess. 0 or >1 → fall through (next tool, or
                    // Orchestration). This keeps a rare race from mis-billing to another agent's task.
                    if created.count == 1 { return created[0].id }
                }
                continue
            }
            guard Self.smithTaskActionTools.contains(call.name) else { continue }
            guard let params = try? call.parsedArguments(),
                  case .string(let raw)? = params["task_id"],
                  let taskID = UUID(uuidString: raw) else { continue }
            // Only attribute to a task that actually exists — a malformed/stale id is not a target.
            if await toolContext.taskStore.taskAnyDisposition(id: taskID) != nil { return taskID }
        }
        return nil
    }

    /// The lifecycle tools that hand control to ANOTHER actor, so the calling agent must stop
    /// after one succeeds. Every name here has to also be in `taskLifecycleTools`: only the
    /// lifecycle branch of the run loop knows to break out of the remaining segments.
    static let handoffLifecycleTools: Set<String> = ["task_complete", "request_help"]

    /// Whether a successful lifecycle tool transfers control away from the current agent turn.
    static func shouldParkAfterLifecycleTool(named toolName: String, succeeded: Bool) -> Bool {
        succeeded && handoffLifecycleTools.contains(toolName)
    }

    /// Message kinds that are addressed privately to a parked worker but must NOT resume it.
    ///
    /// The default is deliberately "a private message resumes the worker": every other way a
    /// message reaches a parked worker means somebody is handing work back (a validator punch
    /// list, a user send-back, `provide_help`, `amend_task`, Smith's `notify_brown`), and a
    /// missed entry here only costs an extra turn. A missed entry in an ALLOWLIST would instead
    /// strand the worker parked forever, which is the worse failure — hence the exemption list.
    static let parkedWorkerInformationalMessageKinds: Set<ChannelMessageKind> = [
        .validationBlockedWorkerNotice
    ]

    /// Whether `message` should pull a parked worker (`awaitingTaskReview`) into a new LLM turn.
    ///
    /// Addressing alone is not sufficient, and assuming it was cost 19 minutes of spin on
    /// 2026-07-27: a worker submitted correctly, parked, and in the SAME millisecond received
    /// `validation_blocked_worker_notice` — the notice whose own text reads "Do NOT resubmit,
    /// rework anything, or call request_help — STOP and wait." Because it was addressed to the
    /// worker, the old `recipientID == id` test read it as revision feedback and un-parked the
    /// agent it was sent to quiet. The notice had also just forbidden the only two tools that
    /// re-park (`task_complete`, `request_help`), so the worker had no way back to idle and
    /// narrated until a circuit breaker terminated it.
    static func resumesParkedWorker(_ message: ChannelMessage, agentID: UUID) -> Bool {
        guard message.recipientID == agentID else { return false }
        // No kind is a POSITIVE answer here, not a fallback: the private messages that hand work
        // back — `notify_brown`, `amend_task` — carry no `messageKind` at all. "Addressed to this
        // worker and not on the exemption list" IS the rule, and an unkinded message satisfies it.
        guard let kind = message.kind else { return true }
        return !parkedWorkerInformationalMessageKinds.contains(kind)
    }

    /// Folds one completed tool call into the run loop's post-turn decisions.
    ///
    /// Every question here is answered from the tool's DECLARED effects plus the call's domain
    /// outcome — never from its output text. Output text is written for the model and gets
    /// reworded; two of the prose comparisons this replaced were already dead when it was written
    /// (see `ToolEffect`), and had been silently skipping the parking they were meant to trigger.
    ///
    /// `tool` is nil only for a call naming a tool that doesn't exist, which cannot have effects.
    private func updatePostCallFlags(
        call: LLMToolCall,
        tool: (any AgentTool)?,
        succeeded: Bool,
        sentMessage: inout Bool,
        calledTaskComplete: inout Bool,
        triggeredRuntimeRestart: inout Bool
    ) {
        let effects: Set<ToolEffect> = succeeded ? (tool?.successEffects ?? []) : []

        if effects.contains(.deliveredMessage) { sentMessage = true }
        // A successful task_complete or request_help hands control to another actor. Use the
        // tool's domain outcome rather than parsing its human-facing response text.
        if Self.shouldParkAfterLifecycleTool(named: call.name, succeeded: succeeded) { calledTaskComplete = true }
        if effects.contains(.triggeredRuntimeRestart) { triggeredRuntimeRestart = true }

        if configuration.role == .brown {
            if effects.contains(.reportedTaskProgress) {
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

    /// Sleeps for up to `maxDuration` seconds, or until interrupted by a new message or a
    /// broker notification nudge (`wakeFromIdle`), whichever comes first. The agent no longer owns
    /// scheduled wakes — the `WakeScheduler` fires them into the broker, which nudges an idle Smith
    /// to drain — so there is no wake-time clamp here anymore.
    private func idleWait(maxDuration: TimeInterval? = nil) async {
        var duration = maxDuration ?? pollInterval
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

    /// Smith-only: pulls whatever the broker has queued for this agent and injects each notification
    /// as a user-role message, flagging unprocessed input so the loop handles them this iteration.
    /// This is pure CONSUMPTION — the `WakeScheduler` owns scheduling and the broker owns delivery +
    /// durability. A no-op for agents without a drain source wired (Brown).
    private func drainQueuedNotifications() async {
        guard let drainNotifications else { return }
        let texts = await drainNotifications()
        guard !texts.isEmpty else { return }
        for text in texts {
            conversationHistory.append(.user(text))
        }
        hasUnprocessedInput = true
        pushLiveContext()
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

    /// Opening delimiter of the auto-memory block, closed by `[/AUTO_MEMORY_CONTEXT]`.
    ///
    /// The block is appended AFTER the user's own text, separated by a blank line, inside the
    /// USER turn itself (`injectAutoMemoryContextIfNeeded` mutates Smith's local copy of the
    /// pending message; the `ChannelMessage` in the transcript is untouched). Retrieved memory
    /// content is arbitrary stored text, and grafting it into a user turn unmarked would present
    /// it to Smith as something the person said — a memory phrased as an instruction would read
    /// as one. The pair, plus the system note the block opens with, is what draws that line. Keep
    /// them whatever the retrieval cadence: this is a prompt-injection boundary, not bookkeeping.
    ///
    /// Contents are verbatim and uncapped — each hit carries its FULL memory content and ALL its
    /// tags (`formatAutoMemoryContextBlock`). Only the number of hits is bounded, by the search's
    /// `memoryLimit`. So the block's context cost scales with how long the matched memories are,
    /// which is a separate budget from the retrieval latency.
    ///
    /// Retrieval runs on EVERY user message — each message is its own question and deserves its
    /// own memories. It stays affordable because a user-message retrieval searches memories only
    /// (see `injectAutoMemoryContextIfNeeded`), which is one query embedding rather than two.
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

        // Capture the target message ID before the await — we re-locate by ID afterward
        // because the actor may process other isolated methods during the suspend, and a
        // raw index could become stale if `pendingChannelMessages` is mutated.
        let targetMessageID = userMessage.id

        // Resolved-setting-driven retrieval for a user message (`.smithUserMessage`): memories on /
        // prior-tasks off by default, so this is normally one embedding + one memory scan, and a
        // cheap no-op when disabled. Prior-task summaries default off here because "what earlier work
        // resembles this?" is a question about a TASK (`.newTask` retrieval), not a conversational
        // turn. Failure degrades to empty inside `retrieveContext` — no auto-context this time.
        let results = await toolContext.retrieveContext(.smithUserMessage, query)

        guard !results.isEmpty else { return }

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

        // Count the injection only now — the block is committed to the message Smith will read.
        // Every earlier return in this function (empty results, message already drained) leaves
        // these memories retrieved but NOT injected, which is exactly the distinction the two
        // counters exist to draw.
        await toolContext.memoryStore.recordInjections(memoryIDs: results.memories.map(\.memory.id))

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
            "messageKind": .kind(.memorySearched),
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

    /// Formats the auto-attached memory + prior tasks block. Layout mirrors `SearchMemoryTool`'s
    /// output so Smith sees a familiar shape, with an explicit framing note that the user did
    /// not author this section.
    private func formatAutoMemoryContextBlock(results: SemanticSearchResults) -> String {
        var lines: [String] = []
        lines.append(Self.autoMemoryContextMarker)
        lines.append("*System note: relevant memories were auto-attached based on the user's message above. Consider this background before creating a task or answering. Prior-task summaries are NOT searched here — those are retrieved when a task is created or started — so their absence means nothing was looked for, not that nothing was relevant. The user did not write any of the text inside this block.*")

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
        // staged via `attach_file` (which arrive with no associated channel message
        // but still need to land in the conversation history for the next LLM turn).
        guard !pendingChannelMessages.isEmpty || !pendingStagedAttachments.isEmpty else { return }

        // When awaiting task review, only wake if a message that actually hands work back
        // arrived (revision feedback, an amended task, Smith poking the worker directly).
        // Everything else — system banners, public notifications, and the park notice itself —
        // still drains into history but doesn't trigger a new LLM call.
        if awaitingTaskReview {
            let hasResumeMessage = pendingChannelMessages.contains {
                Self.resumesParkedWorker($0, agentID: id)
            }
            if hasResumeMessage {
                awaitingTaskReview = false
                hasUnprocessedInput = true
                continuationNudgesSinceProgress = 0
            }
            // else: drain messages into history below, but leave hasUnprocessedInput as-is
        } else {
            // Separate task_complete messages from the batch so they get their own LLM turn.
            // This prevents the review trigger from being buried in a merged text blob.
            let hasTaskComplete = pendingChannelMessages.contains { msg in
                if msg.kind == .taskComplete { return true }
                return false
            }
            let hasOtherMessages = pendingChannelMessages.contains { msg in
                if msg.kind == .taskComplete { return false }
                return true
            }

            if hasTaskComplete && hasOtherMessages {
                // Split: defer task_complete messages, drain everything else now.
                let taskCompleteMessages = pendingChannelMessages.filter { msg in
                    if msg.kind == .taskComplete { return true }
                    return false
                }
                pendingChannelMessages.removeAll { msg in
                    if msg.kind == .taskComplete { return true }
                    return false
                }
                deferredMessages.append(contentsOf: taskCompleteMessages)
            }

            // Lifecycle messages are informational — drain them into history for context but
            // don't trigger a new LLM call. Only messages that require Smith's action (user
            // messages, task_complete, errors) should wake it.
            let nonWakingKinds: Set<ChannelMessageKind> = [.taskLifecycle, .taskAcknowledged]
            let hasActionableMessage = pendingChannelMessages.contains { msg in
                if let kind = msg.kind, nonWakingKinds.contains(kind) {
                    return false
                }
                return true
            }
            if hasActionableMessage {
                hasUnprocessedInput = true
                // Real input from outside is progress in the sense the nudge budget cares about:
                // the worker now has something it did not have on the previous turn.
                continuationNudgesSinceProgress = 0
            }
        }

        // Collect all images + documents across pending messages
        var allImages: [LLMImageContent] = []
        var allDocuments: [LLMDocumentContent] = []
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
            case .validator:
                senderLabel = "VALIDATOR"
            }
            let formatted = message.kind == .orchestratorMessage
                ? Self.orchestratorMessageEnvelope(message.content)
                : "[\(senderLabel)]: \(message.content)"

            // Downscale + inject images (gated on the model's vision capability) and surface
            // EVERY attachment as a `file://` reference line the agent can quote (id=…) into a
            // downstream tool call or pass to `file_read`. Single source of truth in the helper.
            let assembled = AttachmentInjection.assemble(
                message.attachments,
                modelSupportsVision: configuration.supportsVision,
                modelSupportsDocuments: configuration.supportsDocuments,
                urlProvider: toolContext.attachmentURLProvider
            )
            allImages.append(contentsOf: assembled.images)
            allDocuments.append(contentsOf: assembled.documents)
            allTextParts.append(([formatted] + assembled.referenceLines).joined(separator: "\n"))
        }
        // Signal the runtime which user messages are being incorporated this turn, so their
        // durable buffer entries can be dropped now (and not before — see the callback doc).
        let incorporatedUserMessageIDs: [UUID] = pendingChannelMessages.compactMap { msg in
            if case .user = msg.sender { return msg.id }
            return nil
        }
        pendingChannelMessages.removeAll()
        if !incorporatedUserMessageIDs.isEmpty {
            onInboundUserMessagesIncorporated?(incorporatedUserMessageIDs)
        }

        // Drain any attachments staged via `attach_file`: images become content blocks (gated
        // on the model's vision capability), every attachment gets a reference line. Dedupe by
        // id so an attach_file called twice in a row doesn't double-inject. Stage list is cleared
        // unconditionally — leaving entries across drains creates leaks under retries.
        if !pendingStagedAttachments.isEmpty {
            var seenIDs: Set<UUID> = []
            var uniqueAttachments: [Attachment] = []
            for entry in pendingStagedAttachments {
                guard seenIDs.insert(entry.attachment.id).inserted else { continue }
                uniqueAttachments.append(entry.attachment)
            }
            let assembled = AttachmentInjection.assemble(
                uniqueAttachments,
                modelSupportsVision: configuration.supportsVision,
                modelSupportsDocuments: configuration.supportsDocuments,
                urlProvider: toolContext.attachmentURLProvider
            )
            allImages.append(contentsOf: assembled.images)
            allDocuments.append(contentsOf: assembled.documents)
            allTextParts.append((["[Staged for this turn via attach_file]"] + assembled.referenceLines).joined(separator: "\n"))
            pendingStagedAttachments.removeAll()
        }

        let combinedText = allTextParts.joined(separator: "\n\n")

        // If the last history entry is already a user message (e.g. a prior LLM call failed
        // before producing an assistant response), merge into it to maintain the strict
        // user/assistant alternation that some model APIs require.
        if let lastIndex = conversationHistory.indices.last,
           conversationHistory[lastIndex].role == .user,
           case .text(let existingText) = conversationHistory[lastIndex].content {
            let merged = existingText + "\n\n" + combinedText
            // Combine images + documents from both the existing message and the new ones.
            let mergedImages = (conversationHistory[lastIndex].images ?? []) + allImages
            let mergedDocuments = (conversationHistory[lastIndex].documents ?? []) + allDocuments
            conversationHistory[lastIndex] = Self.makeUserMessage(merged, images: mergedImages, documents: mergedDocuments)
        } else {
            conversationHistory.append(Self.makeUserMessage(combinedText, images: allImages, documents: allDocuments))
        }
        pushLiveContext()
    }

    /// Builds a user message, attaching image/document content only when present so a plain
    /// message stays plain (some providers reject empty media arrays).
    static func makeUserMessage(_ text: String, images: [LLMImageContent], documents: [LLMDocumentContent]) -> LLMMessage {
        if images.isEmpty && documents.isEmpty {
            return .user(text)
        }
        return .user(text, images: images, documents: documents)
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

    /// Caps a tool result for conversation history (shared overflow handling — see `ToolResultCap`).
    static func capToolResult(_ result: String) -> String {
        ToolResultCap.cap(result)
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
              case .httpError(let statusCode, let body, _, _) = providerError else {
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
                content: "Aggressively pruned \(prunedCount) messages for \(roleName) (task-state rebuild unavailable)."
            ))
        }
    }

    /// Reports a failed task-state rebuild as a channel error and logs it.
    ///
    /// This is the fail-closed leg of `rebuildContextFromTask`: the agent keeps running on a
    /// sliding-window prune of its own history rather than adopting a task that isn't its own,
    /// but the condition is anomalous — a worker exists to run a task — so it is surfaced as an
    /// error rather than absorbed silently.
    private func postRebuildFailure(_ reason: String) async {
        let roleName = configuration.role.displayName
        let agentIDPrefix = String(id.uuidString.prefix(8))
        Self.stopLogger.error(
            "rebuildContextFromTask failed role=\(roleName, privacy: .public) agent=\(agentIDPrefix, privacy: .public) reason=\(reason, privacy: .public)"
        )
        await toolContext.post(ChannelMessage(
            sender: .system,
            content: "Cannot rebuild \(roleName)'s context from task state: \(reason). Falling back to pruning the agent's own history — it will NOT be re-seeded from another task.",
            metadata: ["isError": .bool(true), "agentRole": .string(configuration.role.rawValue)]
        ))
    }

    /// Rebuilds Brown's conversation history from ITS OWN task's data.
    ///
    /// Completely replaces the conversation history with:
    /// 1. The original system prompt
    /// 2. A freshly composed worker briefing — the SAME text a newly spawned worker gets
    /// 3. The last complete assistant + tool-result exchange from the old history (for continuity)
    ///
    /// This is far more efficient than pruning because task updates are a compressed log
    /// of accomplishments (~1 line each) vs the verbose tool call/result pairs they replaced.
    /// It also eliminates tool-pair stitching bugs that can cause API errors.
    ///
    /// **Task binding.** The task comes from `taskForAgent` — this agent's own assignment —
    /// and nothing else. This method used to take `allTasks().first(where: { $0.status ==
    /// .running })`, and `allTasks()` sorts newest-first, so with more than one worker live
    /// EVERY compacting worker deterministically adopted the most recently created running
    /// task's identity. Observed 2026-07-24: a localization worker compacted while a second
    /// worker's audit task was running, came back believing it was the audit worker, and —
    /// having also lost its own progress log to the swap — discarded several thousand
    /// uncommitted translations it no longer remembered making.
    ///
    /// `taskForAgent` accepts any actionable status, not just `.running` as the old lookup did.
    /// That widening is deliberate: it is the SAME binding `task_update`, `task_complete`,
    /// `manage_steps`, and `request_help` resolve through, so what the rebuild reads is by
    /// construction what those tools write to. A second, narrower notion of "this worker's task"
    /// is how the two came to disagree in the first place.
    ///
    /// **Fails closed.** A worker with no assignment, or a briefing that can't be composed,
    /// yields `false` and an error on the channel. Callers fall back to `forceAggressivePrune`,
    /// which keeps a window of the agent's OWN history. Rebuilding from a guessed task is
    /// never the fallback — a plausible-looking envelope belonging to someone else is far
    /// more dangerous than a truncated one belonging to nobody.
    ///
    /// - Returns: `true` if this agent's task was found and context was rebuilt; `false` otherwise.
    private func rebuildContextFromTask() async -> Bool {
        guard let task = await toolContext.taskStore.taskForAgent(agentID: toolContext.agentID) else {
            await postRebuildFailure("it has no assigned task to rebuild from")
            return false
        }
        guard let briefing = await toolContext.composeTaskBriefing(task.id) else {
            await postRebuildFailure("the briefing for task \"\(task.title)\" could not be composed")
            return false
        }

        // Extract the last complete tool exchange before clearing history.
        let lastExchange = extractLastToolExchange()

        let instruction = """
            \(briefing)

            Your conversation history was cleared because it exceeded the model's context window. \
            The briefing above is your task's CURRENT state, re-read from the task store just now — \
            its progress log reflects your work so far. Continue working on this task from where you \
            left off. Do not repeat work that the progress updates show is already done, and do not \
            discard or revert work on the assumption that you never did it. \
            You are already this task's assigned worker — do not start it again; just continue.
            """

        // Post the rebuild marker AFTER composing the briefing, so the briefing carries the
        // work log rather than this bookkeeping line.
        await toolContext.taskStore.addUpdate(
            id: task.id,
            message: "Context cleared due to size limits — rebuilding from task state and continuing work."
        )

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

    /// A clear, actionable transcript line for an HTTP 402 (out of credits / payment required),
    /// so the cause reads plainly instead of a raw JSON error body under a generic "error (n/50):"
    /// frame. Ends without terminal punctuation so the caller's "— retrying in …" suffix flows.
    static func outOfCreditsMessage(role: AgentRole, model: String) -> String {
        "Agent \(role.displayName): out of credits — the provider for model '\(model)' returned HTTP 402 (Payment Required). Add funds to your account to continue"
    }

    private static func logUnhandled400(_ error: Error) {
        guard let providerError = error as? LLMProviderError,
              case .httpError(let statusCode, let body, let url, _) = providerError,
              statusCode == 400 else {
            return
        }
        agentLogger.warning(
            "Unhandled HTTP 400 (not context overflow): url=\(url?.absoluteString ?? "unknown", privacy: .public) body=\(body.prefix(500), privacy: .public)"
        )
    }

    /// Formats a retry delay for the transcript in the largest sensible whole unit —
    /// e.g. "6 seconds", "10 minutes", "1.5 hours", "2 days". Approximate by design.
    static func formatRetryDelay(_ seconds: Double) -> String {
        let s = max(0, seconds)
        if s < 60 {
            let n = Int(s.rounded())
            return "\(n) second\(n == 1 ? "" : "s")"
        }
        if s < 3600 {
            let n = Int((s / 60).rounded())
            return "\(n) minute\(n == 1 ? "" : "s")"
        }
        if s < 86_400 {
            let hours = (s / 3600 * 10).rounded() / 10
            let text = hours == hours.rounded() ? String(Int(hours)) : String(format: "%.1f", hours)
            return "\(text) hour\(hours == 1 ? "" : "s")"
        }
        let days = (s / 86_400 * 10).rounded() / 10
        let text = days == days.rounded() ? String(Int(days)) : String(format: "%.1f", days)
        return "\(text) day\(days == 1 ? "" : "s")"
    }

    /// Wall-clock time a retry will fire, for the transcript: just the time when it's later
    /// today ("3:14 PM"), or the weekday + date when it lands on another day
    /// ("3:14 PM on Mon Jul 14").
    static func formatRetryClock(_ date: Date, now: Date = Date()) -> String {
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "h:mm a"
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return time.string(from: date)
        }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "EEE MMM d"
        return "\(time.string(from: date)) on \(day.string(from: date))"
    }

}
