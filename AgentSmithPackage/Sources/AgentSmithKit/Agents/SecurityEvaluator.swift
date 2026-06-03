import Foundation
import SwiftLLMKit

/// The outcome of a security evaluation of a tool request.
public struct SecurityDisposition: Sendable, Equatable {
    public let approved: Bool
    /// Explanation — required when denied, recommended for medium-risk warnings.
    public let message: String?
    /// True when this is a WARN denial — the request can be retried once for auto-approval.
    public let isWarning: Bool
    /// True when this approval was automatic (identical retry of a WARN'd request).
    public let isAutoApproval: Bool
    /// True when the evaluation was cancelled mid-flight (user stop/abort/escape). The
    /// tool was not actually deemed unsafe — the surrounding agent was just torn down
    /// before Jones could finish. Inspector rendering treats this as a neutral
    /// "CANCELLED" label rather than red UNSAFE.
    public let isCancelled: Bool

    /// Creates a security disposition with the given approval state and optional metadata.
    public init(approved: Bool, message: String? = nil, isWarning: Bool = false, isAutoApproval: Bool = false, isCancelled: Bool = false) {
        self.approved = approved
        self.message = message
        self.isWarning = isWarning
        self.isAutoApproval = isAutoApproval
        self.isCancelled = isCancelled
    }
}

/// Execution outcome of a tool call.
public enum ToolExecutionOutcome: String, Codable, Sendable {
    /// Tool has not yet been executed
    case notExecuted
    /// Tool was executed and succeeded
    case succeeded
    /// Tool was approved but failed during execution
    case safeButFailed
}

/// Record of a single security evaluation for inspector display.
public struct EvaluationRecord: Sendable, Identifiable, Equatable {
    public let id = UUID()
    /// When the evaluation occurred.
    public let timestamp: Date
    /// The name of the tool that was evaluated.
    public let toolName: String
    /// The JSON-encoded parameters passed to the tool call.
    public let toolParams: String
    /// The title of the task the tool call was made under, if any.
    public let taskTitle: String?
    /// The full evaluation prompt sent to the Jones LLM.
    public let prompt: String
    /// The raw text response from the Jones LLM.
    public let response: String
    /// The parsed security disposition (approved/denied, warning status, etc.).
    public let disposition: SecurityDisposition
    /// Wall-clock time in milliseconds for the evaluation round-trip.
    public let latencyMs: Int
    /// The execution outcome of the tool call (if executed).
    public let executionOutcome: ToolExecutionOutcome
    /// The tool call ID for tracking execution status.
    public let toolCallID: String
    
    public init(
        timestamp: Date,
        toolName: String,
        toolParams: String,
        taskTitle: String?,
        prompt: String,
        response: String,
        disposition: SecurityDisposition,
        latencyMs: Int,
        executionOutcome: ToolExecutionOutcome = .notExecuted,
        toolCallID: String = ""
    ) {
        self.timestamp = timestamp
        self.toolName = toolName
        self.toolParams = toolParams
        self.taskTitle = taskTitle
        self.prompt = prompt
        self.response = response
        self.disposition = disposition
        self.latencyMs = latencyMs
        self.executionOutcome = executionOutcome
        self.toolCallID = toolCallID
    }
}

/// Outcome of a per-task tool scoping pass.
public struct ToolScopingResult: Sendable {
    /// Tool names the security agent approved (already intersected with the real candidate set,
    /// so hallucinated names are excluded).
    public let approvedNames: Set<String>
    /// The raw security-agent response, for the audit record.
    public let rawResponse: String
    /// `false` when the security agent could not produce a parseable allow/block decision after
    /// retries — a hard error the caller must surface to the user (do NOT spawn the worker).
    /// `true` even when `approvedNames` is empty: that is a deliberate "block everything"
    /// refusal, which is a different situation from a failed evaluation.
    public let succeeded: Bool

    public init(approvedNames: Set<String>, rawResponse: String, succeeded: Bool) {
        self.approvedNames = approvedNames
        self.rawResponse = rawResponse
        self.succeeded = succeeded
    }
}

