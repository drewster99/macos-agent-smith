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
            toolChoice: LLMToolChoice?,
            thinkingEffortOverride: String?,
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

    // MARK: - Continuation round-trip (swift-llm-kit 0.0.24+)
    //
    // The 0.0.24 work added `LLMResponse.continuation` carrying provider-
    // specific multi-turn "thinking continuity" blobs (Anthropic thinking-
    // block signatures, Gemini per-part thoughtSignatures). AgentActor must
    // preserve these onto the recorded assistant message so the next turn
    // can replay them — otherwise Anthropic with thinkingBudget > 0 and any
    // Gemini 2.5 model silently lose thinking continuity across the agent
    // loop. The pre-0.0.24 manual `LLMMessage(role: .assistant, ...)`
    // construction had no slot for continuation; the .assistant(from:)
    // factory fixes that. These tests lock the wiring so a future
    // refactor cannot regress it.

    @Test("text-only response carries Anthropic thinking continuation into history")
    func anthropicContinuationTextOnly() async throws {
        let channel = MessageChannel()
        let taskStore = TaskStore()
        let blocks = [
            AnthropicThinkingBlock(thinking: "step 1", signature: "sig-A"),
            AnthropicThinkingBlock(thinking: "step 2", signature: "sig-B")
        ]
        let provider = CannedResponseProvider(LLMResponse(
            text: "Here is my answer.",
            toolCalls: [],
            reasoning: "step 2",
            usage: nil,
            continuation: ProviderContinuation(anthropicThinkingBlocks: blocks)
        ))
        let (agent, _) = Self.makeBrown(provider: provider, channel: channel, taskStore: taskStore)
        await agent.start(initialInstruction: "hello")

        let assistant = await Self.waitForAssistantMessage(agent)
        await agent.stop()

        #expect(assistant?.continuation?.anthropicThinkingBlocks == blocks)
    }

    @Test("tool-call response carries Gemini response parts into history (0.0.26)")
    func geminiContinuationToolCalls() async throws {
        let channel = MessageChannel()
        let taskStore = TaskStore()
        let parts = [
            GeminiResponsePart(
                functionCall: GeminiFunctionCall(name: "tool_a", argsJSON: "{}"),
                thoughtSignature: "sig-zero"
            ),
            GeminiResponsePart(
                functionCall: GeminiFunctionCall(name: "tool_b", argsJSON: "{}"),
                thoughtSignature: "sig-one"
            )
        ]
        let provider = CannedResponseProvider(LLMResponse(
            text: nil,
            toolCalls: [
                LLMToolCall(id: "id-A", name: "tool_a", arguments: "{}"),
                LLMToolCall(id: "id-B", name: "tool_b", arguments: "{}")
            ],
            reasoning: nil,
            usage: nil,
            continuation: ProviderContinuation(geminiResponseParts: parts)
        ))
        let (agent, _) = Self.makeBrown(provider: provider, channel: channel, taskStore: taskStore)
        await agent.start(initialInstruction: "do both")

        let assistant = await Self.waitForAssistantMessage(agent)
        await agent.stop()

        #expect(assistant?.continuation?.geminiResponseParts == parts)
    }

    @Test("mixed text+tool-call response carries thinking continuation")
    func mixedContinuation() async throws {
        let channel = MessageChannel()
        let taskStore = TaskStore()
        let blocks = [AnthropicThinkingBlock(thinking: "thought", signature: "sig-X")]
        let provider = CannedResponseProvider(LLMResponse(
            text: "Calling now.",
            toolCalls: [LLMToolCall(id: "abc", name: "noop", arguments: "{}")],
            reasoning: "thought",
            usage: nil,
            continuation: ProviderContinuation(anthropicThinkingBlocks: blocks)
        ))
        let (agent, _) = Self.makeBrown(provider: provider, channel: channel, taskStore: taskStore)
        await agent.start(initialInstruction: "go")

        let assistant = await Self.waitForAssistantMessage(agent)
        await agent.stop()

        #expect(assistant?.continuation?.anthropicThinkingBlocks == blocks)
        if case .mixed = assistant?.content {
            // expected
        } else {
            Issue.record("expected .mixed content, got \(String(describing: assistant?.content))")
        }
    }

    @Test("response without continuation leaves message continuation nil")
    func absentContinuationStaysNil() async throws {
        let channel = MessageChannel()
        let taskStore = TaskStore()
        let provider = CannedResponseProvider(LLMResponse(
            text: "ok",
            toolCalls: [],
            reasoning: nil,
            usage: nil
            // continuation defaults to nil
        ))
        let (agent, _) = Self.makeBrown(provider: provider, channel: channel, taskStore: taskStore)
        await agent.start(initialInstruction: "hi")

        let assistant = await Self.waitForAssistantMessage(agent)
        await agent.stop()

        #expect(assistant?.continuation == nil)
    }
}
