import Foundation
import SwiftLLMKit

/// Result of a tool execution. The `output` string is the message presented to the LLM as
/// the tool result; `succeeded` is the domain-level outcome propagated to the
/// `ToolExecutionTracker` so the security evaluator can tell a legitimate retry-after-failure
/// from a duplicate operation.
public struct ToolExecutionResult: Sendable {
    public let output: String
    public let succeeded: Bool

    public init(output: String, succeeded: Bool) {
        self.output = output
        self.succeeded = succeeded
    }

    public static func success(_ output: String) -> ToolExecutionResult {
        ToolExecutionResult(output: output, succeeded: true)
    }

    public static func failure(_ output: String) -> ToolExecutionResult {
        ToolExecutionResult(output: output, succeeded: false)
    }
}

/// A tool that an agent can invoke via LLM tool calling.
public protocol AgentTool: Sendable {
    /// Unique name for this tool (must match the LLM tool definition).
    var name: String { get }

    /// Human-readable description of what the tool does.
    var toolDescription: String { get }

    /// JSON Schema parameters definition.
    var parameters: [String: AnyCodable] { get }

    /// Executes the tool with the given arguments and returns the output plus a domain-level
    /// success/failure flag. Tools that wrap external processes (bash, gh) MUST mark the
    /// result as failed when the underlying process exited non-zero or timed out; tools
    /// that detect their own domain failures (file-not-found, invalid input, etc.) should
    /// likewise return `.failure(...)` so Security Agent's recent-tool-calls context is accurate.
    func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult

    /// Whether this tool should be included in the LLM's tool definitions for this turn.
    /// Default is `true`. Override to conditionally hide tools based on context.
    func isAvailable(in context: ToolAvailabilityContext) -> Bool

    /// Maximum wall-clock time a single invocation of this tool may take. After this
    /// `AgentActor` cancels the tool's task and synthesizes a "Tool execution exceeded N s —
    /// cancelled" result for the LLM. Default is 120 s. Tools that legitimately need longer
    /// (e.g. a future `download_file`) should override.
    /// Note: cancellation is cooperative *and* structured — `runToolWithTimeout` awaits the
    /// cancelled task, so a tool that never checks `Task.isCancelled` / never hits a
    /// cancellation-aware `await` will keep running and delay the agent loop until it finishes
    /// on its own. A long-running tool must poll cancellation in its hot loop.
    var executionTimeout: Duration { get }

    /// Whether invoking this tool can cause destructive or hard-to-reverse effects (data loss,
    /// irreversible state change). Surfaced to the security agent (Security Agent) when scoping a task's
    /// tool set. Defaults to the central `ToolSafetyClassification`, which is fail-closed —
    /// an unrecognized name is treated as destructive. MCP tools override this from the
    /// server's (untrusted) `destructiveHint`.
    var isDestructive: Bool { get }

    /// Whether the tool reaches an open/external world beyond a closed local system (arbitrary
    /// network access, external app control, the internet). Surfaced to Security Agent when scoping.
    /// Same fail-closed default as `isDestructive`; MCP tools override from `openWorldHint`.
    var isOpenWorld: Bool { get }

    /// A stable identity salt folded into the per-task scoping fingerprint, so a tool whose
    /// *provenance* changes (not just its name/description/schema) forces a re-scope. Built-in
    /// tools return `nil` (their name is their identity). MCP tools return their server's
    /// install-stable UUID, so deleting a server and reinstalling a same-named one — even with a
    /// byte-identical tool spec — produces a different fingerprint and never inherits the prior
    /// approval. Not part of the dispatch name and never persisted.
    var identityToken: String? { get }
}

/// Contextual information for determining tool availability before an LLM call.
public struct ToolAvailabilityContext: Sendable {
    /// When the user last sent a direct message to this agent, if ever.
    public let lastDirectUserMessageAt: Date?
    /// The role of the agent whose tools are being evaluated.
    public let agentRole: AgentRole
    /// Whether the task store contains any active tasks with a runnable status (pending, paused, or interrupted).
    public let hasRunnableTasks: Bool
    /// Whether the task store contains any active tasks with awaitingReview status.
    public let hasAwaitingReviewTasks: Bool