/// Direct security evaluator that replaces the Jones agent actor.
///
/// Makes LLM calls using Jones's model configuration to evaluate tool requests.
/// Thread-safe — can be called concurrently for parallel tool call batches.
/// Each Brown agent gets its own evaluator instance; state dies with Brown.
actor SecurityEvaluator {
    private let provider: any LLMProvider
    private let systemPrompt: String
    private let channel: MessageChannel
    private let abort: @Sendable (String, AgentRole) async -> Void

    /// Ring buffer of recent tool requests for evaluation context. Each entry
    /// retains the originating tool call ID so the prompt can annotate the
    /// summary with the actual execution outcome (succeeded / failed / unknown)
    /// — without that, Jones sees only "verdict: SAFE" and assumes the tool
    /// actually ran successfully, which leads to false denials of legitimate
    /// retries after a tool error.
    private struct RecentToolRequest {
        let toolName: String
        let toolParams: String
        let verdict: String
        let toolCallID: String?
    }
    private var recentToolRequests: [RecentToolRequest] = []
    private static let maxRecentToolRequests = 10

    /// WARN retry tracking — an identical retry of a WARN'd request is auto-approved.
    /// Uses an array of pending retries instead of a single "last warned" slot so
    /// concurrent evaluations don't clear each other's state.
    private struct WarnedRequest {
        let toolName: String
        let toolParams: [String: AnyCodable]?
    }
    private var pendingWarnRetries: [WarnedRequest] = []
    private static let maxPendingWarnRetries = 10

    /// Consecutive evaluation-level failures (each evaluation exhausted its retries).
    /// Triggers abort at threshold. Only incremented when a full evaluation fails,
    /// not on individual retry attempts — prevents false aborts under concurrency
    /// where transient failures across parallel evaluations would race the counter.
    private var consecutiveEvaluationFailures = 0
    private static let maxConsecutiveFailures = 20
    /// Cap on parse-failure retries within a single evaluation. Each unparseable verdict
    /// costs one retry; LLM call errors also cost one retry. File_read rounds are NOT
    /// capped — Jones may read as many files as it needs before committing to a verdict;
    /// the loop ends only on a parsed verdict, parse-retry exhaustion, or task
    /// cancellation. (A pathological model that never stops reading is bounded only by
    /// task cancellation — revisit if that ever shows up in practice.)
    private static let maxRetries = 5

    /// Tool definition for file_read, presented to Jones's LLM.
    private static let fileReadToolDef: LLMToolDefinition = {
        let tool = FileReadTool()
        return tool.definition(for: .jones)
    }()

    /// Evaluation history for inspector display.
    private var history: [EvaluationRecord] = []
    private static let maxHistory = 50

    /// Fires after each evaluation is recorded, pushing the record to the UI layer.
    private var onEvaluationRecorded: (@Sendable (EvaluationRecord) -> Void)?
    /// Fires after each Jones LLM call so the inspector's per-agent token/cost view for the
    /// security agent is populated (Jones is a SecurityEvaluator, not an AgentActor, so without
    /// this it never produced turn records and showed 0 tokens / $0.00).
    private var onTurnRecorded: (@Sendable (LLMTurnRecord) -> Void)?

    /// Token usage store for persistent analytics.
    private let usageStore: UsageStore?
    /// Full snapshot of the ModelConfiguration used for Jones's LLM calls. Carried
    /// directly so UsageRecords get the full config — context size, temperature, etc. —
    /// embedded as immutable historical truth.
    private let configuration: ModelConfiguration?
    /// API type key for the provider (e.g. "anthropic", "openAICompatible"). Not on
    /// ModelConfiguration itself, so still passed separately.
    private let providerType: String
    /// Session ID for the current orchestration run — stamped on every UsageRecord.
    private let sessionID: UUID?

    /// Function to check if a tool call has already succeeded.
    private let hasToolSucceeded: @Sendable (String) async -> Bool
    /// Function to check if a tool call has already failed after being approved.
    private let hasToolFailed: @Sendable (String) async -> Bool

    public init(
        provider: any LLMProvider,
        systemPrompt: String,
        channel: MessageChannel,
        abort: @escaping @Sendable (String, AgentRole) async -> Void,
        usageStore: UsageStore? = nil,
        configuration: ModelConfiguration? = nil,
        providerType: String = "",
        sessionID: UUID? = nil,
        // Forgetting to wire these causes Jones to misclassify failed-then-retried calls as
        // duplicates (the original 394bbbc bug). `assertionFailure` surfaces the wiring
        // mistake loudly in debug/tests; a release build degrades to `false` (the neutral
        // "no recorded outcome" state) rather than crashing. Production callers
        // (OrchestrationRuntime) and tests exercising this path MUST pass real closures.
        hasToolSucceeded: @escaping @Sendable (String) async -> Bool = { _ in
            assertionFailure("SecurityEvaluator.hasToolSucceeded was not configured — wire it through to a ToolExecutionTracker before evaluating tools.")
            return false
        },
        hasToolFailed: @escaping @Sendable (String) async -> Bool = { _ in
            assertionFailure("SecurityEvaluator.hasToolFailed was not configured — wire it through to a ToolExecutionTracker before evaluating tools.")
            return false
        }
    ) {
        self.provider = provider
        self.systemPrompt = systemPrompt
        self.channel = channel
        self.abort = abort
        self.usageStore = usageStore
        self.configuration = configuration
        self.providerType = providerType
        self.sessionID = sessionID
        self.hasToolSucceeded = hasToolSucceeded
        self.hasToolFailed = hasToolFailed
    }

    /// Returns the evaluation history for inspector display.
    public func evaluationHistory() -> [EvaluationRecord] {
        history
    }

    /// Posts a channel message stamped with the evaluator's provider/model/config
    /// context. Use this instead of `channel.post(...)` for any Jones-originated
    /// message so it carries full provenance for downstream rollups. `taskID`
    /// can be passed explicitly for messages tied to a specific evaluation.
    private func postToChannel(_ message: ChannelMessage, taskID: UUID? = nil) async {
        var stamped = message
        if stamped.taskID == nil { stamped.taskID = taskID }
        if stamped.providerID == nil { stamped.providerID = configuration?.providerID }
        if stamped.modelID == nil { stamped.modelID = configuration?.model }
        if stamped.configuration == nil { stamped.configuration = configuration }
        await channel.post(stamped)
    }

    /// Registers a callback fired after each security evaluation is recorded.
    public func setOnEvaluationRecorded(_ handler: @escaping @Sendable (EvaluationRecord) -> Void) {
        onEvaluationRecorded = handler
    }

    /// Registers a callback fired after each Jones LLM call, carrying a turn record so the
    /// inspector can show the security agent's per-session token usage and cost.
    public func setOnTurnRecorded(_ handler: @escaping @Sendable (LLMTurnRecord) -> Void) {
        onTurnRecorded = handler
    }

    /// Builds and emits a turn record for one Jones LLM call.
    private func emitTurnRecord(response: LLMResponse, latencyMs: Int, messageCount: Int) {
        guard let onTurnRecorded else { return }
        onTurnRecorded(LLMTurnRecord(
            inputDelta: [],
            response: response,
            totalMessageCount: messageCount,
            latencyMs: latencyMs,
            modelID: configuration?.model ?? "",
            providerType: providerType,
            providerID: configuration?.providerID,
            temperature: configuration?.temperature ?? 0,
            maxOutputTokens: configuration?.maxTokens ?? 0,
            thinkingBudget: configuration?.thinkingBudget,
            usage: response.usage
        ))
    }

    /// Evaluates a tool request and returns a security disposition.
    ///
    /// Posts channel messages for UI visibility (tool review status).
    /// Handles WARN auto-retry: if Brown resubmits an identical request as the very next call,
    /// it is auto-approved without an LLM call.
    public func evaluate(
        toolName: String,
        toolParams: String,
        toolDescription: String,
        toolParameterDefs: String,
        taskTitle: String?,
        taskID: String?,
        taskDescription: String?,
        siblingCalls: String?,
        agentRoleName: String,
        toolCallID: String? = nil
    ) async -> SecurityDisposition {
        let parsedParams = Self.parseToolParams(toolParams)

        // Auto-approve identical retry of a WARN'd request.
        if let matchIndex = pendingWarnRetries.firstIndex(where: {
            $0.toolName == toolName && $0.toolParams == parsedParams
        }) {
            pendingWarnRetries.remove(at: matchIndex)
            appendSummary(toolName: toolName, toolParams: toolParams, verdict: "SAFE (auto-approved retry of prior WARN)", toolCallID: toolCallID)
            return SecurityDisposition(approved: true, isAutoApproval: true)
        }

        let evalPrompt = await buildEvalPrompt(
            toolName: toolName,
            toolParams: toolParams,
            toolDescription: toolDescription,
            toolParameterDefs: toolParameterDefs,
            taskTitle: taskTitle,
            taskID: taskID,
            taskDescription: taskDescription,
            siblingCalls: siblingCalls
        )

        var conversationMessages: [LLMMessage] = [
            .system(systemPrompt),
            .user(evalPrompt)
        ]

        let startTime = Date()
        var retryCount = 0
        var lastError: Error?
        // Only parse-failure retries bound this loop. A file_read round (the model
        // returned tool_calls) does NOT consume the retry budget and is not otherwise
        // capped — Jones reads as many files as it needs, then commits to a verdict.
        while retryCount < Self.maxRetries {
            let response: LLMResponse
            let callLatencyMs: Int
            do {
                let callStart = Date()
                // No max_tokens override — Jones uses whatever output cap its own
                // model configuration specifies. An earlier hard 200-token cap here
                // collided with extended thinking: the Anthropic provider has to
                // raise max_tokens above the thinking budget (>=1024), so a 200 cap
                // got clamped to budget+1, leaving ~1 token for the actual verdict
                // and producing empty, unparseable responses.
                response = try await provider.send(
                    messages: conversationMessages,
                    tools: [Self.fileReadToolDef]
                )
                callLatencyMs = Int(Date().timeIntervalSince(callStart) * 1000)
            } catch {
                if Task.isCancelled {
                    let disposition = SecurityDisposition(approved: false, message: "Evaluation cancelled", isCancelled: true)
                    recordEvaluation(toolName: toolName, toolParams: toolParams, taskTitle: taskTitle, prompt: evalPrompt, response: "(cancelled)", disposition: disposition, startTime: startTime)
                    return disposition
                }
                lastError = error
                retryCount += 1
                continue
            }

            // LLM call succeeded. Execute any file_reads Jones requested, accumulating
            // per-turn tool execution stats for the UsageRecord below.
            var turnToolExecutionMs = 0
            var turnToolResultChars = 0
            if !response.toolCalls.isEmpty {
                // `.assistant(from:)` preserves reasoning + provider
                // continuation (Anthropic thinking signatures / Gemini
                // thoughtSignatures) so Jones's multi-turn file-read loop
                // keeps thinking continuity. Manual construction silently
                // broke thinkingBudget > 0 runs and Gemini 2.5.
                conversationMessages.append(.assistant(from: response))
                // Execute each file_read and append tool results, timing each one.
                for call in response.toolCalls {
                    await postJonesFileReadToChannel(call)
                    let execStart = Date()
                    let result = executeJonesFileRead(call)
                    turnToolExecutionMs += Int(Date().timeIntervalSince(execStart) * 1000)
                    turnToolResultChars += result.count
                    conversationMessages.append(.toolResult(result, callID: call.id))
                }
            }

            // Capture Jones's token usage for analytics — tool stats folded in.
            if let usageStore {
                let taskUUID = taskID.flatMap { UUID(uuidString: $0) }
                await UsageRecorder.record(
                    response: response,
                    context: LLMCallContext(
                        agentRole: .jones,
                        taskID: taskUUID,
                        modelID: configuration?.model ?? "",
                        providerType: providerType,
                        providerID: configuration?.providerID,
                        configuration: configuration,
                        sessionID: sessionID,
                        totalToolExecutionMs: turnToolExecutionMs,
                        totalToolResultChars: turnToolResultChars
                    ),
                    latencyMs: callLatencyMs,
                    to: usageStore
                )
            }

            emitTurnRecord(response: response, latencyMs: callLatencyMs, messageCount: conversationMessages.count)

            if !response.toolCalls.isEmpty {
                continue
            }

            let responseText = response.text ?? ""

            guard let disposition = parseDisposition(responseText, toolName: toolName, parsedParams: parsedParams, agentRoleName: agentRoleName) else {
                retryCount += 1

                // Post error to channel only after several failures.
                if retryCount >= 3 {
                    await postToChannel(ChannelMessage(
                        sender: .system,
                        content: "Agent Jones error (\(retryCount)/\(Self.maxRetries)): failed to parse security response",
                        metadata: ["isError": .bool(true), "agentRole": .string(AgentRole.jones.rawValue)]
                    ))
                }
                continue
            }

            consecutiveEvaluationFailures = 0
            recordEvaluation(toolName: toolName, toolParams: toolParams, taskTitle: taskTitle, prompt: evalPrompt, response: responseText, disposition: disposition, startTime: startTime, toolCallID: toolCallID ?? "")

            // Record the summary with the verdict (after evaluation, so we have the result).
            appendSummary(toolName: toolName, toolParams: toolParams, verdict: Self.verdictSummary(from: responseText), toolCallID: toolCallID)

            // Handle ABORT — trigger system-wide shutdown. Uses verdictSummary so
            // ABORT is detected even when the model prefixes the verdict with preamble.
            // Case-sensitive: ABORT must be ALL-CAPS to count.
            if !disposition.approved,
               Self.verdictSummary(from: responseText).hasPrefix("ABORT") {
                // A bare `ABORT` (no trailing reason) parses to a nil message, but it
                // must still trigger the system-wide abort.
                let msg = disposition.message ?? "(no reason given)"
                await postToChannel(ChannelMessage(
                    sender: .system,
                    content: "Security review: ABORT — \(msg)",
                    metadata: [
                        "securityDisposition": .string("abort"),
                        "agentRole": .string(AgentRole.jones.rawValue)
                    ]
                ))
                await abort(msg, .jones)
            }

            return disposition
        }

        // Exhausted parse-failure retries — this evaluation fully failed (the model
        // could not produce a parseable verdict, or its LLM calls kept erroring).
        consecutiveEvaluationFailures += 1

        let lastErrorDescription = lastError?.localizedDescription

        if consecutiveEvaluationFailures >= Self.maxConsecutiveFailures {
            var abortContent = "Jones produced \(consecutiveEvaluationFailures) consecutive failed evaluations — aborting. Check Jones model configuration."
            if let desc = lastErrorDescription {
                abortContent += "\nLast error: \(desc)"
            }
            await postToChannel(ChannelMessage(
                sender: .system,
                content: abortContent
            ))
            await abort(
                "Jones security gatekeeper failed to produce valid output after \(consecutiveEvaluationFailures) consecutive evaluations",
                .jones
            )
        }

        var fallbackMessage = "Security evaluation failed after \(retryCount) parse retries"
        if let desc = lastErrorDescription {
            fallbackMessage += "\nLast error: \(desc)"
        }
        let fallback = SecurityDisposition(
            approved: false,
            message: fallbackMessage
        )
        let recordedResponse = lastErrorDescription ?? "(parse failure)"
        recordEvaluation(toolName: toolName, toolParams: toolParams, taskTitle: taskTitle, prompt: evalPrompt, response: recordedResponse, disposition: fallback, startTime: startTime, toolCallID: toolCallID ?? "")
        appendSummary(toolName: toolName, toolParams: toolParams, verdict: "UNSAFE (evaluation failed)", toolCallID: toolCallID)
        return fallback
    }

    // MARK: - Tool scoping (per-task)

    /// Per-task tool scoping pass: presents the full candidate tool list to the security agent
    /// (Jones), in the context of the task, and returns the subset it approves. Stateless — it
    /// does not consult or store prior approvals; the caller re-runs it whenever the candidate
    /// set changes. Fail-closed: a tool not explicitly allowed is blocked, and an unparseable
    /// response after retries returns `succeeded == false` so the caller can hard-stop.
    ///
    /// Uses a dedicated scoping system prompt and offers no tools (no file reads during scoping).
    func scopeTools(
        candidateTools: [any AgentTool],
        taskTitle: String,
        taskID: String,
        taskDescription: String
    ) async -> ToolScopingResult {
        // toolID == the tool's dispatch name (bare for built-ins, prefixed for MCP), so the
        // registry map-back is identity.
        let candidateNames = Set(candidateTools.map(\.name))
        guard !candidateNames.isEmpty else {
            return ToolScopingResult(approvedNames: [], rawResponse: "(no candidate tools)", succeeded: true)
        }

        let prompt = Self.buildScopingPrompt(
            candidateTools: candidateTools,
            taskTitle: taskTitle,
            taskID: taskID,
            taskDescription: taskDescription
        )
        let messages: [LLMMessage] = [
            .system(JonesBehavior.toolScopingSystemPrompt),
            .user(prompt)
        ]

        let startTime = Date()
        var retryCount = 0
        var lastError: Error?
        while retryCount < Self.maxRetries {
            let response: LLMResponse
            let callLatencyMs: Int
            do {
                let callStart = Date()
                response = try await provider.send(messages: messages, tools: [])
                callLatencyMs = Int(Date().timeIntervalSince(callStart) * 1000)
            } catch {
                if Task.isCancelled {
                    return ToolScopingResult(approvedNames: [], rawResponse: "(cancelled)", succeeded: false)
                }
                lastError = error
                retryCount += 1
                continue
            }

            if let usageStore {
                await UsageRecorder.record(
                    response: response,
                    context: LLMCallContext(
                        agentRole: .jones,
                        taskID: UUID(uuidString: taskID),
                        modelID: configuration?.model ?? "",
                        providerType: providerType,
                        providerID: configuration?.providerID,
                        configuration: configuration,
                        sessionID: sessionID
                    ),
                    latencyMs: callLatencyMs,
                    to: usageStore
                )
            }

            emitTurnRecord(response: response, latencyMs: callLatencyMs, messageCount: messages.count)

            let responseText = response.text ?? ""
            guard let approved = Self.parseScopingResponse(responseText, candidateNames: candidateNames) else {
                retryCount += 1
                continue
            }

            consecutiveEvaluationFailures = 0
            recordScopingEvaluation(
                taskTitle: taskTitle,
                prompt: prompt,
                response: responseText,
                approvedNames: approved,
                candidateCount: candidateNames.count,
                startTime: startTime
            )
            return ToolScopingResult(approvedNames: approved, rawResponse: responseText, succeeded: true)
        }

        // Exhausted retries — the security agent could not produce a usable decision.
        consecutiveEvaluationFailures += 1
        let failureText = "(scoping failed after \(retryCount) retries)" +
            (lastError.map { "\nLast error: \($0.localizedDescription)" } ?? "")
        recordScopingEvaluation(
            taskTitle: taskTitle,
            prompt: prompt,
            response: failureText,
            approvedNames: [],
            candidateCount: candidateNames.count,
            startTime: startTime
        )
        return ToolScopingResult(approvedNames: [], rawResponse: failureText, succeeded: false)
    }

    // MARK: - Structured scoping payloads

    /// The structured request handed to the security agent for per-task tool scoping. Serialized
    /// to JSON as the user message — a clean schema the model parses mechanically instead of a
    /// layered-prose prompt. We only ever encode it.
    private struct ToolSetScopingUserPrompt: Encodable {
        let taskID: String
        let taskTitle: String
        let taskDescription: String
        let toolGroups: [ToolGroup]
        let candidateTools: [CandidateTool]

        /// Tri-state capability flag. `unknown` = could not be determined (e.g. an MCP server
        /// that didn't declare the hint) — the agent is told to assume the riskier possibility.
        enum Flag: String, Encodable { case yes, no, unknown }

        /// How far to trust a tool's self-reported description and flags.
        enum TrustLevel: String, Encodable {
            /// Built-in: flags are authoritative facts.
            case requiredBySystem
            /// From an external server the user installed: description/flags are self-reported.
            case approvedByUser
            /// External, not explicitly installed by the user. (Unused today; reserved.)
            case untrusted
        }

        enum Source: String, Encodable {
            case builtIn
            case externalUserAdded
            case externalAutoDiscovered
        }

        struct ToolGroup: Encodable {
            let toolGroupID: String
            let name: String
            let description: String
            let source: Source
        }

        struct CandidateTool: Encodable {
            /// Unique id == the tool's dispatch name (the registry key).
            let toolID: String
            let toolGroupID: String
            let trustLevel: TrustLevel
            /// The tool's own name (unprefixed for MCP tools).
            let name: String
            let description: String
            let hasSideEffects: Flag
            let isDestructive: Flag
            let isOpenWorld: Flag
        }
    }

    /// The structured response we require back from the security agent: an allow/block decision
    /// per tool. We only ever decode it.
    private struct ToolSetScopingAIResponse: Decodable {
        struct ToolDecision: Decodable {
            let toolID: String
            let isAllowed: Bool
        }
        let toolResponses: [ToolDecision]
    }

    /// Classifies one candidate tool into its structured representation plus the group it belongs
    /// to. Built-in flags are authoritative facts; MCP flags come from the server's untrusted
    /// hints and become `.unknown` when the hint is absent.
    private static func classify(
        _ tool: any AgentTool
    ) -> (tool: ToolSetScopingUserPrompt.CandidateTool, group: ToolSetScopingUserPrompt.ToolGroup) {
        if let mcp = tool as? MCPBridgedTool {
            let groupID = "mcp__\(mcp.serverName)"
            let group = ToolSetScopingUserPrompt.ToolGroup(
                toolGroupID: groupID,
                name: mcp.serverName,
                description: "External MCP server configured by the user. Its tool descriptions and capability flags are self-reported by the server and not independently verified.",
                source: .externalUserAdded
            )
            let candidate = ToolSetScopingUserPrompt.CandidateTool(
                toolID: mcp.name,
                toolGroupID: groupID,
                trustLevel: .approvedByUser,
                name: mcp.originalToolName,
                description: mcp.toolDescription,
                hasSideEffects: flag(fromReadOnlyHint: mcp.isReadOnlyHint),
                isDestructive: flag(mcp.destructiveHint),
                isOpenWorld: flag(mcp.openWorldHint)
            )
            return (candidate, group)
        }
        let group = ToolSetScopingUserPrompt.ToolGroup(
            toolGroupID: "builtin",
            name: "Built-in tools",
            description: "Tools provided and vetted by the system. Their capability flags are authoritative facts.",
            source: .builtIn
        )
        let candidate = ToolSetScopingUserPrompt.CandidateTool(
            toolID: tool.name,
            toolGroupID: "builtin",
            trustLevel: .requiredBySystem,
            name: tool.name,
            description: tool.smithFacingSummary,
            hasSideEffects: ToolSafetyClassification.hasSideEffects(toolName: tool.name) ? .yes : .no,
            isDestructive: tool.isDestructive ? .yes : .no,
            isOpenWorld: tool.isOpenWorld ? .yes : .no
        )
        return (candidate, group)
    }

    private static func flag(_ hint: Bool?) -> ToolSetScopingUserPrompt.Flag {
        guard let hint else { return .unknown }
        return hint ? .yes : .no
    }

    private static func flag(fromReadOnlyHint readOnly: Bool?) -> ToolSetScopingUserPrompt.Flag {
        guard let readOnly else { return .unknown }
        return readOnly ? .no : .yes   // read-only ⇒ no side effects
    }

    /// Builds the scoping user message: the structured request serialized to pretty, sorted-key
    /// JSON. Sorted keys keep it deterministic (prompt-cache friendly).
    private static func buildScopingPrompt(
        candidateTools: [any AgentTool],
        taskTitle: String,
        taskID: String,
        taskDescription: String
    ) -> String {
        var groupsByID: [String: ToolSetScopingUserPrompt.ToolGroup] = [:]
        var candidates: [ToolSetScopingUserPrompt.CandidateTool] = []
        for tool in candidateTools {
            let (candidate, group) = classify(tool)
            groupsByID[group.toolGroupID] = group
            candidates.append(candidate)
        }
        let payload = ToolSetScopingUserPrompt(
            taskID: taskID,
            taskTitle: taskTitle,
            taskDescription: taskDescription,
            toolGroups: groupsByID.values.sorted { $0.toolGroupID < $1.toolGroupID },
            candidateTools: candidates
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(payload), let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    /// Decodes the structured allow/block response into the set of approved (and real) tool names.
    /// Tolerates ```json fences / surrounding prose by extracting the first balanced JSON object.
    /// Fail-closed: a candidate not explicitly allowed is blocked; hallucinated toolIDs are dropped.
    /// Returns nil — a parse failure that triggers a retry — when no decision object can be decoded
    /// OR when the decoded response references not a single real candidate (a garbage response).
    static func parseScopingResponse(_ text: String, candidateNames: Set<String>) -> Set<String>? {
        guard let jsonData = extractJSONObject(from: text),
              let decoded = try? JSONDecoder().decode(ToolSetScopingAIResponse.self, from: jsonData) else {
            return nil
        }
        var approved: Set<String> = []
        var recognizedAny = false
        for decision in decoded.toolResponses {
            guard candidateNames.contains(decision.toolID) else { continue }
            recognizedAny = true
            if decision.isAllowed { approved.insert(decision.toolID) }
        }
        return recognizedAny ? approved : nil
    }

    /// Extracts the first balanced top-level JSON object from arbitrary model text (handles
    /// ```json fences and leading/trailing prose). Brace counting ignores braces inside strings.
    static func extractJSONObject(from text: String) -> Data? {
        let chars = Array(text)
        guard let start = chars.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        for i in start..<chars.count {
            let c = chars[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 {
                    return String(chars[start...i]).data(using: .utf8)
                }
            }
        }
        return nil
    }

    /// Records a scoping decision as an `EvaluationRecord` for the inspector / audit trail.
    private func recordScopingEvaluation(
        taskTitle: String,
        prompt: String,
        response: String,
        approvedNames: Set<String>,
        candidateCount: Int,
        startTime: Date
    ) {
        let disposition = SecurityDisposition(
            approved: !approvedNames.isEmpty,
            message: "Approved \(approvedNames.count)/\(candidateCount) tools: \(approvedNames.sorted().joined(separator: ", "))"
        )
        recordEvaluation(
            toolName: "(tool scoping)",
            toolParams: "candidates: \(candidateCount)",
            taskTitle: taskTitle,
            prompt: prompt,
            response: response,
            disposition: disposition,
            startTime: startTime
        )
    }

    // MARK: - Private

    private func appendSummary(toolName: String, toolParams: String, verdict: String, toolCallID: String?) {
        recentToolRequests.append(RecentToolRequest(
            toolName: toolName,
            toolParams: toolParams,
            verdict: verdict,
            toolCallID: toolCallID
        ))
        if recentToolRequests.count > Self.maxRecentToolRequests {
            recentToolRequests.removeFirst()
        }
    }

    /// Extracts the verdict keyword and reasoning from Jones's raw response text,
    /// stripping the WARN retry boilerplate that is only relevant to Brown.
    ///
    /// Mirrors `parseDisposition`'s preamble-tolerance: scans all lines for the last
    /// one beginning with a verdict keyword so responses with chain-of-thought
    /// preceding the verdict still produce a useful one-line summary.
    ///
    /// Verdict matching is case-sensitive — Jones's prompt mandates ALL-CAPS. A lowercase
    /// `"abort, this is risky"` in conversational text must NOT trip a system-wide ABORT.
    private static func verdictSummary(from responseText: String) -> String {
        let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "(no response)" }
        let verdictKeywords: Set<String> = ["SAFE", "WARN", "UNSAFE", "ABORT"]
        let stripSet = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "*_`#>-•·\t "))

        var lastVerdictLine: String?
        for rawLine in trimmed.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(rawLine).trimmingCharacters(in: stripSet)
            guard !line.isEmpty else { continue }
            let words = line.split(separator: " ", maxSplits: 1)
            guard let first = words.first else { continue }
            // Strip punctuation but do NOT case-fold — verdict keywords MUST be ALL-CAPS.
            let keyword = first.trimmingCharacters(in: CharacterSet.punctuationCharacters)
            if verdictKeywords.contains(keyword) {
                lastVerdictLine = line
            }
        }

        if let lastVerdictLine { return lastVerdictLine }
        // Fall back to the first non-empty line so summaries still show *something*
        // useful even when the response is unparseable.
        let firstLineEnd = trimmed.firstIndex(where: { $0 == "\n" || $0 == "\r" }) ?? trimmed.endIndex
        return String(trimmed[trimmed.startIndex..<firstLineEnd])
    }

    private func recordEvaluation(toolName: String, toolParams: String, taskTitle: String?, prompt: String, response: String, disposition: SecurityDisposition, startTime: Date, executionOutcome: ToolExecutionOutcome = .notExecuted, toolCallID: String = "") {
        let latency = Int(Date().timeIntervalSince(startTime) * 1000)
        let record = EvaluationRecord(
            timestamp: Date(),
            toolName: toolName,
            toolParams: toolParams,
            taskTitle: taskTitle,
            prompt: prompt,
            response: response,
            disposition: disposition,
            latencyMs: latency,
            executionOutcome: executionOutcome,
            toolCallID: toolCallID
        )
        history.append(record)
        if history.count > Self.maxHistory {
            history.removeFirst(history.count - Self.maxHistory)
        }
        onEvaluationRecorded?(record)
    }

    private func buildEvalPrompt(
        toolName: String,
        toolParams: String,
        toolDescription: String,
        toolParameterDefs: String,
        taskTitle: String?,
        taskID: String?,
        taskDescription: String?,
        siblingCalls: String?
    ) async -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        let dateStr = dateFormatter.string(from: Date())

        var sections: [String] = []
        sections.append("The current date and time are \(dateStr)")

        if let title = taskTitle, let id = taskID {
            sections.append("""
                # Current task
                - title: \(title)
                - identifier: \(id)
                - description: \(taskDescription ?? "")
                """)
        }

        if !recentToolRequests.isEmpty {
            // Annotate each entry with the actual execution outcome of the
            // approved tool call. Without this Jones cannot tell that a SAFE
            // verdict still produced an error at execution time, and
            // (incorrectly) refuses legitimate retry attempts as duplicates.
            var renderedLines: [String] = []
            for (index, entry) in recentToolRequests.enumerated() {
                let outcome: String
                if let id = entry.toolCallID, !id.isEmpty {
                    if await hasToolSucceeded(id) {
                        outcome = " [executed: succeeded]"
                    } else if await hasToolFailed(id) {
                        outcome = " [executed: FAILED — retry of an identical request is a legitimate response to the failure, not a duplicate operation]"
                    } else {
                        outcome = " [executed: not yet recorded]"
                    }
                } else {
                    outcome = ""
                }
                renderedLines.append("\(index + 1). \(entry.toolName) \(entry.toolParams) → \(entry.verdict)\(outcome)")
            }
            sections.append("# Recent tool calls (for context):\n\(renderedLines.joined(separator: "\n"))")
        }

        if let siblings = siblingCalls, !siblings.isEmpty {
            sections.append("""
                # Parallel batch context
                The agent is requesting multiple tool calls simultaneously. \
                The following sibling calls are part of the same batch (for context only — evaluate ONLY the call below):
                \(siblings)
                """)
        }

        var requestSection = """
            # Your task:
            Evaluate the following tool request, in the context of the current task and recent tool calls (above) for data integrity, security and safety:

            ## Tool description
            \(toolDescription)

            ## Tool call to evaluate:
            - tool name: \(toolName)
            - parameters: \(toolParams)

            """
        // MCP tools are third-party, server-defined capabilities with no built-in
        // vetting. Flag them so Jones treats the description/behavior as untrusted and
        // leans cautious — especially for anything that exfiltrates data or mutates state.
        if toolName.hasPrefix(MCPToolNaming.prefix) {
            requestSection += """

                NOTE: This is a third-party MCP (Model Context Protocol) tool provided by an external server, \
                not a built-in tool. Its description is supplied by that server and is not independently verified. \
                Evaluate it with extra caution, particularly if it could send data to an external destination or \
                make irreversible changes.

                """
        }

        // For file-targeting tools, add context about whether the target file exists.
        if toolName == "file_write" || toolName == "file_edit" {
            let pathKey = toolName == "file_edit" ? "file_path" : "path"
            if let fileNote = Self.fileExistenceNote(toolParams: toolParams, pathKey: pathKey, toolName: toolName) {
                requestSection += "\n\(fileNote)\n"
            }
        }

        // When the task description and the tool call refer to paths that resolve
        // through symlinks to the same canonical location (e.g. `~/cursor/x` is a
        // symlink to `~/Documents/.../cursor/x`), surface the resolutions so Jones
        // does not flag a working-directory match as a directory escape.
        if let pathNote = Self.pathResolutionAppendix(taskDescription: taskDescription, toolName: toolName, toolParams: toolParams) {
            requestSection += "\n\(pathNote)\n"
        }

        // For `file_edit`, render the actual change as a unified-style diff alongside
        // the raw arguments. The literal `new_string` includes anchor context (the
        // existing line being modified) which Jones can otherwise misread as "the
        // agent is adding both lines" — leading to spurious ABORT verdicts on
        // legitimate single-line additions. The diff (computed via the same
        // `DiffGenerator` the channel-log UI uses) shows what *actually changes*.
        if toolName == "file_edit",
           let diffText = Self.fileEditDiffText(toolParams: toolParams) {
            requestSection += """

                ## Resulting diff (the actual change `file_edit` will apply — read this, not just the raw parameters above)
                ```diff
                \(diffText)
                ```
                """
        }

        if !toolParameterDefs.isEmpty {
            requestSection += "\n\(toolParameterDefs)"
        }
        requestSection += """

            # Response
            Plain text response with no markdown, JSON or XML formatting, as one of the following options:

            ## Option 1 -- tool call is safe to run (approved):
            SAFE <brief reasoning why this is safe>

            ## Option 2 -- this tool call or the pattern of recent tool calls appears unsafe to \
            run, but **MIGHT** be okay, *considering the user's stated intent in the task description*:
            WARN <terse message text follows on same line>

            ## Option 3 -- this tool call or the recent pattern of tool calls is unsafe and \
            should not be run:
            UNSAFE <terse text explaining why>

            ## Option 4 -- this tool call or the pattern established by recent history is \
            incredibly unsafe, presenting an immediate danger to the user's data, data \
            integrity, system integrity, the user's health, safety or well-being, or another \
            human's health, safety, or well-being, or is otherwise of a destructive and \
            unwanted nature:
            ABORT <brief terse text explaining why>

            ## If you are uncertain as to how to respond, respond with WARN.

            Your response will be processed by an automated system. DO NOT write any preamble, reasoning, \
            analysis, or chain-of-thought before your verdict. Your response MUST begin — on the very first \
            character of the very first line — with one of the four keywords SAFE, WARN, UNSAFE, or ABORT, \
            followed by your terse reasoning. No leading whitespace, no prefacing sentences, no markdown \
            headers, no "Let me think...", no "Based on...". Just the keyword, then your reasoning, all on one line.

            Correct: `SAFE reading a project file for task context`
            Incorrect: `Let me analyze this... SAFE reading a project file`
            Incorrect: `Based on the task, this appears safe.\\nSAFE reading a project file`
            """
        sections.append(requestSection)

        return sections.joined(separator: "\n\n")
    }

    /// Parses Jones's text response into a SecurityDisposition.
    /// Returns nil on parse failure (caller should retry).
    ///
    /// Robust to models that emit preamble or chain-of-thought before the verdict
    /// (notably observed on claude-haiku-4-5). Scans all lines for the *last* line
    /// whose first word — after trimming leading whitespace, markdown punctuation,
    /// and list bullets — is SAFE/WARN/UNSAFE/ABORT. The last match wins so a model
    /// that reasons about "UNSAFE" earlier and concludes "SAFE" ends up approved.
    ///
    /// Verdict matching is **case-sensitive**: Jones's prompt mandates ALL-CAPS keywords,
    /// and conversational lowercase ("abort, this is risky") must not trip a system-wide
    /// ABORT. If the model violates the prompt and writes a lowercase verdict, we let the
    /// retry path catch it — preferable to silently letting a chatty model trigger an abort.
    private func parseDisposition(_ text: String, toolName: String, parsedParams: [String: AnyCodable]?, agentRoleName: String) -> SecurityDisposition? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let verdictKeywords: Set<String> = ["SAFE", "WARN", "UNSAFE", "ABORT"]
        let stripSet = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "*_`#>-•·\t "))

        let lines = trimmed.split(whereSeparator: { $0 == "\n" || $0 == "\r" })

        var matchedKeyword: String?
        var matchedRemainder: String?
        var matchedLineIndex: Int?

        for (index, rawLine) in lines.enumerated() {
            let line = String(rawLine).trimmingCharacters(in: stripSet)
            guard !line.isEmpty else { continue }
            let words = line.split(separator: " ", maxSplits: 1)
            guard let first = words.first else { continue }
            // Strip punctuation but do NOT case-fold — verdict keywords MUST be ALL-CAPS.
            let keywordCandidate = first.trimmingCharacters(in: CharacterSet.punctuationCharacters)
            if verdictKeywords.contains(keywordCandidate) {
                matchedKeyword = keywordCandidate
                matchedRemainder = words.count > 1 ? String(words[1]) : nil
                matchedLineIndex = index
            }
        }

        guard let keywordUpper = matchedKeyword, let matchIdx = matchedLineIndex else {
            return nil
        }

        let explanatoryText: String? = {
            var parts: [String] = []
            if let remainder = matchedRemainder, !remainder.isEmpty {
                parts.append(remainder)
            }
            if matchIdx + 1 < lines.count {
                let rest = lines[(matchIdx + 1)...]
                    .map(String.init)
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !rest.isEmpty {
                    parts.append(rest)
                }
            }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }()

        switch keywordUpper {
        case "SAFE":
            return SecurityDisposition(approved: true, message: explanatoryText)
        case "WARN":
            pendingWarnRetries.append(WarnedRequest(toolName: toolName, toolParams: parsedParams))
            // Cap the pending retries to prevent unbounded growth.
            if pendingWarnRetries.count > Self.maxPendingWarnRetries {
                pendingWarnRetries.removeFirst()
            }
            let warnText = (explanatoryText ?? "") + "\nYour tool was not allowed to execute. Carefully consider the security response text above, in the context of the user's original intent (as given in the task description) and other actions taken and interactions and decide if you really want to call this tool. If you do, send *exactly* the same request again as your *very next* tool call, and it will be approved."
            return SecurityDisposition(approved: false, message: warnText, isWarning: true)
        case "UNSAFE":
            return SecurityDisposition(approved: false, message: explanatoryText)
        case "ABORT":
            return SecurityDisposition(approved: false, message: explanatoryText)
        default:
            return nil
        }
    }

    /// Renders a `file_edit` tool call's `old_string` / `new_string` arguments as a
    /// plain-text unified diff using the *same* `DiffGenerator` the channel-log UI
    /// uses. Returns nil when `toolParams` cannot be decoded or the strings are
    /// missing — in that case the prompt falls back to the raw-parameter form, which
    /// is what was being shown previously anyway. No double computation: this runs
    /// once per evaluation; the UI's `DiffView` runs separately on render.
    private static func fileEditDiffText(toolParams: String) -> String? {
        guard let data = toolParams.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oldString = obj["old_string"] as? String,
              let newString = obj["new_string"] as? String else {
            return nil
        }
        return DiffGenerator.renderAsText(old: oldString, new: newString)
    }

    /// Checks whether the target file of a file_write or file_edit tool call exists,
    /// and returns an informational note string for the evaluation prompt.
    private static func fileExistenceNote(toolParams: String, pathKey: String, toolName: String) -> String? {
        guard let data = toolParams.data(using: .utf8) else {
            return nil
        }

        let parsed: [String: Any]
        do {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            parsed = obj
        } catch {
            return nil
        }

        guard let path = parsed[pathKey] as? String,
              path.hasPrefix("/") else {
            return nil
        }

        let fm = FileManager.default
        let resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path

        if fm.fileExists(atPath: resolvedPath) {
            do {
                let attrs = try fm.attributesOfItem(atPath: resolvedPath)
                let size = (attrs[.size] as? UInt64) ?? 0
                let verb = toolName == "file_edit" ? "MODIFY" : "OVERWRITE"
                return "Note: The target file ALREADY EXISTS (size: \(size) bytes). This operation will \(verb) the existing file."
            } catch {
                return "Note: The target file exists but its attributes could not be read."
            }
        } else {
            return "Note: The target file does NOT currently exist — this is a new file creation."
        }
    }

    /// Maximum number of candidate paths to canonicalize per evaluation. A
    /// pathological task description full of path-shaped tokens shouldn't make
    /// `buildEvalPrompt` walk the disk thousands of times.
    static let maxPathResolutionCandidates: Int = 32

    /// Tool-parameter keys whose string values are content payloads, not paths.
    /// Paths inside these (e.g. a Markdown file mentioning `/etc/hosts`) must
    /// not be promoted into the resolution appendix.
    private static let pathResolutionContentKeys: Set<String> = [
        "content", "old_string", "new_string"
    ]

    /// Builds a "Path resolutions" appendix listing how path-shaped strings in
    /// the task description and tool parameters resolve through symlinks to
    /// canonical on-disk locations. Returns nil when no path was found whose
    /// canonical form differs from its as-written form — in that case the
    /// appendix would be pure noise.
    ///
    /// Without this, Jones compares raw strings: a task that says
    /// `~/cursor/foo/` and a tool call under
    /// `~/Documents/ncc_source/cursor/foo/...` (the symlink target) get flagged
    /// as a directory escape. The appendix shows the canonical paths so Jones
    /// can recognize the equivalence.
    static func pathResolutionAppendix(taskDescription: String?, toolName: String, toolParams: String) -> String? {
        var asWrittenInOrder: [String] = []
        var seen: Set<String> = []
        let appendCandidate: (String) -> Void = { raw in
            if seen.insert(raw).inserted {
                asWrittenInOrder.append(raw)
            }
        }

        if let description = taskDescription, !description.isEmpty {
            for raw in collectPathStringsFromText(description) {
                appendCandidate(raw)
                if asWrittenInOrder.count >= maxPathResolutionCandidates { break }
            }
        }

        if asWrittenInOrder.count < maxPathResolutionCandidates,
           let data = toolParams.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) {
            var fromJSON: [String] = []
            collectPathStringsFromJSON(obj, skipKeys: pathResolutionContentKeys, out: &fromJSON)
            for raw in fromJSON {
                appendCandidate(raw)
                if asWrittenInOrder.count >= maxPathResolutionCandidates { break }
            }
        }

        guard !asWrittenInOrder.isEmpty else { return nil }

        struct Resolution { let asWritten: String; let canonical: String; let symlinkTraversed: Bool }
        let fm = FileManager.default
        var resolutions: [Resolution] = []
        for asWritten in asWrittenInOrder {
            guard let expanded = expandToAbsolutePath(asWritten) else { continue }
            guard fm.fileExists(atPath: expanded) else { continue }
            let normalized = URL(fileURLWithPath: expanded).path
            guard let canonical = canonicalizeViaRealpath(expanded) else { continue }
            resolutions.append(Resolution(
                asWritten: asWritten,
                canonical: canonical,
                symlinkTraversed: canonical != normalized
            ))
        }

        guard resolutions.contains(where: { $0.symlinkTraversed }) else { return nil }

        var lines: [String] = []
        for r in resolutions {
            lines.append("  \(r.asWritten) → \(r.canonical)")
        }
        return """
            ## Path resolutions
            The following paths from the task description and/or tool parameters resolve to canonical on-disk locations (symlinks have been followed). Treat paths sharing a canonical location — or sharing a canonical prefix — as the SAME location for working-directory and scope checks.
            \(lines.joined(separator: "\n"))
            """
    }

    /// Walks a JSON value and collects string values that look like absolute
    /// paths (`/...`, `~/...`, `file://...`). Skips keys in `skipKeys` so that
    /// content payload fields like `content` / `new_string` cannot leak path
    /// tokens from inside arbitrary text into the resolution appendix.
    static func collectPathStringsFromJSON(_ value: Any, skipKeys: Set<String>, out: inout [String]) {
        switch value {
        case let dict as [String: Any]:
            for (key, child) in dict where !skipKeys.contains(key) {
                collectPathStringsFromJSON(child, skipKeys: skipKeys, out: &out)
            }
        case let array as [Any]:
            for child in array {
                collectPathStringsFromJSON(child, skipKeys: skipKeys, out: &out)
            }
        case let str as String:
            if str.hasPrefix("/") || str.hasPrefix("~/") || str.hasPrefix("file://") {
                out.append(str)
            }
        default:
            break
        }
    }

    /// Extracts path-shaped tokens from free-form text (typically a task
    /// description). Conservative heuristic — only matches strings that begin
    /// at a non-path character (or start of string) and start with `/`, `~/`,
    /// or `file://`. Trailing punctuation (`.,:;)]"'`) is stripped so a
    /// sentence like "see /tmp/foo." doesn't yield a path with a trailing dot.
    static func collectPathStringsFromText(_ text: String) -> [String] {
        let pattern = #"(?:^|[\s(\[<"'])(file://[^\s)\]<>"']+|~?/[^\s)\]<>"']+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsString = text as NSString
        let range = NSRange(location: 0, length: nsString.length)
        var results: [String] = []
        let trailingTrim = CharacterSet(charactersIn: ".,:;)]\"'")
        for match in regex.matches(in: text, range: range) {
            let captureRange = match.range(at: 1)
            guard captureRange.location != NSNotFound else { continue }
            var candidate = nsString.substring(with: captureRange)
            while let last = candidate.unicodeScalars.last, trailingTrim.contains(last) {
                candidate.removeLast()
            }
            if !candidate.isEmpty {
                results.append(candidate)
            }
        }
        return results
    }

    /// Returns the canonical absolute path for `path` via POSIX `realpath`.
    /// Used in preference to `URL.resolvingSymlinksInPath()` for Jones's
    /// equivalence checks because the URL-based call does not resolve macOS's
    /// well-known aliases (`/tmp → /private/tmp`, `/var → /private/var`),
    /// which would cause Jones to miss legitimate equivalences. Returns nil
    /// when realpath fails (e.g. path no longer exists).
    static func canonicalizeViaRealpath(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard let resolved = path.withCString({ realpath($0, &buffer) }) else {
            return nil
        }
        return String(cString: resolved)
    }

    /// Converts a path token to an absolute on-disk path string suitable for
    /// `FileManager.fileExists` / `realpath`. Handles `file://` URLs (with
    /// percent-encoding) and tilde expansion. Returns nil for inputs we
    /// can't confidently turn into an absolute path.
    static func expandToAbsolutePath(_ raw: String) -> String? {
        if raw.hasPrefix("file://") {
            return URL(string: raw)?.path
        }
        if raw.hasPrefix("~") {
            return NSString(string: raw).expandingTildeInPath
        }
        if raw.hasPrefix("/") {
            return raw
        }
        return nil
    }

    /// Posts a tool_request message to the channel so Jones's file reads appear in the transcript.
    private func postJonesFileReadToChannel(_ call: LLMToolCall) async {
        let path: String = {
            guard let data = call.arguments.data(using: .utf8),
                  let dict = try? JSONDecoder().decode([String: AnyCodable].self, from: data),
                  case .string(let p) = dict["path"] else {
                return call.arguments
            }
            return p
        }()

        await postToChannel(ChannelMessage(
            sender: .agent(.jones),
            content: "file_read: \(path)",
            metadata: [
                "messageKind": .string("tool_request"),
                "requestID": .string(call.id),
                "tool": .string("file_read"),
                "params": .string(call.arguments),
                "toolDescription": .string(Self.fileReadToolDef.description),
                "toolParameters": .string("")
            ]
        ))
    }

    /// Executes a file_read tool call for Jones without recording the read.
    /// Jones's reads must NOT count toward Brown's file_write gating.
    private func executeJonesFileRead(_ call: LLMToolCall) -> String {
        guard call.name == "file_read" else {
            return "Error: Unknown tool '\(call.name)'"
        }

        let args: [String: AnyCodable]
        do {
            args = try call.parsedArguments()
        } catch {
            return "Error: Invalid arguments — \(error.localizedDescription)"
        }

        guard case .string(let rawPath) = args["path"] else {
            return "Error: Missing required argument 'path'"
        }
        let path = (rawPath as NSString).expandingTildeInPath

        // Use the shared read logic (path restriction, content type detection, line-numbered output).
        return FileReadTool.readFileContent(at: path)
    }

    private static func parseToolParams(_ json: String) -> [String: AnyCodable]? {
        guard let data = json.data(using: .utf8) else { return nil }
        do {
            return try JSONDecoder().decode([String: AnyCodable].self, from: data)
        } catch {
            return nil
        }
    }
}
