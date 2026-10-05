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

    /// 2026-10-04: Smith "enabled" create_task, list_tasks, watch_task, list_task_watches and
    /// list_scheduled_wakes on a coordinator task. Overrides apply only to a worker's candidate tools,
    /// so the call reported success and the worker never got any of them.
    @Test("an override for a tool no worker can have is refused, and nothing is written")
    func smithOnlyToolOverrideIsRefused() async throws {
        let store = TaskStore()
        let task = await store.addTask(title: "Coordinator", description: "Create the audits.")
        let context = TestToolContext.make(agentRole: .smith, taskStore: store)

        let result = try await EditTaskTool().execute(
            arguments: [
                "task_id": .string(task.id.uuidString),
                "title": .string("Changed"),
                "tool_overrides": .dictionary([
                    "create_task": .string("on"),
                    "file_write": .string("on")
                ])
            ],
            context: context
        )

        #expect(!result.succeeded)
        #expect(result.output.contains("create_task"))
        #expect(!result.output.contains("file_write"), "a real worker tool was named as unavailable")
        let unchanged = await store.task(id: task.id)
        #expect(unchanged?.title == "Coordinator")
        #expect(unchanged?.userToolOverrides == nil)
    }

    @Test("worker tools and MCP tools can be overridden; a stale unavailable override can be cleared")
    func workerAndMCPOverridesAndClearing() async throws {
        let store = TaskStore()
        let task = await store.addTask(title: "Coordinator", description: "Create the audits.")
        // An override stored before the check existed.
        await store.setUserToolOverride(id: task.id, tool: "create_task", enabled: true)
        let context = TestToolContext.make(agentRole: .smith, taskStore: store)

        let result = try await EditTaskTool().execute(
            arguments: [
                "task_id": .string(task.id.uuidString),
                "tool_overrides": .dictionary([
                    "file_write": .string("on"),
                    "mcp__mac-control__window": .string("off"),
                    "create_task": .string("auto")
                ])
            ],
            context: context
        )

        #expect(result.succeeded, "\(result.output)")
        let overrides = await store.task(id: task.id)?.userToolOverrides
        #expect(overrides == ["file_write": true, "mcp__mac-control__window": false])
    }
}