    public init(lastDirectUserMessageAt: Date? = nil, agentRole: AgentRole, hasRunnableTasks: Bool = false, hasAwaitingReviewTasks: Bool = false) {
        self.lastDirectUserMessageAt = lastDirectUserMessageAt
        self.agentRole = agentRole
        self.hasRunnableTasks = hasRunnableTasks
        self.hasAwaitingReviewTasks = hasAwaitingReviewTasks
    }
}

extension AgentTool {
    /// Default: tool is always available.
    public func isAvailable(in context: ToolAvailabilityContext) -> Bool { true }

    /// Default per-tool wall-clock cap. Picked so that the slowest legitimate in-process
    /// tools (large `glob`, deep `grep`, schema introspection of a heavy app) finish
    /// comfortably while a tool that overruns gets cancelled (and, if it polls cancellation,
    /// actually stops) instead of pinning the agent loop on a stuck call.
    public var executionTimeout: Duration { .seconds(120) }

    /// Default classification from the central built-in table (fail-closed for unknown names).
    public var isDestructive: Bool { ToolSafetyClassification.isDestructive(toolName: name) }

    /// Default classification from the central built-in table (fail-closed for unknown names).
    public var isOpenWorld: Bool { ToolSafetyClassification.isOpenWorld(toolName: name) }

    /// Default: built-in tools have no separate identity salt (their name is their identity).
    public var identityToken: String? { nil }

    /// One-line summary of what the tool does, suitable for inclusion in *another* agent's
    /// system prompt (notably Smith's "Brown's tools" manifest). Returns the first sentence
    /// of `toolDescription` with intra-line wrapping collapsed — strips parameter detail and
    /// the Brown-only safety/approval-gate framing that lives further down most descriptions.
    /// Override on tools whose first sentence is awkward or uninformative for cross-agent use.
    public var smithFacingSummary: String {
        let collapsed = toolDescription
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if let firstSentenceEnd = collapsed.range(of: ". ") {
            return String(collapsed[..<firstSentenceEnd.lowerBound]) + "."
        }
        return collapsed
    }

    /// Returns the description to present to the LLM for a given agent role.
    /// Defaults to `toolDescription`. Override to provide role-specific instructions.
    public func description(for role: AgentRole) -> String {
        toolDescription
    }

    /// Returns the parameters schema to present to the LLM for a given agent role.
    /// Defaults to `parameters`. Override to provide role-specific parameter descriptions.
    public func parameters(for role: AgentRole) -> [String: AnyCodable] {
        parameters
    }

    /// Builds an `LLMToolDefinition` with description and parameters tailored for the given agent role.
    public func definition(for role: AgentRole) -> LLMToolDefinition {
        LLMToolDefinition(
            name: name,
            description: description(for: role),
            parameters: parameters(for: role)
        )
    }
}

/// Canonical reasons used when draining pending tool requests due to system-level cancellations.
/// Both the producer (OrchestrationRuntime drain sites) and consumer (AgentActor status filtering)
/// reference these constants to avoid fragile hardcoded string matching.
public enum SystemCancellationReason: String, CaseIterable, Sendable {
    case agentTerminated = "Agent terminated"
    case agentSelfTerminated = "Agent self-terminated"
    case systemShuttingDown = "System shutting down"

    /// Pre-computed set of all raw values for O(1) membership checks.
    public static let allMessages: Set<String> = Set(allCases.map(\.rawValue))
}

