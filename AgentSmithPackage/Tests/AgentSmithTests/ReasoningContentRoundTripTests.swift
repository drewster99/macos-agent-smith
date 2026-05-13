import Testing
import Foundation
@testable import AgentSmithKit
import SwiftLLMKit

/// Asserts that `AgentActor.handleResponse` preserves `LLMResponse.reasoning`
/// on the assistant message it appends to conversation history, so that a
/// subsequent provider call can replay `reasoning_content` when the model's
/// `BehaviorFlags.replayReasoningContent` is set (DeepSeek V4 Pro and friends
/// fail with HTTP 400 otherwise).
///
/// We exercise three response shapes — text-only, tool-call-only, mixed — and
/// for each verify that `response.reasoning` makes it onto the corresponding
/// `LLMMessage.reasoning` field in `conversationHistory`. The provider-side
/// emission is covered by `OpenAIReasoningContentReplayTests` in swift-llm-kit.
@Suite("Reasoning content round-trip", .serialized)
struct ReasoningContentRoundTripTests {

    private static let sharedEngine = SemanticSearchEngine()

    /// Provider that returns a single canned response, then signals
    /// "no more work" by returning an empty response thereafter. We use this
    /// to drive exactly one LLM turn through the run loop and then stop.
    private final class CannedResponseProvider: LLMProvider, @unchecked Sendable {
        let lock = NSLock()
        private var _hasReturnedCanned = false
        let canned: LLMResponse

        init(_ canned: LLMResponse) { self.canned = canned }

        func send(
            messages: [LLMMessage],
            tools: [LLMToolDefinition],
            maxOutputTokensOverride: Int?
        ) async throws -> LLMResponse {
            let isFirst = lock.withLock { () -> Bool in
                if !_hasReturnedCanned {
                    _hasReturnedCanned = true
                    return true
                }
                return false
            }
            if isFirst { return canned }
            // Subsequent calls: hang so we can inspect history right after the
            // first turn settles, without the run loop ploughing on into more
            // calls or empty-response strikes.
            try await Task.sleep(for: .seconds(60))
            return LLMResponse(text: nil, toolCalls: [], reasoning: nil, usage: nil)
        }
    }

    private static func makeBrown(
        provider: any LLMProvider,
        channel: MessageChannel,
        taskStore: TaskStore
    ) -> (AgentActor, UUID) {
        let memoryStore = MemoryStore(engine: Self.sharedEngine)
        let agentID = UUID()
        let config = AgentConfiguration(
            role: .brown,
            llmConfig: ModelConfiguration(
                name: "test", providerID: "test", modelID: "test-model",
                maxOutputTokens: 4096, maxContextTokens: 128_000
            ),
            systemPrompt: "test brown"
        )
        let context = ToolContext(
            agentID: agentID,
            agentRole: .brown,
            channel: channel,
            taskStore: taskStore,
            spawnBrown: { nil },
            terminateAgent: { _, _ in false },
            abort: { _, _ in },
            agentRoleForID: { _ in .brown },
            memoryStore: memoryStore,
            setToolExecutionStatus: { _, _ in },
            hasToolSucceeded: { _ in false },
            hasToolFailed: { _ in false }
        )
        let actor = AgentActor(
            id: agentID,
            configuration: config,
            provider: provider,
            tools: [],  // empty tool set is fine; we never execute a tool call
            toolContext: context
        )
        return (actor, agentID)
    }

    /// Polls `agent.contextSnapshot()` until it contains an assistant message,
    /// or `deadline` elapses. The actor processes the canned response in its
    /// run loop; we need to wait for that to land in history before assertions.
    private static func waitForAssistantMessage(
        _ agent: AgentActor,
        deadline: TimeInterval = 1.0
    ) async -> LLMMessage? {
        let until = Date().addingTimeInterval(deadline)
        while Date() < until {
            let history = await agent.contextSnapshot()
            if let assistant = history.last(where: { $0.role == .assistant }) {
                return assistant
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    @Test("text-only response carries reasoning into conversation history")
    func textOnlyRoundTrip() async throws {
        let channel = MessageChannel()
        let taskStore = TaskStore()
        let provider = CannedResponseProvider(LLMResponse(
            text: "I'll wait for instructions.",
            toolCalls: [],
            reasoning: "User hasn't given me a goal yet.",
            usage: nil
        ))
        let (agent, _) = Self.makeBrown(provider: provider, channel: channel, taskStore: taskStore)
        await agent.start(initialInstruction: "hello")

        let assistant = await Self.waitForAssistantMessage(agent)
        await agent.stop()

        #expect(assistant != nil)
        #expect(assistant?.reasoning == "User hasn't given me a goal yet.")
    }

    @Test("tool-call-only response carries reasoning")
    func toolCallOnlyRoundTrip() async throws {
        let channel = MessageChannel()
        let taskStore = TaskStore()
        let provider = CannedResponseProvider(LLMResponse(
            text: nil,
            toolCalls: [LLMToolCall(id: "abc", name: "noop", arguments: "{}")],
            reasoning: "Step 1: invoke noop.",
            usage: nil
        ))
        let (agent, _) = Self.makeBrown(provider: provider, channel: channel, taskStore: taskStore)
        await agent.start(initialInstruction: "do the thing")

        let assistant = await Self.waitForAssistantMessage(agent)
        await agent.stop()

        #expect(assistant?.reasoning == "Step 1: invoke noop.")
        // Sanity-check the content shape so a future refactor doesn't drop the
        // reasoning into a message that wasn't actually a tool-call turn.
        if case .toolCalls = assistant?.content {
            // expected
        } else {
            Issue.record("expected .toolCalls content, got \(String(describing: assistant?.content))")
        }
    }

    @Test("mixed text + tool-call response carries reasoning")
    func mixedRoundTrip() async throws {
        let channel = MessageChannel()
        let taskStore = TaskStore()
        let provider = CannedResponseProvider(LLMResponse(
            text: "Calling noop now.",
            toolCalls: [LLMToolCall(id: "abc", name: "noop", arguments: "{}")],
            reasoning: "Narrate then invoke.",
            usage: nil
        ))
        let (agent, _) = Self.makeBrown(provider: provider, channel: channel, taskStore: taskStore)
        await agent.start(initialInstruction: "go")

        let assistant = await Self.waitForAssistantMessage(agent)
        await agent.stop()

        #expect(assistant?.reasoning == "Narrate then invoke.")
        if case .mixed = assistant?.content {
            // expected
        } else {
            Issue.record("expected .mixed content, got \(String(describing: assistant?.content))")
        }
    }

    @Test("response without reasoning leaves message reasoning nil")
    func absentReasoningStaysNil() async throws {
        let channel = MessageChannel()
        let taskStore = TaskStore()
        let provider = CannedResponseProvider(LLMResponse(
            text: "ok",
            toolCalls: [],
            reasoning: nil,
            usage: nil
        ))
        let (agent, _) = Self.makeBrown(provider: provider, channel: channel, taskStore: taskStore)
        await agent.start(initialInstruction: "hi")

        let assistant = await Self.waitForAssistantMessage(agent)
        await agent.stop()

        #expect(assistant?.reasoning == nil)
    }
}
