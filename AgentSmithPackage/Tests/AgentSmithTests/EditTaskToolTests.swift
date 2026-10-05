import Foundation
import Testing
@testable import AgentSmithKit

@Suite("Edit task tool")
struct EditTaskToolTests {

    /// 2026-10-04: Smith "enabled" create_task, list_tasks, watch_task and more on a coordinator
    /// task. Smith granting tools bypassed the Security Agent's scoping and the user's policy, so
    /// edit_task lost the parameter (2026-10-05). A call that still passes it is refused whole.
    @Test("tool_overrides is refused and nothing is written")
    func toolOverridesRefused() async throws {
        let store = TaskStore()
        let task = await store.addTask(title: "Original", description: "Keep me.")
        let context = TestToolContext.make(agentRole: .smith, taskStore: store)

        let result = try await EditTaskTool().execute(
            arguments: [
                "task_id": .string(task.id.uuidString),
                "title": .string("Changed"),
                "tool_overrides": .dictionary(["file_write": .string("on")])
            ],
            context: context
        )

        #expect(!result.succeeded)
        let unchanged = await store.task(id: task.id)
        #expect(unchanged?.title == "Original")
        #expect(unchanged?.userToolOverrides == nil)
    }

    @Test("an empty tool_overrides of any shape is an absent optional, not a grant")
    func emptyToolOverridesIgnored() async throws {
        let store = TaskStore()
        let task = await store.addTask(title: "Original", description: "Keep me.")
        let context = TestToolContext.make(agentRole: .smith, taskStore: store)

        for sentinel: AnyCodable in [.dictionary([:]), .null, .array([]), .string(""), .string("  ")] {
            let result = try await EditTaskTool().execute(
                arguments: [
                    "task_id": .string(task.id.uuidString),
                    "title": .string("Changed"),
                    "tool_overrides": sentinel
                ],
                context: context
            )
            #expect(result.succeeded, "\(result.output)")
        }
        #expect(await store.task(id: task.id)?.title == "Changed")
        #expect(await store.task(id: task.id)?.userToolOverrides == nil)
    }

    @Test("the schema no longer offers tool_overrides")
    func schemaHasNoToolOverrides() {
        guard case .dictionary(let properties)? = EditTaskTool().parameters["properties"] else {
            Issue.record("edit_task has no properties")
            return
        }
        #expect(properties["tool_overrides"] == nil)
    }
}
