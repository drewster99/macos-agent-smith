import Testing
import Foundation
@testable import AgentSmithKit

/// Regression tests for `TaskStore.updateDescription` and the `lastEditedAt` flag.
///
/// The user-facing flow: completed and scheduled tasks need to accept description edits
/// (e.g. correcting a typo after the work has already finished, or refining a scheduled
/// task before its wake fires). The status must NOT change — a completed task stays
/// completed; the only signal that the description was touched is `lastEditedAt`, which
/// the UI surfaces as an "edited" badge.
@Suite("Task description editing")
struct TaskDescriptionEditingTests {

    @Test(
        "Editable statuses accept description edits and stamp lastEditedAt",
        arguments: [
            AgentTask.Status.pending,
            .paused,
            .interrupted,
            .scheduled,
            .completed,
            .failed,
        ]
    )
    func editableStatusesAcceptEdits(status: AgentTask.Status) async {
        let store = TaskStore()
        let task = AgentTask(title: "T", description: "old", status: status)
        await store.restore([task])

        let problem = await store.updateDescription(id: task.id, description: "new")
        #expect(problem == nil)

        let updated = await store.task(id: task.id)
        #expect(updated?.description == "new")
        #expect(updated?.status == status, "Editing must NOT change the status")
        #expect(updated?.lastEditedAt != nil, "lastEditedAt must be stamped on edit")
    }

    @Test(
        "Non-editable statuses reject description edits",
        arguments: [AgentTask.Status.running, .awaitingReview]
    )
    func nonEditableStatusesRejectEdits(status: AgentTask.Status) async {
        let store = TaskStore()
        let task = AgentTask(title: "T", description: "old", status: status)
        await store.restore([task])

        let problem = await store.updateDescription(id: task.id, description: "new")
        #expect(problem?.contains(status.rawValue) == true)

        let updated = await store.task(id: task.id)
        #expect(updated?.description == "old", "Description must be unchanged on rejection")
        #expect(updated?.lastEditedAt == nil, "lastEditedAt must remain nil on rejection")
    }

    @Test("No-op edit (same description) does not stamp lastEditedAt")
    func noOpEditDoesNotStamp() async {
        let store = TaskStore()
        let task = AgentTask(title: "T", description: "same", status: .completed)
        await store.restore([task])

        let problem = await store.updateDescription(id: task.id, description: "same")
        #expect(problem == nil, "Returning success keeps the UI's Save button quiet")

        let updated = await store.task(id: task.id)
        #expect(updated?.lastEditedAt == nil, "Identical-content edit must not stamp the badge")
    }

    @Test("Edit on a completed task preserves the completed status and the result field")
    func editPreservesCompletedFields() async {
        let store = TaskStore()
        let task = AgentTask(
            title: "T",
            description: "old",
            status: .completed,
            result: "shipped",
            completedAt: Date(timeIntervalSinceReferenceDate: 0)
        )
        await store.restore([task])

        _ = await store.updateDescription(id: task.id, description: "edited")

        let updated = await store.task(id: task.id)
        #expect(updated?.status == .completed)
        #expect(updated?.result == "shipped")
        #expect(updated?.completedAt == Date(timeIntervalSinceReferenceDate: 0))
        #expect(updated?.description == "edited")
    }

    @Test("Updating a non-existent task ID is refused")
    func unknownIDIsRefused() async {
        let store = TaskStore()
        let problem = await store.updateDescription(id: UUID(), description: "x")
        #expect(problem == "Task not found.")
    }

    @Test("AgentTask round-trips lastEditedAt through Codable")
    func codableRoundTrip() throws {
        let when = Date(timeIntervalSinceReferenceDate: 12345)
        let task = AgentTask(title: "T", description: "d", lastEditedAt: when)
        let encoded = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(AgentTask.self, from: encoded)
        #expect(decoded.lastEditedAt == when)
    }

    @Test("Decoding pre-existing JSON without lastEditedAt yields nil (back-compat)")
    func backwardCompatDecode() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "title": "T",
          "description": "d",
          "status": "completed",
          "disposition": "active",
          "assigneeIDs": [],
          "createdAt": 0,
          "updatedAt": 0
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AgentTask.self, from: json)
        #expect(decoded.lastEditedAt == nil)
    }
}
