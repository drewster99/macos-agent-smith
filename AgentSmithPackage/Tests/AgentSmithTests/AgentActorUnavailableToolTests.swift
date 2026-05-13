import Testing
import Foundation
import SwiftLLMKit
@testable import AgentSmithKit

/// Regression coverage for ROADMAP "Reject unavailable tool calls at execution time."
///
/// Bug: `AgentActor` filtered the tool *definitions* sent to the LLM by `isAvailable`,
/// but the execution-time dispatch sites looked up the tool from the unfiltered `tools`
/// array. An LLM that hallucinated a call to an unavailable tool would still have that
/// tool executed. Fix: each dispatch site re-checks `isAvailable` against a freshly
/// rebuilt `ToolAvailabilityContext` and returns a fixed rejection result string
/// instead of dispatching.
///
/// Test approach: spin up a Brown `AgentActor` whose tools include `ReplyToUserTool`
/// (gated on a recent direct user message — never satisfied in a brand-new actor),
/// inject a canned LLM response that hallucinates a `reply_to_user` call, and confirm:
///
/// 1. `ReplyToUserTool.execute` is never called — verified by the absence of a Brown-to-user
///    message on the channel (the tool's only observable side effect).
/// 2. The tool-execution-status callback fires with `succeeded == false` for the rejected
///    call (so a later retry isn't flagged as a duplicate of a successful operation).
/// 3. A tool_result with the canonical rejection string is appended to the conversation
///    history.
@Suite("AgentActor unavailable tool rejection")
struct AgentActorUnavailableToolTests {

    private static let sharedEngine = SemanticSearchEngine()

    private final class StatusRecorder: @unchecked Sendable {
        struct Entry { let callID: String; let succeeded: Bool }
        private let lock = NSLock()
        private var entries: [Entry] = []
        func record(_ callID: String, _ succeeded: Bool) {
            lock.lock(); defer { lock.unlock() }
            entries.append(Entry(callID: callID, succeeded: succeeded))
        }
        var all: [Entry] { lock.lock(); defer { lock.unlock() }; return entries }
    }

    private final class ContextRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var latest: [LLMMessage] = []
        func update(_ messages: [LLMMessage]) {
            lock.lock(); defer { lock.unlock() }
            latest = messages
        }
        var snapshot: [LLMMessage] { lock.lock(); defer { lock.unlock() }; return latest }
    }

    @Test("Brown rejects a hallucinated unavailable tool call without executing it")
    func brownRejectsUnavailableTool() async throws {
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
            systemPrompt: "test"
        )

        // First response: hallucinated reply_to_user call. ReplyToUserTool's
        // `isAvailable` requires `context.lastDirectUserMessageAt` to be set within the
        // last 10 minutes — a freshly spawned actor has no such timestamp, so the tool
        // is filtered out of the LLM-facing definitions but remains in `tools`.
        let hallucinatedCall = LLMToolCall(
            id: "call-reject-1",
            name: "reply_to_user",
            arguments: #"{"message":"this should never be sent"}"#
        )
        // Subsequent responses: empty text, no tool calls. The agent loop's
        // text-only-response / empty-response counters will trip and terminate
        // Brown without us needing a hard stop.
        let responses: [LLMResponse] = [
            LLMResponse(toolCalls: [hallucinatedCall]),
            LLMResponse(text: ""),
            LLMResponse(text: ""),
            LLMResponse(text: ""),
            LLMResponse(text: ""),
            LLMResponse(text: "")
        ]
        let provider = MockLLMProvider(responses: responses)

        let statusRecorder = StatusRecorder()
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
            setToolExecutionStatus: { id, ok in statusRecorder.record(id, ok) },
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

        let contextRecorder = ContextRecorder()
        await agent.setOnContextChanged { messages in contextRecorder.update(messages) }

        // A running task gives Brown a reason to be in the loop.
        let task = await taskStore.addTask(title: "unavailable-tool test", description: "exercise the dispatch-time guard")
        await taskStore.updateStatus(id: task.id, status: .running)
        await taskStore.assignAgent(taskID: task.id, agentID: agentID)

        // `start` only schedules an LLM call when there is unprocessed input.
        // A dummy initial instruction is the cheapest way to drive a real turn.
        await agent.start(initialInstruction: "please start")

        // Wait for natural termination (empty-response or text-only-response counter trips)
        // or for the loop to settle. 2 seconds is generous: the mock provider returns
        // synchronously and the only real work is per-turn bookkeeping.
        let deadline = Date().addingTimeInterval(2.0)
        while await agent.running, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        await agent.stop()

        // 1. The tool was never executed — Brown never posted a user-directed message.
        let brownToUserMessages = await channel.allMessages().filter {
            $0.sender == .agent(.brown) && $0.recipient == .user
        }
        #expect(brownToUserMessages.isEmpty, "ReplyToUserTool.execute() ran — guard missed the unavailable call")

        // 2. The execution-status tracker received a `(callID, false)` entry for the
        //    hallucinated call.
        let rejectionEntry = statusRecorder.all.first { $0.callID == hallucinatedCall.id }
        #expect(rejectionEntry != nil, "no setToolExecutionStatus recorded for the rejected call")
        #expect(rejectionEntry?.succeeded == false, "rejected call should be marked succeeded=false")

        // 3. A tool_result with the canonical rejection string is in the conversation history.
        let history = contextRecorder.snapshot
        let rejectionToolResult = history.first { msg in
            guard msg.role == .tool else { return false }
            if case .toolResult(let id, let content) = msg.content {
                return id == hallucinatedCall.id && content.contains("is not currently available")
            }
            return false
        }
        #expect(rejectionToolResult != nil, "conversation history is missing the rejection tool_result")
    }
}
