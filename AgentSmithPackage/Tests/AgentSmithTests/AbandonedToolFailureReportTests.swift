import Testing
import Foundation
import SwiftLLMKit
@testable import AgentSmithKit

/// An agent that goes quiet while a tool is still failing must SAY SO.
///
/// The 2026-09-20 failure: Smith called `create_task` seven times, was rejected every time, then
/// moved on to the user's next message and never mentioned the first. Neither existing breaker
/// fired — the identical-call breaker resets whenever the arguments differ (they did, every
/// time), and the failure-streak breaker only trips at ten. The mid-streak correction does tell
/// the model to "report the blocker"; the model ignored it, which is the whole reason this cannot
/// be left to the model.
///
/// The signal is structural: an unresolved entry in `toolFailureStreaks` at the moment the run
/// loop parks. A streak clears only when that tool SUCCEEDS, so surviving to the idle transition
/// means the failures were never resolved. Nothing here reads what the model wrote.
@Suite("Abandoned tool-failure reporting")
struct AbandonedToolFailureReportTests {

    private static let sharedEngine = SemanticSearchEngine()

    /// Fails every time with a fixed message — standing in for `create_task` rejecting a sentinel.
    private struct AlwaysFailingTool: AgentTool {
        let name = "create_task"
        let toolDescription = "Test stub: always fails."
        let parameters: [String: AnyCodable] = [
            "type": .string("object"),
            "properties": .dictionary([:]),
            "required": .array([])
        ]
        static let failureText = "template_inputs are valid only when is_template is true."