/// Contextual information passed to tools during execution.
public struct ToolContext: Sendable {
    public let agentID: UUID
    public let agentRole: AgentRole
    public let channel: MessageChannel
    /// This session's task store. Holds only *active* tasks; the archived + deleted buckets are
    /// global and reached through `taskStore.allInactiveTasks()` / `taskStore.taskAnyDisposition(id:)`.
    public let taskStore: TaskStore
    /// Full snapshot of the ModelConfiguration the owning agent is using at spawn
    /// time. Used to stamp channel messages with provider/model/config provenance.
    /// Frozen at context construction — if the agent's config changes mid-run (rare),
    /// a fresh ToolContext would need to be built.
    public let currentConfiguration: ModelConfiguration?
    /// Provider API type (e.g. "anthropic", "openAICompatible") for the owning
    /// agent's current configuration. Not derivable from ModelConfiguration alone.
    public let currentProviderType: String?
    /// Callback to request spawning a new Brown+Security Agent pair. Returns the Brown agent's ID.
    public let spawnBrown: @Sendable () async -> UUID?
    /// Callback to terminate an agent by ID. Second parameter is the caller's agent ID.
    public let terminateAgent: @Sendable (UUID, UUID) async -> Bool
    /// Emergency abort: stops all agents. Requires user interaction to restart.
    /// Second parameter is the caller's role for attribution.
    public let abort: @Sendable (String, AgentRole?) async -> Void
    /// Resolves an agent ID to its role, used for access-control checks.
    public let agentRoleForID: @Sendable (UUID) async -> AgentRole?
    /// Resolves a role to the currently active agent's UUID, used for role-based addressing.
    public let agentIDForRole: @Sendable (AgentRole) async -> UUID?
    /// Called when the agent's run loop exits naturally (errors or self-termination).
    /// Allows the runtime to clean up subscriptions and registry entries.
    public let onSelfTerminate: @Sendable () async -> Void
    /// Hands a just-submitted task to the acceptance-validation system. Called by
    /// `task_complete` after setting the result and the `.validating` status.
    public let beginTaskValidation: @Sendable (UUID) async -> Void
    /// A fresh snapshot of the evaluator registry (hot-loaded from disk), or nil when no
    /// registry directory is configured. Smith's criteria/validator tools use this as
    /// their selection surface. Defaults to nil for contexts built outside the runtime.
    public let loadEvaluatorRegistry: @Sendable () async -> EvaluatorRegistry?
    /// Liveness lease check: returns true while the runtime still tracks this agent as a
    /// live, current agent. The agent's run loop consults this around every LLM turn and
    /// self-stops on false — the dead-man's switch that kills an agent whose runtime
    /// moved on without stopping it (the "zombie agent" class). Defaults to always-true
    /// for contexts built outside the runtime (tests).
    public let isAgentCurrent: @Sendable () async -> Bool
    /// Called with `true` when the agent begins an LLM API call, and `false` when it completes.
    public let onProcessingStateChange: @Sendable (Bool) -> Void
    /// Called with `true` when Security Agent begins a security evaluation LLM call, `false` when it completes.
    public let onSecurityAgentProcessingStateChange: @Sendable (Bool) -> Void
    /// Called when a tool execution starts or finishes. `started == true` adds the tool's
    /// name to the in-flight set for this agent; `started == false` removes it. Allows the
    /// UI to show a "Working" / "Tool: <name>" indicator distinct from the LLM "Thinking"
    /// state — important when a slow tool blocks the agent for minutes after the LLM call
    /// has returned. Multiple concurrent calls (parallel-tool batches) are fine; ordering
    /// of starts/ends is preserved per call ID.
    public let onToolExecutionStateChange: @Sendable (_ toolName: String, _ started: Bool) -> Void
    /// Schedules a deferred wake-up. See `ScheduledWake` for the per-wake record. Returns
    /// `.scheduled(wake)` or `.error(...)`. Args: wakeAt, instructions, taskID, replacesID,
    /// recurrence, survivesTaskTermination. Pass `survivesTaskTermination: true` for wakes
    /// whose intent is to act on a task whose previous run has already terminated (e.g.
    /// `run_task`, `summarize`) — otherwise the first run's completion will wipe every
    /// queued future wake against the same task.
    let scheduleWake: @Sendable (Date, String, UUID?, UUID?, Recurrence?, Bool) async -> ScheduleWakeOutcome
    /// Returns all currently-scheduled wakes for the calling agent (sorted by `wakeAt`).
    public let listScheduledWakes: @Sendable () async -> [ScheduledWake]
    /// Cancels a single wake by id. Returns true on success.
    public let cancelScheduledWake: @Sendable (UUID) async -> Bool
    /// Signals a full system restart for a new task. Called by create_task.
    public let restartForNewTask: @Sendable (UUID) async -> Void
    /// The task ID that the current session was started/restarted for, if any.
    /// Used by `run_task` to prevent restart loops when Smith re-invokes it on the same task.
    public let currentResumingTaskID: UUID?
    /// Semantic memory store for saving and searching memories and task summaries.
    public let memoryStore: MemoryStore
    /// Triggers summarization and embedding of a completed or failed task.
    public let summarizeCompletedTask: @Sendable (UUID) async -> Void
    /// Merges two related memory texts into a single consolidated memory via LLM.
    /// Parameters: (existingContent, newContent). Returns merged text, or nil if unavailable.
    public let mergeMemoryContent: @Sendable (String, String) async -> String?
    /// Runs a prompt against fetched web-page content via the summarizer's LLM and returns the
    /// extracted answer, or nil if unavailable or the call fails. Backs `web_fetch`'s hybrid
    /// extraction mode. Parameters: (content, prompt).
    public let extractWebContent: @Sendable (String, String) async -> String?
    /// Whether Smith should automatically run the next pending task after completing one.
    /// Closure so the value reflects the current setting, not the value at init time.
    public let autoAdvanceEnabled: @Sendable () async -> Bool
    /// Records that a file at the given path was successfully read during this agent session.
    public let recordFileRead: @Sendable (String) -> Void
    /// Returns true if the file at the given path was read during this agent session.
    public let hasFileBeenRead: @Sendable (String) -> Bool
    /// Records the execution status of a tool call for security agent inspection.
    public let setToolExecutionStatus: @Sendable (String, Bool) async -> Void
    /// Checks if a tool call has already succeeded. Async because the underlying
    /// store is actor-isolated.
    public let hasToolSucceeded: @Sendable (String) async -> Bool
    /// Checks if a tool call has already failed after being approved. Async because
    /// the underlying store is actor-isolated.
    public let hasToolFailed: @Sendable (String) async -> Bool
    /// Resolves a list of attachment-ID strings (UUID strings) to live `Attachment`
    /// records via the per-session `AttachmentRegistry`. Returns the resolved attachments
    /// and a list of any IDs that couldn't be resolved (for tool error messages).
    /// Used by `create_task`, `task_update`, and `task_complete` to forward user-attached
    /// or task-attached files when the LLM references them by ID.
    public let resolveAttachments: @Sendable ([String]) async -> (resolved: [Attachment], rejected: [String])
    /// Reads a local file from disk, mints a fresh `Attachment`, persists its bytes to
    /// the per-session attachments directory, and registers it for later ID-based lookup.
    /// Used by Brown's lifecycle tools (`task_update`, `task_complete`) to attach files
    /// produced during the task. Returns the new `Attachment` on success; on failure
    /// returns nil with a human-readable error string.
    public let ingestAttachmentFile: @Sendable (String) async -> (attachment: Attachment?, error: String?)
    /// Mints an `Attachment` from bytes already in memory (`data`, `filename`, `mimeType`),
    /// persists + registers it, and returns it. Used by `web_fetch` when a fetched URL returns
    /// binary content (image / PDF) downloaded into memory rather than read from a path.
    /// Mirrors `ingestAttachmentFile` but for in-hand bytes. Returns the new `Attachment` on
    /// success; on failure returns nil with a human-readable error string.
    public let ingestAttachmentData: @Sendable (_ data: Data, _ filename: String, _ mimeType: String) async -> (attachment: Attachment?, error: String?)
    /// Synchronous resolver for the on-disk URL of an attachment by `(id, filename)`.
    /// Used by sync-only paths in `AgentActor` (e.g. `drainPendingMessages`) to produce
    /// `file://` markdown links without an actor hop. Returns nil when no per-session
    /// path is wired (tests, in-memory contexts). The URL is purely informational —
    /// callers MUST NOT assume the file exists; bytes still go through the registry.
    public let attachmentURLProvider: @Sendable (UUID, String) -> URL?
    /// Stages attachments into the calling agent's next user turn. The runtime drains
    /// these into the assembled LLM message — image attachments become content blocks at
    /// the requested detail tier; non-image attachments become markdown reference lines.
    /// Used by the `view_attachment` tool so an agent can pull a previously-known
    /// attachment into its visual context on demand. The string parameter is the
    /// detail tier ("thumbnail" / "standard" / "full"); unknown values fall back to
    /// "standard".
    public let stageAttachmentsForNextTurn: @Sendable ([Attachment], String) async -> Void
    /// Per-message aggregate attachment cap in bytes. Tool resolvers sum
    /// `Attachment.byteCount` across the resolved set and reject when the total exceeds
    /// this cap. Sourced from `OrchestrationRuntime.maxAttachmentBytesPerMessage`, which
    /// the app layer drives from `SharedAppState.maxAttachmentBytesPerMessage`. The
    /// tool-side check is independent of the per-file cap enforced by the registry's
    /// `ingestFile`.
    public let maxAttachmentBytesPerMessage: @Sendable () async -> Int
    /// Invoked when a backend rejects a request because the configured output-token cap
    /// exceeds the model's true maximum, reporting that maximum as `(providerID, modelID,
    /// limit)`. The app layer persists it as a catalog override so future provider builds
    /// clamp to it (and the Settings UI reflects the corrected limit). No-op by default.
    public let onLearnedModelOutputLimit: @Sendable (_ providerID: String, _ modelID: String, _ limit: Int) -> Void

