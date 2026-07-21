import Foundation
import Testing
@testable import AgentSmithKit

@Suite("Edit task tool")
struct EditTaskToolTests {

    @Test("Invalid tool overrides reject before mutating the task definition")
    func invalidToolOverridesAreAtomic() async throws {
        let store = TaskStore()
        let task = await store.addTask(title: "Original", description: "Keep me.")
        let context = TestToolContext.make(agentRole: .smith, taskStore: store)

        let result = try await EditTaskTool().execute(
            arguments: [
                "task_id": .string(task.id.uuidString),
                "title": .string("Changed"),
                "tool_overrides": .dictionary([
                    "file_read": .string("bogus")
                ])
            ],
            context: context
        )

        #expect(!result.succeeded)
        #expect(result.output.contains("Invalid tool override state"))

        let unchangedTask = await store.task(id: task.id)
        #expect(unchangedTask?.title == "Original")
        #expect(unchangedTask?.userToolOverrides == nil)
    }
}
