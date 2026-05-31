import Testing
import Foundation
@testable import AgentSmithKit
import SwiftLLMKit

/// Regression coverage for the rebuild-loop guard in `pruneHistoryIfNeeded`.
///
/// Bug: when the model context is too small to hold Brown's system prompt + tool
/// definitions + task envelope, `rebuildContextFromTask` cannot bring the
/// conversation below the prune threshold. The run loop then re-triggers
/// `pruneHistoryIfNeeded` on the next iteration, posting another "Context rebuilt
/// for Brown" banner — observed in production cycling at roughly 1,000 banners
/// per second for an entire session.
///
/// Fix: `pruneHistoryIfNeeded` counts consecutive rebuilds and terminates Brown
/// after `maxConsecutivePruneRebuilds` (3) attempts without an intervening
/// successful LLM turn. The counter resets on LLM success.
@Suite("Rebuild loop guard", .serialized)
struct RebuildLoopGuardTests {

    private static let sharedEngine = SemanticSearchEngine()

    /// Provider that always throws HTTP 400 with a body classified by
    /// `AgentActor.isContextOverflowError` as a context overflow. Using the
    /// overflow path is what keeps the run loop iterating fast without backoff
    /// sleeps — `try await Task.sleep` would otherwise add seconds per iteration.
    /// The prune-loop guard is what actually terminates the run; the overflow
    /// path's own counter would also terminate Brown after 3 errors, but that
    /// fires *one iteration later* and posts a different banner, which is what
    /// lets the test distinguish "fix engaged" from "would have engaged anyway."
    private final class ContextOverflowThrowingProvider: LLMProvider, @unchecked Sendable {
        let lock = NSLock()
        private var _callCount = 0

        var callCount: Int { lock.withLock { _callCount } }

        func send(
            messages: [LLMMessage],
            tools: [LLMToolDefinition],
            overrides: LLMCallOverrides
        ) async throws -> LLMResponse {
            lock.withLock { _callCount += 1 }
            throw LLMProviderError.httpError(
                statusCode: 400,
                body: #"{"error":{"message":"This model's maximum context length is 100 tokens. Reduce the length of the messages and try again."}}"#,
                url: nil
            )
        }
    }

    @Test("Brown terminates with the prune-rebuild banner rather than looping forever")
    func brownTerminatesOnRebuildLoop() async throws {
        let channel = MessageChannel()
        let taskStore = TaskStore()
        let memoryStore = MemoryStore(engine: Self.sharedEngine)

        // Tiny window: even Brown's system prompt alone vastly exceeds the
        // prune threshold (≈40 tokens with the clamped output reservation),
        // so every loop iteration triggers a rebuild.
        let llmConfig = ModelConfiguration(
            name: "tiny",
            providerID: "test",
            modelID: "test-model",
            maxOutputTokens: 50,
            maxContextTokens: 100
        )
        let config = AgentConfiguration(
            role: .brown,
            llmConfig: llmConfig,
            systemPrompt: BrownBehavior.systemPrompt
        )

        let provider = ContextOverflowThrowingProvider()

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
            tools: BrownBehavior.tools(),
            toolContext: context
        )

        // `rebuildContextFromTask` needs a running task assigned to the agent.
        let task = await taskStore.addTask(title: "loop test", description: "exercise the rebuild guard")
        await taskStore.updateStatus(id: task.id, status: .running)
        await taskStore.assignAgent(taskID: task.id, agentID: agentID)

        await agent.start(initialInstruction: nil)

        // Poll for termination. 2 seconds is far more than the few-millisecond
        // wall time required: the overflow path skips backoff sleep, so the loop
        // iterates at full speed.
        let deadline = Date().addingTimeInterval(2.0)
        while await agent.running, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        await agent.stop()

        let running = await agent.running
        #expect(running == false, "agent should have terminated rather than spinning")

        let allMessages = await channel.allMessages()
        let pruneTerminationBanner = allMessages.first {
            $0.content.contains("stopped: context still exceeds the prune threshold")
        }
        #expect(
            pruneTerminationBanner != nil,
            "prune-rebuild guard should post its termination banner; the overflow path's banner would only appear if the fix were absent"
        )

        // Sanity check: the rebuild banner count must be bounded. Without the
        // guard the production trace cleared 1,400 banners in 1.5 s; with the
        // guard, prune-driven and overflow-driven rebuild paths each top out at
        // 3, so the total stays well under 20 even with the small amount of
        // cross-talk between paths.
        let rebuildBanners = allMessages.filter {
            $0.content.contains("Context rebuilt for Brown from task state")
        }
        #expect(
            rebuildBanners.count <= 20,
            "rebuild banner count should be bounded by the guard; got \(rebuildBanners.count)"
        )
    }
}
