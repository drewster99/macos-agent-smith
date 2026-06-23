import Testing
import Foundation
import SwiftLLMKit
@testable import AgentSmithKit

/// Closes the "in-app behavior" requirement WITHOUT the GUI: it drives a REAL Brown `AgentActor`
/// through the live agent loop (via `MockLLMProvider`) so the agent actually *invokes*
/// `web_search` / `instant_answer` and receives their results, and it exercises the REAL Jones
/// `SecurityEvaluator` gating those same tools (approve on SAFE, deny on UNSAFE). No network
/// (stub backend / `URLProtocolStub`), no LLM credits, no window automation — the substance of
/// "Brown calls the tools through the live loop and Jones gates them," made deterministic.
@Suite("Web tools agent loop", .serialized)
struct WebToolsAgentLoopTests {

    private struct StubBackend: WebSearchBackend {
        let identifier = "stub"
        let displayName = "Stub"
        func search(query: String, limit: Int) async throws -> [WebSearchResult] {
            [WebSearchResult(title: "Swift.org", url: "https://swift.org", snippet: "The Swift language")]
        }
    }

    private static func brownConfig() -> AgentConfiguration {
        AgentConfiguration(
            role: .brown,
            llmConfig: ModelConfiguration(
                name: "test", providerID: "test", modelID: "test-model",
                maxOutputTokens: 1024, maxContextTokens: 100_000
            ),
            systemPrompt: "test"
        )
    }

    private final class HistoryRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var latest: [LLMMessage] = []
        func update(_ messages: [LLMMessage]) { lock.lock(); defer { lock.unlock() }; latest = messages }
        var snapshot: [LLMMessage] { lock.lock(); defer { lock.unlock() }; return latest }
    }

    /// Drives a Brown `AgentActor` whose first LLM response is `toolCall`, then empty responses
    /// so the loop terminates. Returns the final conversation history.
    private func runBrown(tool: any AgentTool, toolCall: LLMToolCall) async -> [LLMMessage] {
        let channel = MessageChannel()
        let taskStore = TaskStore()
        let agentID = UUID()
        let context = TestToolContext.make(agentID: agentID, agentRole: .brown, channel: channel, taskStore: taskStore)

        let provider = MockLLMProvider(responses: [
            LLMResponse(toolCalls: [toolCall]),
            LLMResponse(text: ""), LLMResponse(text: ""),
            LLMResponse(text: ""), LLMResponse(text: "")
        ])
        let agent = AgentActor(
            id: agentID, configuration: Self.brownConfig(), provider: provider,
            tools: [tool], toolContext: context
        )
        let history = HistoryRecorder()
        await agent.setOnContextChanged { messages in history.update(messages) }

        let task = await taskStore.addTask(title: "agent-loop test", description: "drive a web tool")
        await taskStore.updateStatus(id: task.id, status: .running)
        await taskStore.assignAgent(taskID: task.id, agentID: agentID)
        await agent.start(initialInstruction: "go")

        let deadline = Date().addingTimeInterval(3.0)
        while await agent.running, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        await agent.stop()
        return history.snapshot
    }

    private func toolResult(in history: [LLMMessage], callID: String) -> String? {
        for message in history where message.role == .tool {
            if case .toolResult(let id, let content) = message.content, id == callID {
                return content
            }
        }
        return nil
    }

    // MARK: - Brown actually invokes the tools through the live loop

    @Test("Brown's live agent loop invokes web_search and receives results")
    func brownInvokesWebSearch() async {
        let call = LLMToolCall(id: "ws-1", name: "web_search", arguments: #"{"query":"swift"}"#)
        let history = await runBrown(tool: WebSearchTool(backend: StubBackend()), toolCall: call)
        let result = toolResult(in: history, callID: "ws-1")
        #expect(result != nil, "web_search never executed through Brown's agent loop")
        #expect(result?.contains("Swift.org") == true)
        #expect(result?.contains("https://swift.org") == true)
    }

    @Test("Brown's live agent loop invokes instant_answer and receives an entity summary")
    func brownInvokesInstantAnswer() async {
        let service = DuckDuckGoInstantAnswerService(session: URLProtocolStub.makeSession(statusCode: 200, body: Data("""
        { "Heading": "Swift", "AbstractText": "A language.", "AbstractSource": "Wikipedia",
          "AbstractURL": "https://en.wikipedia.org/wiki/Swift", "Type": "A" }
        """.utf8)))
        let call = LLMToolCall(id: "ia-1", name: "instant_answer", arguments: #"{"query":"Swift"}"#)
        let history = await runBrown(tool: InstantAnswerTool(service: service), toolCall: call)
        let result = toolResult(in: history, callID: "ia-1")
        #expect(result != nil, "instant_answer never executed through Brown's agent loop")
        #expect(result?.contains("Swift") == true)
    }

    // MARK: - Jones gates the tools (real SecurityEvaluator)

    private func makeJones(verdict: String) -> SecurityEvaluator {
        SecurityEvaluator(
            provider: MockLLMProvider(responses: [LLMResponse(text: verdict)]),
            systemPrompt: "You are a security gatekeeper. Reply SAFE/WARN/UNSAFE/ABORT.",
            channel: MessageChannel(),
            abort: { _, _ in },
            hasToolSucceeded: { _ in false },
            hasToolFailed: { _ in false }
        )
    }

    private func evaluate(_ jones: SecurityEvaluator, tool: any AgentTool, params: String) async -> SecurityDisposition {
        await jones.evaluate(
            toolName: tool.name,
            toolParams: params,
            toolDescription: tool.toolDescription,
            toolParameterDefs: "",
            taskTitle: "t",
            taskID: nil,
            taskDescription: "d",
            siblingCalls: nil,
            agentRoleName: "Brown",
            toolCallID: "call-1"
        )
    }

    @Test("Jones approves web_search on a SAFE verdict")
    func jonesApprovesWebSearch() async {
        let disposition = await evaluate(makeJones(verdict: "SAFE"), tool: WebSearchTool(), params: #"{"query":"swift"}"#)
        #expect(disposition.approved)
    }

    @Test("Jones denies web_search on an UNSAFE verdict")
    func jonesDeniesWebSearch() async {
        let disposition = await evaluate(makeJones(verdict: "UNSAFE: not allowed"), tool: WebSearchTool(), params: #"{"query":"swift"}"#)
        #expect(!disposition.approved)
    }

    @Test("Jones approves instant_answer on a SAFE verdict")
    func jonesApprovesInstantAnswer() async {
        let disposition = await evaluate(makeJones(verdict: "SAFE"), tool: InstantAnswerTool(), params: #"{"query":"Swift"}"#)
        #expect(disposition.approved)
    }
}
