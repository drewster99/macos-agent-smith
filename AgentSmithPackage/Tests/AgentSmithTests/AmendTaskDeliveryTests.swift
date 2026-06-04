import Testing
import Foundation
@testable import AgentSmithKit

/// Tests for `AmendTaskTool`'s live-delivery behavior.
///
/// `amend_task` mutates the stored task description (so Jones, which reads the live
/// description on every approval, sees the new intent) but Brown's briefing is a
/// one-time spawn snapshot. To keep a running Brown in sync — rather than relying on
/// Smith to remember a follow-up `message_brown` — the tool injects the amendment
/// directly into a live Brown's conversation. These tests pin that contract:
///   - When Brown is running the amended task, the amendment is posted privately to
///     Brown as a `.system` message (not attributed to Smith) carrying the amendment text.
///   - When no Brown is assigned to the running task (queued task, or no Brown at all),
///     nothing is delivered and the result says it'll land on the next respawn.
@Suite("AmendTaskTool live delivery")
struct AmendTaskDeliveryTests {

    private static func makeContext(
        channel: MessageChannel,
        taskStore: TaskStore,
        brownID: UUID?
    ) -> ToolContext {
        ToolContext(
            agentID: UUID(),
            agentRole: .smith,
            channel: channel,
            taskStore: taskStore,
            spawnBrown: { nil },
            terminateAgent: { _, _ in false },
            abort: { _, _ in },
            agentRoleForID: { _ in nil },
            agentIDForRole: { role in role == .brown ? brownID : nil },
            memoryStore: MemoryStore(engine: SemanticSearchEngine())
        )
    }

    @Test("Amending a task a live Brown is running delivers the amendment privately to Brown")
    func deliversToRunningBrown() async throws {
        let channel = MessageChannel()
        let taskStore = TaskStore()
        let brownID = UUID()

        let task = await taskStore.addTask(title: "Extract hooks", description: "Original briefing.")
        await taskStore.assignAgent(taskID: task.id, agentID: brownID)
        await taskStore.updateStatus(id: task.id, status: .running)

        let context = Self.makeContext(channel: channel, taskStore: taskStore, brownID: brownID)
        let result = try await AmendTaskTool().execute(
            arguments: [
                "task_id": .string(task.id.uuidString),
                "amendment": .string("Here is the transcript: [00:00] hello")
            ],
            context: context
        )

        #expect(result.succeeded)
        #expect(result.output.contains("delivered to the running Brown"))

        // Stored description carries the amendment so Jones sees it on the next approval.
        let updated = await taskStore.task(id: task.id)
        #expect(updated?.description.contains("Here is the transcript") == true)

        // Exactly one channel post: a private .system message to Brown with the amendment.
        let posted = await channel.allMessages()
        #expect(posted.count == 1)
        let delivery = try #require(posted.first)
        #expect(delivery.recipientID == brownID)
        if case .system = delivery.sender {} else {
            Issue.record("Expected the amendment to be delivered as a .system message, not attributed to Smith")
        }
        #expect(delivery.content.contains("Here is the transcript"))
        #expect(delivery.content.contains("[Task description amended]"))
    }

    @Test("Amending a task no running Brown is assigned to delivers nothing")
    func skipsWhenNoBrownAssigned() async throws {
        let channel = MessageChannel()
        let taskStore = TaskStore()
        let brownID = UUID()

        // Brown exists, but it isn't assigned to this (still-pending) task.
        let task = await taskStore.addTask(title: "Queued task", description: "Original briefing.")

        let context = Self.makeContext(channel: channel, taskStore: taskStore, brownID: brownID)
        let result = try await AmendTaskTool().execute(
            arguments: [
                "task_id": .string(task.id.uuidString),
                "amendment": .string("Additional context for later.")
            ],
            context: context
        )

        #expect(result.succeeded)
        #expect(result.output.contains("next started"))

        // Amendment is still stored for the eventual respawn, but nothing is delivered.
        let updated = await taskStore.task(id: task.id)
        #expect(updated?.description.contains("Additional context for later.") == true)
        let posted = await channel.allMessages()
        #expect(posted.isEmpty)
    }
}
