import Testing
import Foundation
import SwiftLLMKit
@testable import AgentSmithKit

/// Every tool call in a response gets exactly one result, even when the provider repeats an id.
///
/// A call id is provider data: some servers emit an empty id, or reuse one, inside a single
/// response. The run loop used to track which calls had been answered in a `Set<String>` of ids, so
/// when a turn ended early (stop, a lifecycle handoff) a second call carrying an already-answered id
/// looked answered too, got no placeholder, and the history was left with a `tool_use` and no
/// `tool_result` — a request every provider rejects. Tracking is by position now.
@Suite("Duplicate tool-call ids")
struct DuplicateToolCallIDTests {

    private static let sharedEngine = SemanticSearchEngine()

    /// Holds its caller until the test releases it, so the test can stop the agent mid-batch.
    private actor Gate {
        private var arrived = false
        private var release: CheckedContinuation<Void, Never>?
        private var released = false

        func arriveAndWait() async {
            arrived = true
            guard !released else { return }
            await withCheckedContinuation { release = $0 }
        }

        func hasArrived() -> Bool { arrived }

        func open() {
            released = true
            release?.resume()
            release = nil
        }
    }

    private struct GatedTool: AgentTool {
        let name = "gated_probe"
        let toolDescription = "Test stub: waits for the test to release it."
        let parameters: [String: AnyCodable] = [
            "type": .string("object"),
            "properties": .dictionary([:]),
            "required": .array([])
        ]
        let gate: Gate

        func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
            await gate.arriveAndWait()
            return .success("done")
        }
    }

    @Test("a second call reusing an answered id still gets its own result when the turn ends early")
    func repeatedIDGetsPlaceholder() async throws {
        let gate = Gate()
        let llmConfig = ModelConfiguration(
            name: "test", providerID: "test", modelID: "test-model",
            maxOutputTokens: 1024, maxContextTokens: 100_000
        )
        let agentID = UUID()
        let context = ToolContext(
            agentID: agentID,
            agentRole: .smith,
            channel: MessageChannel(),
            taskStore: TaskStore(),
            spawnBrown: { _ in nil },
            terminateAgent: { _, _ in false },
            abort: { _, _ in },
            agentRoleForID: { _ in .smith },
            memoryStore: MemoryStore(engine: Self.sharedEngine),
            setToolExecutionStatus: { _, _ in },
            hasToolSucceeded: { _ in false },
            hasToolFailed: { _ in false }
        )
        // Both calls carry the SAME id, as a server that numbers calls per response or leaves the
        // id empty would send them.
        let response = LLMResponse(toolCalls: [
            LLMToolCall(id: "dup", name: "gated_probe", arguments: "{}"),
            LLMToolCall(id: "dup", name: "gated_probe", arguments: "{\"second\": true}")
        ])
        let agent = AgentActor(
            id: agentID,
            configuration: AgentConfiguration(role: .smith, llmConfig: llmConfig, systemPrompt: "test-system"),
            provider: MockLLMProvider(responses: [response, LLMResponse(text: "ok")]),
            tools: [GatedTool(gate: gate)],
            toolContext: context
        )
        await agent.setSecurityEvaluator(SecurityEvaluator(
            provider: MockLLMProvider(responses: Array(repeating: LLMResponse(text: "SAFE: test"), count: 10)),
            systemPrompt: "security gatekeeper",
            channel: MessageChannel(),
            abort: { _, _ in },
            hasToolSucceeded: { _ in false },
            hasToolFailed: { _ in false }
        ))
        await agent.appendUserMessage("probe twice")
        await agent.start()

        let deadline = Date().addingTimeInterval(5)
        while await gate.hasArrived() == false, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await gate.hasArrived(), "the first call never started")

        // Stop while the first call is running, then let it finish: the loop must not start the
        // second call, and must answer it with a placeholder.
        let stopping = Task { await agent.stop() }
        await gate.open()
        await stopping.value

        let history = await agent.contextSnapshot()
        let callCount = history.reduce(0) { count, message in
            if case .toolCalls(let calls) = message.content { return count + calls.count }
            if case .mixed(_, let calls) = message.content { return count + calls.count }
            return count
        }
        let resultCount = history.filter {
            if case .toolResult = $0.content { return true }
            return false
        }.count
        #expect(callCount == 2)
        #expect(resultCount == 2, "a call that reused an answered id was left without a result")
    }
}
