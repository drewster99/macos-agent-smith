import Testing
import Foundation
@testable import AgentSmithKit

/// Tests for the `request_help` ↔ `provide_help` round-trip — Brown's honest blocker-escalation
/// path, mirroring `task_complete` ↔ `review_work`. A help request parks in `awaitingReview`
/// (reusing the review wait machinery) but is flagged via `AgentTask.helpRequest`, so `review_work`
/// refuses it and Smith answers via `provide_help`, which returns the task to running and wakes Brown.
@Suite("Help request round-trip")
struct HelpRequestTests {

    private static func brownContext(taskStore: TaskStore, channel: MessageChannel, brownID: UUID, smithID: UUID) -> ToolContext {
        ToolContext(
            agentID: brownID,
            agentRole: .brown,
            channel: channel,
            taskStore: taskStore,
            spawnBrown: { nil },
            terminateAgent: { _, _ in false },
            abort: { _, _ in },
            agentRoleForID: { id in id == brownID ? .brown : (id == smithID ? .smith : nil) },
            agentIDForRole: { role in role == .brown ? brownID : (role == .smith ? smithID : nil) },
            memoryStore: MemoryStore(engine: SemanticSearchEngine())
        )
    }

    private static func smithContext(taskStore: TaskStore, channel: MessageChannel, brownID: UUID, smithID: UUID) -> ToolContext {
        ToolContext(
            agentID: smithID,
            agentRole: .smith,
            channel: channel,
            taskStore: taskStore,
            spawnBrown: { nil },
            terminateAgent: { _, _ in false },
            abort: { _, _ in },
            agentRoleForID: { id in id == brownID ? .brown : (id == smithID ? .smith : nil) },
            agentIDForRole: { role in role == .brown ? brownID : (role == .smith ? smithID : nil) },
            memoryStore: MemoryStore(engine: SemanticSearchEngine())
        )
    }

    @Test("request_help parks the task in awaitingReview, flags it, and notifies Smith (no result set)")
    func requestHelpEscalates() async throws {
        let channel = MessageChannel()
        let taskStore = TaskStore()
        let brownID = UUID(), smithID = UUID()
        let task = await taskStore.addTask(title: "Extract hooks", description: "...")
        await taskStore.assignAgent(taskID: task.id, agentID: brownID)
        await taskStore.updateStatus(id: task.id, status: .running)

        let ctx = Self.brownContext(taskStore: taskStore, channel: channel, brownID: brownID, smithID: smithID)
        let result = try await RequestHelpTool().execute(
            arguments: [
                "blocker": .string("The transcript isn't in my context."),
                "needed": .string("The transcript text, from the user.")
            ],
            context: ctx
        )
        #expect(result.succeeded)

        let updated = try #require(await taskStore.task(id: task.id))
        #expect(updated.status == .awaitingReview)
        #expect(updated.helpRequest?.contains("transcript") == true)
        #expect(updated.result == nil)  // a blocker is NOT a result

        let posted = await channel.allMessages()
        let toSmith = try #require(posted.first { $0.recipientID == smithID })
        if case .string("help_requested") = toSmith.metadata?["messageKind"] {} else {
            Issue.record("Expected a help_requested message to Smith")
        }
    }

    @Test("provide_help answers a help request: clears the flag, returns to running, messages Brown")
    func provideHelpResolves() async throws {
        let channel = MessageChannel()
        let taskStore = TaskStore()
        let brownID = UUID(), smithID = UUID()
        let task = await taskStore.addTask(title: "Extract hooks", description: "...")
        await taskStore.assignAgent(taskID: task.id, agentID: brownID)
        await taskStore.requestHelp(id: task.id, request: "Blocker: x\nNeeded: y")

        let ctx = Self.smithContext(taskStore: taskStore, channel: channel, brownID: brownID, smithID: smithID)
        let result = try await ProvideHelpTool().execute(
            arguments: [
                "task_id": .string(task.id.uuidString),
                "response": .string("Here's the transcript: [00:00] hello")
            ],
            context: ctx
        )
        #expect(result.succeeded)

        let updated = try #require(await taskStore.task(id: task.id))
        #expect(updated.helpRequest == nil)
        #expect(updated.status == .running)

        let posted = await channel.allMessages()
        let toBrown = try #require(posted.first { $0.recipientID == brownID })
        #expect(toBrown.content.contains("transcript"))
        if case .string("help_provided") = toBrown.metadata?["messageKind"] {} else {
            Issue.record("Expected a help_provided message to Brown")
        }
    }

    @Test("provide_help refuses a task that is not a help request")
    func provideHelpRejectsNonHelpTask() async throws {
        let channel = MessageChannel()
        let taskStore = TaskStore()
        let brownID = UUID(), smithID = UUID()
        let task = await taskStore.addTask(title: "Normal work", description: "...")
        await taskStore.assignAgent(taskID: task.id, agentID: brownID)
        await taskStore.setResult(id: task.id, result: "done", commentary: nil)
        await taskStore.updateStatus(id: task.id, status: .awaitingReview)

        let ctx = Self.smithContext(taskStore: taskStore, channel: channel, brownID: brownID, smithID: smithID)
        let result = try await ProvideHelpTool().execute(
            arguments: ["task_id": .string(task.id.uuidString), "response": .string("...")],
            context: ctx
        )
        #expect(!result.succeeded)
        #expect(result.output.contains("not a help request"))
    }

    @Test("review_work refuses a help-request task and points to provide_help")
    func reviewWorkRefusesHelpRequest() async throws {
        let channel = MessageChannel()
        let taskStore = TaskStore()
        let brownID = UUID(), smithID = UUID()
        let task = await taskStore.addTask(title: "Blocked task", description: "...")
        await taskStore.assignAgent(taskID: task.id, agentID: brownID)
        await taskStore.requestHelp(id: task.id, request: "Blocker: x\nNeeded: y")

        let ctx = Self.smithContext(taskStore: taskStore, channel: channel, brownID: brownID, smithID: smithID)
        let result = try await ReviewWorkTool().execute(
            arguments: ["task_id": .string(task.id.uuidString), "accepted": .bool(true)],
            context: ctx
        )
        #expect(!result.succeeded)
        #expect(result.output.contains("provide_help"))
    }
}
