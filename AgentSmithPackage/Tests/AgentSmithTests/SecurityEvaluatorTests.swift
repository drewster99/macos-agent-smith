import Testing
import Foundation
@testable import AgentSmithKit

@Suite("ToolExecutionTracker")
struct ToolExecutionTrackerTests {
    @Test("initial lookup returns false / nil")
    func initialState() async {
        let tracker = ToolExecutionTracker()
        #expect(await tracker.hasSucceeded(toolCallID: "x") == false)
        #expect(await tracker.hasFailed(toolCallID: "x") == false)
        #expect(await tracker.getExecutionStatus(toolCallID: "x") == nil)
    }

    @Test("recording success reports hasSucceeded only")
    func recordSuccess() async {
        let tracker = ToolExecutionTracker()
        await tracker.recordExecutionStatus(toolCallID: "abc", succeeded: true)
        #expect(await tracker.hasSucceeded(toolCallID: "abc"))
        #expect(await tracker.hasFailed(toolCallID: "abc") == false)
        #expect(await tracker.getExecutionStatus(toolCallID: "abc") == true)
    }

    @Test("recording failure reports hasFailed only")
    func recordFailure() async {
        let tracker = ToolExecutionTracker()
        await tracker.recordExecutionStatus(toolCallID: "abc", succeeded: false)
        #expect(await tracker.hasFailed(toolCallID: "abc"))
        #expect(await tracker.hasSucceeded(toolCallID: "abc") == false)
        #expect(await tracker.getExecutionStatus(toolCallID: "abc") == false)
    }

    @Test("later record overrides earlier record")
    func recordOverride() async {
        let tracker = ToolExecutionTracker()
        await tracker.recordExecutionStatus(toolCallID: "abc", succeeded: true)
        await tracker.recordExecutionStatus(toolCallID: "abc", succeeded: false)
        #expect(await tracker.hasFailed(toolCallID: "abc"))
        #expect(await tracker.hasSucceeded(toolCallID: "abc") == false)
    }

    @Test("status is per-tool-call-id, not shared")
    func independentEntries() async {
        let tracker = ToolExecutionTracker()
        await tracker.recordExecutionStatus(toolCallID: "a", succeeded: true)
        await tracker.recordExecutionStatus(toolCallID: "b", succeeded: false)
        #expect(await tracker.hasSucceeded(toolCallID: "a"))
        #expect(await tracker.hasFailed(toolCallID: "b"))
        #expect(await tracker.hasFailed(toolCallID: "a") == false)
        #expect(await tracker.hasSucceeded(toolCallID: "b") == false)
    }
}

/// Captures invocations of the abort closure for assertion.
actor AbortRecorder {
    struct Call: Sendable { let reason: String; let role: AgentRole }
    private(set) var calls: [Call] = []
    func record(reason: String, role: AgentRole) {
        calls.append(Call(reason: reason, role: role))
    }
}

@Suite("SecurityEvaluator")
struct SecurityEvaluatorTests {
    /// Builds an evaluator wired to a mock provider. Optional execution-tracker
    /// closures so individual tests can simulate "approved-but-failed" states
    /// without standing up the full ToolContext.
    private func makeEvaluator(
        responses: [LLMResponse],
        hasToolSucceeded: @escaping @Sendable (String) async -> Bool = { _ in false },
        hasToolFailed: @escaping @Sendable (String) async -> Bool = { _ in false }
    ) -> (SecurityEvaluator, MockLLMProvider, MessageChannel) {
        let provider = MockLLMProvider(responses: responses)
        let channel = MessageChannel()
        let evaluator = SecurityEvaluator(
            provider: provider,
            systemPrompt: "test system prompt",
            channel: channel,
            abort: { _, _ in },
            hasToolSucceeded: hasToolSucceeded,
            hasToolFailed: hasToolFailed
        )
        return (evaluator, provider, channel)
    }

    private func textResponse(_ text: String) -> LLMResponse {
        LLMResponse(text: text, toolCalls: [])
    }