        func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
            .failure(Self.failureText)
        }
    }

    /// Fails, then succeeds once, then fails again — so one agent run contains TWO separate
    /// streaks with a success between them.
    private actor FlakyCallCounter {
        private var seen = 0
        /// The 7th call (index 6) succeeds; everything else fails.
        func nextSucceeds() -> Bool {
            defer { seen += 1 }
            return seen == 6
        }
    }

    private struct FlakyTool: AgentTool {
        let name = "create_task"
        let toolDescription = "Test stub: fails, succeeds once, fails again."
        let parameters: [String: AnyCodable] = [
            "type": .string("object"),
            "properties": .dictionary([:]),
            "required": .array([])
        ]
        let counter: FlakyCallCounter

        func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
            await counter.nextSucceeds()
                ? .success("Task created.")
                : .failure(AlwaysFailingTool.failureText)
        }
    }

    /// Succeeds every time, to prove a resolved streak reports nothing.
    private struct AlwaysSucceedingTool: AgentTool {
        let name = "create_task"
        let toolDescription = "Test stub: always succeeds."
        let parameters: [String: AnyCodable] = [
            "type": .string("object"),
            "properties": .dictionary([:]),
            "required": .array([])
        ]

        func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
            .success("Task created.")
        }
    }

    /// Approves everything, so the stub tool actually RUNS and fails on its own terms — which is
    /// the shape of the real incident. Without an evaluator every call is blocked before
    /// execution, and the streak would be measuring the gate instead of the tool.
    private func approvingEvaluator() -> SecurityEvaluator {
        SecurityEvaluator(
            provider: MockLLMProvider(
                responses: Array(repeating: LLMResponse(text: "SAFE: fine for test"), count: 40)
            ),
            systemPrompt: "security gatekeeper",
            channel: MessageChannel(),
            abort: { _, _ in },
            hasToolSucceeded: { _ in false },
            hasToolFailed: { _ in false }
        )
    }

    private func makeAgent(
        tool: any AgentTool,
        callCount: Int,
        channel: MessageChannel,
        script: [LLMResponse]? = nil
    ) -> AgentActor {
        let llmConfig = ModelConfiguration(
            name: "test", providerID: "test", modelID: "test-model",
            maxOutputTokens: 1024, maxContextTokens: 100_000
        )
        let config = AgentConfiguration(role: .smith, llmConfig: llmConfig, systemPrompt: "test-system")

        // The model varies its arguments every time, exactly as the live one did — which is why
        // the identical-call breaker never fires. Then it falls silent (a text-only turn), which
        // is the agent "moving on".
        var responses: [LLMResponse] = (0..<callCount).map { index in
            LLMResponse(toolCalls: [
                LLMToolCall(id: "call-\(index)", name: tool.name, arguments: "{\"attempt\": \(index)}")
            ])
        }
        responses.append(LLMResponse(text: Self.finalTurnText))
        let scriptedResponses = script ?? responses

        let agentID = UUID()
        let context = ToolContext(
            agentID: agentID,
            agentRole: .smith,
            channel: channel,
            taskStore: TaskStore(),
            spawnBrown: { nil },
            terminateAgent: { _, _ in false },
            abort: { _, _ in },
            agentRoleForID: { _ in .smith },
            memoryStore: MemoryStore(engine: Self.sharedEngine),
            setToolExecutionStatus: { _, _ in },
            hasToolSucceeded: { _ in false },
            hasToolFailed: { _ in false }
        )
        return AgentActor(
            id: agentID, configuration: config,
            provider: MockLLMProvider(responses: scriptedResponses),
            tools: [tool], toolContext: context
        )
    }

    /// The agent's last scripted turn — its arrival means the run is over and any report has
    /// either been posted or never will be. Waiting on THIS rather than on a fixed timeout is
    /// what keeps the negative cases fast and deterministic: a test that expects no message must
    /// not spend its whole budget proving a negative by exhaustion.
    private static let finalTurnText = "I'll look at something else."

    private func runAndCollect(
        tool: any AgentTool, callCount: Int, timeout: TimeInterval = 5.0
    ) async -> [ChannelMessage] {
        let channel = MessageChannel()
        let agent = makeAgent(tool: tool, callCount: callCount, channel: channel)
        await agent.setSecurityEvaluator(approvingEvaluator())
        await agent.appendUserMessage("Look into the MCP repo and file a task.")
        await agent.start()

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let posted = await channel.allMessages()
            let reported = posted.contains { $0.recipient == .user && $0.severity == .error }
            let finished = posted.contains { $0.content.contains(Self.finalTurnText) }
            if reported || finished { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        // The report is posted as the loop parks, which is just after the final turn lands.
        try? await Task.sleep(for: .milliseconds(120))
        await agent.stop()
        return await channel.allMessages()
    }

    /// The regression, end to end.
    @Test("An agent that goes quiet mid-streak tells the user, naming the tool and the error")
    func abandonedStreakIsReportedToUser() async throws {
        let posted = await runAndCollect(tool: AlwaysFailingTool(), callCount: 6)

        let reports = posted.filter { $0.recipient == .user && $0.severity == .error }
        #expect(reports.count == 1, "expected exactly one abandoned-failure report, got \(reports.count)" as Comment)

        let report = try #require(reports.first)
        #expect(report.content.contains("create_task"))
        #expect(report.toolName == "create_task")
        // The user has to be told WHY, not just that something failed.
        #expect(report.content.contains(AlwaysFailingTool.failureText))
        // `.error` is what carries it through whatever else the user has filtered.
        #expect(report.severity == .error)
    }

    /// Below the threshold, a couple of failures are ordinary and must stay quiet.
    @Test("A short failure run is not reported")
    func shortStreakIsNotReported() async throws {
        let posted = await runAndCollect(tool: AlwaysFailingTool(), callCount: 2)
        #expect(posted.contains(where: { $0.recipient == .user && $0.severity == .error }) == false)
    }

    /// A tool that succeeds clears its streak, so going idle reports nothing.
    @Test("A succeeding tool produces no report")
    func successfulToolIsNotReported() async throws {
        let posted = await runAndCollect(tool: AlwaysSucceedingTool(), callCount: 6)
        #expect(posted.contains(where: { $0.recipient == .user && $0.severity == .error }) == false)
    }

    /// A tool that fails, SUCCEEDS (clearing the streak), then fails again must report the second
    /// run too. The "already told them" flag lives inside the streak precisely so clearing one
    /// clears the other; as a parallel set it would have suppressed this second report forever.
    @Test("A later streak on the same tool reports again after a success clears the first")
    func laterStreakReportsAgain() async throws {
        let channel = MessageChannel()
        let tool = FlakyTool(counter: FlakyCallCounter())
        // 6 failures → idle (report 1) → 1 success (clears the streak) → 6 more failures → idle.
        var script: [LLMResponse] = (0..<6).map {
            LLMResponse(toolCalls: [LLMToolCall(id: "a-\($0)", name: tool.name, arguments: "{\"n\": \($0)}")])
        }
        script.append(LLMResponse(text: Self.finalTurnText))
        script += (0..<7).map {
            LLMResponse(toolCalls: [LLMToolCall(id: "b-\($0)", name: tool.name, arguments: "{\"m\": \($0)}")])
        }
        script.append(LLMResponse(text: Self.finalTurnText))

        let agent = makeAgent(tool: tool, callCount: 0, channel: channel, script: script)
        await agent.setSecurityEvaluator(approvingEvaluator())
        await agent.appendUserMessage("go")
        await agent.start()

        let deadline = Date().addingTimeInterval(8.0)
        while Date() < deadline {
            let reports = await channel.allMessages()
                .filter { $0.recipient == .user && $0.severity == .error }
            if reports.count >= 2 { break }
            // Keep waking it so it processes the second half of the script after idling.
            await agent.appendUserMessage("continue")
            try? await Task.sleep(for: .milliseconds(60))
        }
        await agent.stop()

        let reports = await channel.allMessages()
            .filter { $0.recipient == .user && $0.severity == .error }
        #expect(reports.count == 2, "a second streak must report again, got \(reports.count)" as Comment)
    }

    /// The worst case: a tool that never once works, hitting the stop-threshold breaker. That
    /// branch idles the agent AND clears the streak, so clearing before reporting left the single
    /// most serious case as the only one with no user-addressed message — just a system row.
    @Test("Hitting the stop-threshold breaker still reports to the user")
    func stopThresholdBreakerReportsToUser() async throws {
        let channel = MessageChannel()
        let tool = AlwaysFailingTool()
        // More calls than the stop threshold (10), so the breaker fires.
        var script: [LLMResponse] = (0..<12).map {
            LLMResponse(toolCalls: [LLMToolCall(id: "c-\($0)", name: tool.name, arguments: "{\"n\": \($0)}")])
        }
        script.append(LLMResponse(text: Self.finalTurnText))

        let agent = makeAgent(tool: tool, callCount: 0, channel: channel, script: script)
        await agent.setSecurityEvaluator(approvingEvaluator())
        await agent.appendUserMessage("go")
        await agent.start()

        let deadline = Date().addingTimeInterval(6.0)
        while Date() < deadline {
            let posted = await channel.allMessages()
            if posted.contains(where: { $0.recipient == .user && $0.severity == .error }) { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        await agent.stop()

        let posted = await channel.allMessages()
        let reports = posted.filter { $0.recipient == .user && $0.severity == .error }
        #expect(reports.count == 1, "the breaker case must still reach the user, got \(reports.count)" as Comment)
        #expect(reports.first?.toolName == "create_task")
        // The system row stays too — it says something different (the loop was broken).
        #expect(posted.contains { $0.sender == .system && $0.content.contains("Breaking loop") })
    }

    /// With NO evaluator every call is blocked before execution — fail-closed, by design. That
    /// path returned without recording the outcome, so the one state in which every call fails
    /// was also the one state in which no streak accumulated: neither circuit breaker could fire,
    /// and the agent would retry forever against a gate that can never open.
    @Test("Calls blocked for a missing evaluator still build a streak and get reported")
    func blockedForMissingEvaluatorIsReported() async throws {
        let channel = MessageChannel()
        // Deliberately NO setSecurityEvaluator — this is the unconfigured state.
        let agent = makeAgent(tool: AlwaysSucceedingTool(), callCount: 6, channel: channel)
        await agent.appendUserMessage("do the thing")
        await agent.start()

        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            let posted = await channel.allMessages()
            if posted.contains(where: { $0.recipient == .user && $0.severity == .error }) { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        await agent.stop()

        let reports = await channel.allMessages()
            .filter { $0.recipient == .user && $0.severity == .error }
        #expect(reports.count == 1, "a permanently-blocked tool must be reported, got \(reports.count)" as Comment)
        // Even a tool that WOULD have succeeded: it never ran, and that is what the user is told.
        #expect(reports.first?.toolName == "create_task")
    }

    /// Reported once per streak — an agent idling repeatedly must not re-report the same run.
    @Test("One streak yields one report, however often the agent idles")
    func streakIsReportedOnlyOnce() async throws {
        let channel = MessageChannel()
        let agent = makeAgent(tool: AlwaysFailingTool(), callCount: 6, channel: channel)
        await agent.setSecurityEvaluator(approvingEvaluator())
        await agent.appendUserMessage("first request")
        await agent.start()

        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            let posted = await channel.allMessages()
            if posted.contains(where: { $0.recipient == .user && $0.severity == .error }) { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        // Wake it again; it idles a second time with the same unresolved streak.
        await agent.appendUserMessage("second request")
        try? await Task.sleep(for: .milliseconds(400))
        await agent.stop()

        let reports = await channel.allMessages()
            .filter { $0.recipient == .user && $0.severity == .error }
        #expect(reports.count == 1, "the same streak must report once, got \(reports.count)")
    }
}
