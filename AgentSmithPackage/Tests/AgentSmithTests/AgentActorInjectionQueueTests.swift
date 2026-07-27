import Testing
import Foundation
import SwiftLLMKit
@testable import AgentSmithKit

/// Regression coverage for the single-writer `conversationHistory` fix (commit `dbd278d`).
///
/// Bug: external `.user` injections (`appendUserMessage`, called by the runtime and the
/// `TaskValidationCoordinator` — a concurrent writer, off the run loop) appended straight to
/// `conversationHistory`. When one arrived while the agent was parked in a tool `await` (e.g.
/// an 8.2 s `save_memory`), it spliced a `.user` message BETWEEN the assistant `tool_calls`
/// message and its `tool_result`s — a non-retryable OpenAI 400 ("tool_call_id did not have
/// response messages") that killed the agent.
///
/// Fix: `appendUserMessage` now enqueues into `pendingInjectedMessages`; the run loop (the sole
/// writer of `conversationHistory`) drains it at the top of the iteration, a boundary where the
/// previous turn is complete. This test pins the observable half of that contract:
///
/// 1. Immediately after `appendUserMessage`, the text is NOT in `conversationHistory` — it was
///    queued, not spliced. (Reverting to a direct append fails here.)
/// 2. After the run loop turns over, the queued message IS in `conversationHistory` — it is
///    drained at the boundary, never lost.
@Suite("AgentActor injection queue (single writer)")
struct AgentActorInjectionQueueTests {

    private static let sharedEngine = SemanticSearchEngine()

    @Test("appendUserMessage queues instead of writing conversationHistory directly, then the loop drains it")
    func appendUserMessageQueuesThenDrains() async throws {
        let channel = MessageChannel()
        let taskStore = TaskStore()
        let memoryStore = MemoryStore(engine: Self.sharedEngine)

        let llmConfig = ModelConfiguration(
            name: "test",
            providerID: "test",
            modelID: "test-model",
            maxOutputTokens: 1024,
            maxContextTokens: 100_000
        )
        let config = AgentConfiguration(
            role: .brown,
            llmConfig: llmConfig,
            systemPrompt: "test-system"
        )

        // Text-only responses: Brown's text-only-response counter trips and it self-terminates,
        // so the loop settles on its own (a hard stop still backstops the deadline below).
        let provider = MockLLMProvider(responses: [
            LLMResponse(text: "ok"),
            LLMResponse(text: "ok"),
            LLMResponse(text: "ok"),
            LLMResponse(text: "ok"),
            LLMResponse(text: "ok"),
            LLMResponse(text: "ok")
        ])

        let agentID = UUID()
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

        let agent = AgentActor(
            id: agentID,
            configuration: config,
            provider: provider,
            tools: [],
            toolContext: context
        )

        let sentinel = "QUEUED_SENTINEL_MUST_NOT_SPLICE"
        // Inject BEFORE the loop runs. With the single-writer fix this only enqueues — the
        // history (seeded with the system prompt at init) must not yet contain it.
        await agent.appendUserMessage(sentinel)

        let beforeRun = await agent.contextSnapshot()
        #expect(
            !beforeRun.contains { ($0.content.textValue ?? "").contains(sentinel) },
            "appendUserMessage wrote to conversationHistory directly — regression of the single-writer fix; a mid-tool-turn inject would splice between an assistant tool_calls turn and its tool_result."
        )

        // Drive the loop; the run loop drains the queue at the top-of-iteration boundary.
        await agent.start()
        let deadline = Date().addingTimeInterval(3.0)
        while await agent.running, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        await agent.stop()

        let afterRun = await agent.contextSnapshot()
        #expect(
            afterRun.contains { ($0.content.textValue ?? "").contains(sentinel) },
            "the queued injection was never drained into conversationHistory."
        )
    }
}