    private func evaluate(
        _ evaluator: SecurityEvaluator,
        toolCallID: String? = nil,
        toolName: String = "bash",
        toolParams: String = "{\"command\":\"ls\"}"
    ) async -> SecurityDisposition {
        await evaluator.evaluate(
            toolName: toolName,
            toolParams: toolParams,
            toolDescription: "Run a shell command",
            toolParameterDefs: "",
            taskTitle: "Test task",
            taskID: UUID().uuidString,
            taskDescription: "Test desc",
            siblingCalls: nil,
            agentRoleName: "Brown",
            toolCallID: toolCallID
        )
    }

    // MARK: - Parser robustness (the failed-to-parse bug)

    @Test("clean SAFE first line is approved")
    func cleanSafe() async {
        let (evaluator, _, _) = makeEvaluator(responses: [textResponse("SAFE reading a project file")])
        let d = await evaluate(evaluator)
        #expect(d.approved)
        #expect(d.message == "reading a project file")
    }

    @Test("clean WARN first line denies with retry permission")
    func cleanWarn() async {
        let (evaluator, _, _) = makeEvaluator(responses: [textResponse("WARN possibly destructive")])
        let d = await evaluate(evaluator)
        #expect(d.approved == false)
        #expect(d.isWarning)
    }

    @Test("clean UNSAFE first line denies without warning")
    func cleanUnsafe() async {
        let (evaluator, _, _) = makeEvaluator(responses: [textResponse("UNSAFE dangerous rm")])
        let d = await evaluate(evaluator)
        #expect(d.approved == false)
        #expect(d.isWarning == false)
    }

    @Test("clean ABORT first line denies and triggers the abort closure")
    func cleanAbortTriggersAbort() async {
        let provider = MockLLMProvider(responses: [textResponse("ABORT immediate danger")])
        let channel = MessageChannel()
        let abortInvocations = AbortRecorder()
        let evaluator = SecurityEvaluator(
            provider: provider,
            systemPrompt: "test",
            channel: channel,
            abort: { reason, role in await abortInvocations.record(reason: reason, role: role) },
            hasToolSucceeded: { _ in false },
            hasToolFailed: { _ in false }
        )
        _ = await evaluate(evaluator)
        let calls = await abortInvocations.calls
        #expect(calls.count == 1)
        #expect(calls.first?.role == .jones)
    }

    @Test("bare ABORT with no reason still triggers the abort closure")
    func bareAbortTriggersAbort() async {
        let provider = MockLLMProvider(responses: [textResponse("ABORT")])
        let channel = MessageChannel()
        let abortInvocations = AbortRecorder()
        let evaluator = SecurityEvaluator(
            provider: provider,
            systemPrompt: "test",
            channel: channel,
            abort: { reason, role in await abortInvocations.record(reason: reason, role: role) },
            hasToolSucceeded: { _ in false },
            hasToolFailed: { _ in false }
        )
        _ = await evaluate(evaluator)
        let calls = await abortInvocations.calls
        #expect(calls.count == 1)
        #expect(calls.first?.role == .jones)
    }

    @Test("ABORT after preamble still triggers the abort closure")
    func abortWithPreambleTriggersAbort() async {
        let response = """
            Considering the danger here carefully...
            This is a destructive command targeting system files.

            ABORT will erase critical user data
            """
        let provider = MockLLMProvider(responses: [textResponse(response)])
        let channel = MessageChannel()
        let abortInvocations = AbortRecorder()
        let evaluator = SecurityEvaluator(
            provider: provider,
            systemPrompt: "test",
            channel: channel,
            abort: { reason, role in await abortInvocations.record(reason: reason, role: role) },
            hasToolSucceeded: { _ in false },
            hasToolFailed: { _ in false }
        )
        _ = await evaluate(evaluator)
        let calls = await abortInvocations.calls
        #expect(calls.count == 1)
    }

    @Test("verdict after preamble paragraph is parsed (the haiku bug)")
    func preambleThenVerdict() async {
        // This is the exact failure pattern observed in production with
        // claude-haiku-4-5: long chain-of-thought before the verdict line.
        let response = """
            Let me think about this carefully. The tool wants to run `ls`, which is read-only \
            and unlikely to cause problems. I should check the recent context to see if this \
            fits a reasonable pattern.

            SAFE listing a directory is read-only
            """
        let (evaluator, _, _) = makeEvaluator(responses: [textResponse(response)])
        let d = await evaluate(evaluator)
        #expect(d.approved)
        #expect(d.message == "listing a directory is read-only")
    }