    init(
        agentID: UUID,
        agentRole: AgentRole,
        channel: MessageChannel,
        taskStore: TaskStore,
        currentConfiguration: ModelConfiguration? = nil,
        currentProviderType: String? = nil,
        spawnBrown: @escaping @Sendable () async -> UUID?,
        terminateAgent: @escaping @Sendable (UUID, UUID) async -> Bool,
        abort: @escaping @Sendable (String, AgentRole?) async -> Void,
        agentRoleForID: @escaping @Sendable (UUID) async -> AgentRole?,
        agentIDForRole: @escaping @Sendable (AgentRole) async -> UUID? = { _ in nil },
        onSelfTerminate: @escaping @Sendable () async -> Void = {},
        beginTaskValidation: @escaping @Sendable (UUID) async -> Void = { _ in },
        loadEvaluatorRegistry: @escaping @Sendable () async -> EvaluatorRegistry? = { nil },
        isAgentCurrent: @escaping @Sendable () async -> Bool = { true },
        onProcessingStateChange: @escaping @Sendable (Bool) -> Void = { _ in },
        onSecurityAgentProcessingStateChange: @escaping @Sendable (Bool) -> Void = { _ in },
        onToolExecutionStateChange: @escaping @Sendable (String, Bool) -> Void = { _, _ in },
        scheduleWake: @escaping @Sendable (Date, String, UUID?, UUID?, Recurrence?, Bool) async -> ScheduleWakeOutcome = { _, _, _, _, _, _ in .error("Scheduling not configured.") },
        listScheduledWakes: @escaping @Sendable () async -> [ScheduledWake] = { [] },
        cancelScheduledWake: @escaping @Sendable (UUID) async -> Bool = { _ in false },
        restartForNewTask: @escaping @Sendable (UUID) async -> Void = { _ in },
        currentResumingTaskID: UUID? = nil,
        memoryStore: MemoryStore,
        summarizeCompletedTask: @escaping @Sendable (UUID) async -> Void = { _ in },
        mergeMemoryContent: @escaping @Sendable (String, String) async -> String? = { _, _ in nil },
        extractWebContent: @escaping @Sendable (String, String) async -> String? = { _, _ in nil },
        autoAdvanceEnabled: @escaping @Sendable () async -> Bool = { true },
        recordFileRead: @escaping @Sendable (String) -> Void = { _ in },
        hasFileBeenRead: @escaping @Sendable (String) -> Bool = { _ in false },
        // Every production code path wires these through to the shared ToolExecutionTracker.
        // A missing wiring is a programming error — `assertionFailure` surfaces it loudly in
        // debug/tests, but a release build degrades (the boolean queries return `false`, the
        // neutral "outcome not yet recorded" state) rather than crashing.
        setToolExecutionStatus: @escaping @Sendable (String, Bool) async -> Void = { _, _ in
            assertionFailure("ToolContext.setToolExecutionStatus was not configured — wire it through to a ToolExecutionTracker.")
        },
        hasToolSucceeded: @escaping @Sendable (String) async -> Bool = { _ in
            assertionFailure("ToolContext.hasToolSucceeded was not configured — wire it through to a ToolExecutionTracker.")
            return false
        },
        hasToolFailed: @escaping @Sendable (String) async -> Bool = { _ in
            assertionFailure("ToolContext.hasToolFailed was not configured — wire it through to a ToolExecutionTracker.")
            return false
        },
        resolveAttachments: @escaping @Sendable ([String]) async -> (resolved: [Attachment], rejected: [String]) = { _ in ([], []) },
        ingestAttachmentFile: @escaping @Sendable (String) async -> (attachment: Attachment?, error: String?) = { _ in
            (nil, "ToolContext.ingestAttachmentFile was not configured.")
        },
        ingestAttachmentData: @escaping @Sendable (Data, String, String) async -> (attachment: Attachment?, error: String?) = { _, _, _ in
            (nil, "ToolContext.ingestAttachmentData was not configured.")
        },
        attachmentURLProvider: @escaping @Sendable (UUID, String) -> URL? = { _, _ in nil },
        stageAttachmentsForNextTurn: @escaping @Sendable ([Attachment], String) async -> Void = { _, _ in },
        maxAttachmentBytesPerMessage: @escaping @Sendable () async -> Int = { 50 * 1024 * 1024 },
        onLearnedModelOutputLimit: @escaping @Sendable (String, String, Int) -> Void = { _, _, _ in }
    ) {
        self.agentID = agentID
        self.agentRole = agentRole
        self.channel = channel
        self.taskStore = taskStore
        self.currentConfiguration = currentConfiguration
        self.currentProviderType = currentProviderType
        self.spawnBrown = spawnBrown
        self.terminateAgent = terminateAgent
        self.abort = abort
        self.agentRoleForID = agentRoleForID
        self.agentIDForRole = agentIDForRole
        self.onSelfTerminate = onSelfTerminate
        self.beginTaskValidation = beginTaskValidation
        self.loadEvaluatorRegistry = loadEvaluatorRegistry
        self.isAgentCurrent = isAgentCurrent
        self.onProcessingStateChange = onProcessingStateChange
        self.onSecurityAgentProcessingStateChange = onSecurityAgentProcessingStateChange
        self.onToolExecutionStateChange = onToolExecutionStateChange
        self.scheduleWake = scheduleWake
        self.listScheduledWakes = listScheduledWakes
        self.cancelScheduledWake = cancelScheduledWake
        self.restartForNewTask = restartForNewTask
        self.currentResumingTaskID = currentResumingTaskID
        self.memoryStore = memoryStore
        self.summarizeCompletedTask = summarizeCompletedTask
        self.mergeMemoryContent = mergeMemoryContent
        self.extractWebContent = extractWebContent
        self.autoAdvanceEnabled = autoAdvanceEnabled
        self.recordFileRead = recordFileRead
        self.hasFileBeenRead = hasFileBeenRead
        self.setToolExecutionStatus = setToolExecutionStatus
        self.hasToolSucceeded = hasToolSucceeded
        self.hasToolFailed = hasToolFailed
        self.resolveAttachments = resolveAttachments
        self.ingestAttachmentFile = ingestAttachmentFile
        self.ingestAttachmentData = ingestAttachmentData
        self.attachmentURLProvider = attachmentURLProvider
        self.stageAttachmentsForNextTurn = stageAttachmentsForNextTurn
        self.maxAttachmentBytesPerMessage = maxAttachmentBytesPerMessage
        self.onLearnedModelOutputLimit = onLearnedModelOutputLimit
    }

    /// Posts a message to the channel, auto-stamping it with the owning agent's
    /// context: `taskID` (looked up via `taskStore.taskForAgent`), `providerID`,
    /// `modelID`, and `configuration` (from `currentConfiguration`). `sessionID`
    /// is filled in by `MessageChannel.post` itself. Fields already set on the
    /// incoming message are left alone — callers can override any stamp by
    /// pre-populating the field.
    ///
    /// Prefer this over `channel.post(...)` directly whenever a `ToolContext`
    /// is in scope so that every ChannelMessage carries full provenance.
    public func post(_ message: ChannelMessage) async {
        var stamped = message
        if stamped.taskID == nil {
            if agentRole == .smith {
                stamped.taskID = await taskStore.currentActiveTask()?.id
            } else {
                stamped.taskID = await taskStore.taskForAgent(agentID: agentID)?.id
            }
        }
        if stamped.providerID == nil {
            stamped.providerID = currentConfiguration?.providerID
        }
        if stamped.modelID == nil {
            stamped.modelID = currentConfiguration?.model
        }
        if stamped.configuration == nil {
            stamped.configuration = currentConfiguration
        }
        await channel.post(stamped)
    }
}
