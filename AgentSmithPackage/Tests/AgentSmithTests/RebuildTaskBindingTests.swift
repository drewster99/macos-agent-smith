import Testing
import Foundation
@testable import AgentSmithKit
import SwiftLLMKit

/// Regression coverage for the task binding in `rebuildContextFromTask`.
///
/// Bug (observed 2026-07-24): the rebuild took `allTasks().first(where: { $0.status ==
/// .running })` instead of the compacting agent's OWN task. `allTasks()` sorts newest-first,
/// so with two workers live, the worker that compacted was re-seeded with the *other*
/// worker's task — whichever was created most recently. In production a localization worker
/// came back from a compaction believing it was a performance-audit worker on a different
/// repo, and, because the swap also replaced its progress log with the other task's, went on
/// to discard several thousand uncommitted translations it no longer remembered making.
///
/// Fix: bind to `taskStore.taskForAgent(agentID:)`, and fail closed (error + own-history
/// prune) rather than rebuilding from a guessed task.
@Suite("Rebuild task binding", .serialized)
struct RebuildTaskBindingTests {

    private static let sharedEngine = SemanticSearchEngine()

    /// Returns one tool-call-free text response, then throws context-overflow forever.
    /// The first success gives the agent a turn to record; every subsequent iteration
    /// drives the overflow path, which is what invokes `rebuildContextFromTask`.
    private final class OverflowAfterFirstTurnProvider: LLMProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var _callCount = 0

        var callCount: Int { lock.withLock { _callCount } }

        func send(
            messages: [LLMMessage],
            tools: [LLMToolDefinition],
            overrides: LLMCallOverrides
        ) async throws -> LLMResponse {
            let count = lock.withLock { () -> Int in
                _callCount += 1
                return _callCount
            }
            if count == 1 {
                return LLMResponse(text: "working")
            }
            throw LLMProviderError.httpError(
                statusCode: 400,
                body: #"{"error":{"message":"This model's maximum context length is 100 tokens. Reduce the length of the messages and try again."}}"#,
                url: nil
            )
        }
    }

    /// Builds a Brown wired to `taskStore`, recording which task IDs the briefing composer
    /// is asked for. That recording IS the assertion surface: the composer is the only route
    /// from a rebuild to a task envelope, so whatever ID it receives is the identity the
    /// rebuilt agent adopts.
    private func makeAgent(
        agentID: UUID,
        channel: MessageChannel,
        taskStore: TaskStore,
        memoryStore: MemoryStore,
        briefedTaskIDs: BriefingRecorder
    ) -> AgentActor {
        let llmConfig = ModelConfiguration(
            name: "tiny",
            providerID: "test",
            modelID: "test-model",
            maxOutputTokens: 50,
            maxContextTokens: 100
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
            composeTaskBriefing: { [taskStore] taskID in
                await briefedTaskIDs.record(taskID)
                guard let task = await taskStore.task(id: taskID) else { return nil }
                return "Task: \"\(task.title)\"\n\n\(task.description)"
            },
            memoryStore: memoryStore,
            setToolExecutionStatus: { _, _ in },
            hasToolSucceeded: { _ in false },
            hasToolFailed: { _ in false }
        )
        return AgentActor(
            id: agentID,
            configuration: AgentConfiguration(
                role: .brown,
                llmConfig: llmConfig,
                systemPrompt: BrownBehavior.systemPrompt
            ),
            provider: OverflowAfterFirstTurnProvider(),
            tools: BrownBehavior.tools(),
            toolContext: context
        )
    }

    actor BriefingRecorder {
        private(set) var taskIDs: [UUID] = []
        func record(_ id: UUID) { taskIDs.append(id) }
    }

    @Test("A compacting worker rebuilds from its own task, not the newest running one")
    func rebuildBindsToOwnTask() async throws {
        let channel = MessageChannel()
        let taskStore = TaskStore()
        let memoryStore = MemoryStore(engine: Self.sharedEngine)
        let recorder = BriefingRecorder()

        // OLDER task — the one our agent owns. `allTasks()` sorts newest-first, so the
        // pre-fix `first(where: .running)` lookup would skip right past it.
        let ownTask = await taskStore.addTask(title: "own task", description: "the agent's actual work")
        await taskStore.updateStatus(id: ownTask.id, status: .running)

        // NEWER task, running concurrently and assigned to a DIFFERENT agent. This is the
        // task the pre-fix lookup returned for every worker that compacted.
        let otherTask = await taskStore.addTask(title: "other task", description: "a second worker's work")
        await taskStore.updateStatus(id: otherTask.id, status: .running)
        await taskStore.assignAgent(taskID: otherTask.id, agentID: UUID())

        let firstRunningID = await taskStore.allTasks().first(where: { $0.status == .running })?.id
        #expect(
            firstRunningID == otherTask.id,
            "precondition: the newest running task must sort first, or this test proves nothing"
        )

        let agentID = UUID()
        await taskStore.assignAgent(taskID: ownTask.id, agentID: agentID)
        let agent = makeAgent(
            agentID: agentID,
            channel: channel,
            taskStore: taskStore,
            memoryStore: memoryStore,
            briefedTaskIDs: recorder
        )

        await agent.start(initialInstruction: nil)
        let deadline = Date().addingTimeInterval(2.0)
        while await agent.running, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        await agent.stop()

        let briefed = await recorder.taskIDs
        #expect(!briefed.isEmpty, "the overflow path should have attempted at least one rebuild")
        #expect(
            briefed.allSatisfy { $0 == ownTask.id },
            "every rebuild must brief from the agent's own task; got \(briefed) (own=\(ownTask.id), other=\(otherTask.id))"
        )

        // The rebuild marker belongs on the agent's own task, never the neighbour's — a
        // misrouted update is how the production incident first became visible.
        let otherUpdates = await taskStore.task(id: otherTask.id)?.updates ?? []
        #expect(
            otherUpdates.allSatisfy { !$0.message.contains("Context cleared due to size limits") },
            "another agent's task must not receive this agent's rebuild marker"
        )
    }

    @Test("An unassigned worker fails closed instead of adopting a running task")
    func unassignedWorkerFailsClosed() async throws {
        let channel = MessageChannel()
        let taskStore = TaskStore()
        let memoryStore = MemoryStore(engine: Self.sharedEngine)
        let recorder = BriefingRecorder()

        // A running task owned by somebody else. Nothing may re-seed our agent from it.
        let strangerTask = await taskStore.addTask(title: "stranger", description: "not ours")
        await taskStore.updateStatus(id: strangerTask.id, status: .running)
        await taskStore.assignAgent(taskID: strangerTask.id, agentID: UUID())

        let agent = makeAgent(
            agentID: UUID(),
            channel: channel,
            taskStore: taskStore,
            memoryStore: memoryStore,
            briefedTaskIDs: recorder
        )

        await agent.start(initialInstruction: nil)
        let deadline = Date().addingTimeInterval(2.0)
        while await agent.running, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        await agent.stop()

        let briefed = await recorder.taskIDs
        #expect(briefed.isEmpty, "an unassigned worker must not compose a briefing from anyone's task")

        let messages = await channel.allMessages()
        #expect(
            messages.contains { $0.content.contains("Cannot rebuild") && $0.content.contains("no assigned task") },
            "the failure must be surfaced as an error, not absorbed silently"
        )
        let strangerUpdates = await taskStore.task(id: strangerTask.id)?.updates ?? []
        #expect(
            strangerUpdates.allSatisfy { !$0.message.contains("Context cleared due to size limits") },
            "a stranger's task must not be touched by a failed rebuild"
        )
    }
}