    @Test("last verdict wins when keywords appear earlier in reasoning")
    func lastVerdictWins() async {
        // Earlier text mentions "UNSAFE" and "WARN" as words being weighed; the
        // final line is the actual verdict.
        let response = """
            I considered whether this is UNSAFE. I considered WARN.
            But on balance the action is fine.

            SAFE reasoning concluded benign
            """
        let (evaluator, _, _) = makeEvaluator(responses: [textResponse(response)])
        let d = await evaluate(evaluator)
        #expect(d.approved)
        #expect(d.message == "reasoning concluded benign")
    }

    @Test("verdict line with leading markdown bullet still parses")
    func markdownBulletPrefix() async {
        let (evaluator, _, _) = makeEvaluator(responses: [textResponse("- SAFE bullet-prefixed verdict")])
        let d = await evaluate(evaluator)
        #expect(d.approved)
    }

    @Test("totally unparseable response retries and falls back to denied")
    func unparseableFallsBack() async {
        // Five identical unparseable responses → exhaust retries → fallback.
        let junk = textResponse("I don't have a verdict for you. Sorry.")
        let (evaluator, provider, _) = makeEvaluator(responses: Array(repeating: junk, count: 5))
        let d = await evaluate(evaluator)
        #expect(d.approved == false)
        #expect(provider.callCount == 5)
    }

    @Test("first response unparseable, second is clean SAFE → approved")
    func retryRecovers() async {
        let (evaluator, provider, _) = makeEvaluator(responses: [
            textResponse("Just musing here, no verdict yet."),
            textResponse("SAFE second attempt landed clean")
        ])
        let d = await evaluate(evaluator)
        #expect(d.approved)
        #expect(provider.callCount == 2)
    }

    // MARK: - Output token budget

    @Test("evaluator does not override the provider's max-output-tokens")
    func tokenCapNotOverridden() async {
        // The evaluator must let Jones use its own configured output budget. A prior
        // hard 200-token override collided with extended thinking (the provider has to
        // raise max_tokens above the thinking budget), leaving no room for the verdict.
        let (evaluator, provider, _) = makeEvaluator(responses: [textResponse("SAFE ok")])
        _ = await evaluate(evaluator)
        #expect(provider.receivedMaxTokenOverrides == [nil])
    }

    // MARK: - Execution-outcome annotation (the new feature)

    /// Captures the prompt the provider sees on a target call.
    private final class PromptCapturingProvider: LLMProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [LLMResponse]
        var capturedPrompts: [String] = []
        init(responses: [LLMResponse]) { self.responses = responses }
        func send(messages: [LLMMessage], tools: [LLMToolDefinition], toolChoice: LLMToolChoice?, thinkingEffortOverride: String?, maxOutputTokensOverride: Int?) async throws -> LLMResponse {
            lock.withLock {
                if let userMsg = messages.last(where: { $0.role == .user }),
                   case .text(let text) = userMsg.content {
                    capturedPrompts.append(text)
                }
                let response = responses.removeFirst()
                return response
            }
        }
    }

    @Test("recent-calls section annotates an entry whose prior call FAILED")
    func annotatesFailedExecution() async {
        // Wire the evaluator to claim toolCallID "first" failed at execution time.
        let provider = PromptCapturingProvider(responses: [
            textResponse("SAFE first call ok"),
            textResponse("SAFE retry is fine")
        ])
        let channel = MessageChannel()
        let evaluator = SecurityEvaluator(
            provider: provider,
            systemPrompt: "sys",
            channel: channel,
            abort: { _, _ in },
            hasToolSucceeded: { _ in false },
            hasToolFailed: { id in id == "first" }
        )

        // 1st call: gets approved, then we pretend it ran and failed.
        _ = await evaluator.evaluate(
            toolName: "file_edit",
            toolParams: "{\"file_path\":\"/tmp/x\"}",
            toolDescription: "edit",
            toolParameterDefs: "",
            taskTitle: "t",
            taskID: UUID().uuidString,
            taskDescription: "d",
            siblingCalls: nil,
            agentRoleName: "Brown",
            toolCallID: "first"
        )

        // 2nd call: the prompt should now reference the prior call as FAILED.
        _ = await evaluator.evaluate(
            toolName: "file_edit",
            toolParams: "{\"file_path\":\"/tmp/x\"}",
            toolDescription: "edit",
            toolParameterDefs: "",
            taskTitle: "t",
            taskID: UUID().uuidString,
            taskDescription: "d",
            siblingCalls: nil,
            agentRoleName: "Brown",
            toolCallID: "second"
        )

        #expect(provider.capturedPrompts.count == 2)
        let secondPrompt = provider.capturedPrompts[1]
        #expect(secondPrompt.contains("[executed: FAILED"))
        #expect(secondPrompt.contains("retry of an identical request is a legitimate response"))
    }

    @Test("recent-calls section annotates a succeeded prior call")
    func annotatesSucceededExecution() async {
        let provider = PromptCapturingProvider(responses: [
            textResponse("SAFE first ok"),
            textResponse("SAFE second ok")
        ])
        let channel = MessageChannel()
        let evaluator = SecurityEvaluator(
            provider: provider,
            systemPrompt: "sys",
            channel: channel,
            abort: { _, _ in },
            hasToolSucceeded: { id in id == "first" },
            hasToolFailed: { _ in false }
        )

        _ = await evaluator.evaluate(
            toolName: "bash", toolParams: "{\"command\":\"ls\"}",
            toolDescription: "", toolParameterDefs: "",
            taskTitle: "t", taskID: UUID().uuidString, taskDescription: "d",
            siblingCalls: nil, agentRoleName: "Brown", toolCallID: "first"
        )
        _ = await evaluator.evaluate(
            toolName: "bash", toolParams: "{\"command\":\"pwd\"}",
            toolDescription: "", toolParameterDefs: "",
            taskTitle: "t", taskID: UUID().uuidString, taskDescription: "d",
            siblingCalls: nil, agentRoleName: "Brown", toolCallID: "second"
        )

        let secondPrompt = provider.capturedPrompts[1]
        #expect(secondPrompt.contains("[executed: succeeded]"))
    }

    @Test("entry with no recorded outcome is annotated as not-yet-recorded")
    func annotatesUnrecordedExecution() async {
        let provider = PromptCapturingProvider(responses: [
            textResponse("SAFE first"),
            textResponse("SAFE second")
        ])
        let channel = MessageChannel()
        let evaluator = SecurityEvaluator(
            provider: provider,
            systemPrompt: "sys",
            channel: channel,
            abort: { _, _ in },
            hasToolSucceeded: { _ in false },
            hasToolFailed: { _ in false }
        )

        _ = await evaluator.evaluate(
            toolName: "bash", toolParams: "{\"command\":\"ls\"}",
            toolDescription: "", toolParameterDefs: "",
            taskTitle: "t", taskID: UUID().uuidString, taskDescription: "d",
            siblingCalls: nil, agentRoleName: "Brown", toolCallID: "first"
        )
        _ = await evaluator.evaluate(
            toolName: "bash", toolParams: "{\"command\":\"pwd\"}",
            toolDescription: "", toolParameterDefs: "",
            taskTitle: "t", taskID: UUID().uuidString, taskDescription: "d",
            siblingCalls: nil, agentRoleName: "Brown", toolCallID: "second"
        )

        let secondPrompt = provider.capturedPrompts[1]
        #expect(secondPrompt.contains("[executed: not yet recorded]"))
    }

    @Test("entry without a tool-call-id is rendered without an outcome bracket")
    func entryWithoutIDHasNoBracket() async {
        let provider = PromptCapturingProvider(responses: [
            textResponse("SAFE first"),
            textResponse("SAFE second")
        ])
        let channel = MessageChannel()
        let evaluator = SecurityEvaluator(
            provider: provider,
            systemPrompt: "sys",
            channel: channel,
            abort: { _, _ in },
            hasToolSucceeded: { _ in false },
            hasToolFailed: { _ in false }
        )

        _ = await evaluator.evaluate(
            toolName: "bash", toolParams: "{\"command\":\"ls\"}",
            toolDescription: "", toolParameterDefs: "",
            taskTitle: "t", taskID: UUID().uuidString, taskDescription: "d",
            siblingCalls: nil, agentRoleName: "Brown", toolCallID: nil
        )
        _ = await evaluator.evaluate(
            toolName: "bash", toolParams: "{\"command\":\"pwd\"}",
            toolDescription: "", toolParameterDefs: "",
            taskTitle: "t", taskID: UUID().uuidString, taskDescription: "d",
            siblingCalls: nil, agentRoleName: "Brown", toolCallID: nil
        )

        let secondPrompt = provider.capturedPrompts[1]
        // The recent-calls line for the prior call should not contain any
        // execution-outcome annotation when the tool call id is missing.
        #expect(secondPrompt.contains("[executed:") == false)
    }

    // MARK: - WARN auto-retry

    @Test("identical retry of a WARN'd request is auto-approved without an LLM call")
    func warnAutoRetry() async {
        let (evaluator, provider, _) = makeEvaluator(responses: [
            textResponse("WARN suspicious")
        ])
        let d1 = await evaluate(evaluator, toolName: "bash", toolParams: "{\"command\":\"rm -rf /tmp/foo\"}")
        #expect(d1.approved == false)
        #expect(d1.isWarning)
        #expect(provider.callCount == 1)

        let d2 = await evaluate(evaluator, toolName: "bash", toolParams: "{\"command\":\"rm -rf /tmp/foo\"}")
        #expect(d2.approved)
        #expect(d2.isAutoApproval)
        // No second LLM call — pending-warn slot consumed.
        #expect(provider.callCount == 1)
    }

    // MARK: - file_edit unified-diff in prompt

    @Test("file_edit prompt fed to Jones contains the unified diff section")
    func fileEditPromptIncludesUnifiedDiff() async {
        let provider = PromptCapturingProvider(responses: [textResponse("SAFE diff confirmed")])
        let channel = MessageChannel()
        let evaluator = SecurityEvaluator(
            provider: provider,
            systemPrompt: "sys",
            channel: channel,
            abort: { _, _ in },
            hasToolSucceeded: { _ in false },
            hasToolFailed: { _ in false }
        )

        let params = """
            {"file_path":"/tmp/example.swift","old_string":"let value = 1","new_string":"let value = 2"}
            """

        _ = await evaluator.evaluate(
            toolName: "file_edit",
            toolParams: params,
            toolDescription: "edit",
            toolParameterDefs: "",
            taskTitle: "t",
            taskID: UUID().uuidString,
            taskDescription: "d",
            siblingCalls: nil,
            agentRoleName: "Brown",
            toolCallID: "edit-1"
        )

        #expect(provider.capturedPrompts.count == 1)
        let prompt = provider.capturedPrompts[0]
        #expect(prompt.contains("## Resulting diff"))
        #expect(prompt.contains("- let value = 1"))
        #expect(prompt.contains("+ let value = 2"))

        let history = await evaluator.evaluationHistory()
        #expect(history.last?.prompt.contains("## Resulting diff") == true)
    }

    @Test("non-file_edit tool calls do not get a Resulting diff section")
    func nonFileEditPromptHasNoDiffSection() async {
        let provider = PromptCapturingProvider(responses: [textResponse("SAFE ok")])
        let channel = MessageChannel()
        let evaluator = SecurityEvaluator(
            provider: provider,
            systemPrompt: "sys",
            channel: channel,
            abort: { _, _ in },
            hasToolSucceeded: { _ in false },
            hasToolFailed: { _ in false }
        )

        _ = await evaluator.evaluate(
            toolName: "bash",
            toolParams: "{\"command\":\"ls\"}",
            toolDescription: "",
            toolParameterDefs: "",
            taskTitle: "t",
            taskID: UUID().uuidString,
            taskDescription: "d",
            siblingCalls: nil,
            agentRoleName: "Brown",
            toolCallID: nil
        )

        #expect(provider.capturedPrompts[0].contains("## Resulting diff") == false)
    }
}
