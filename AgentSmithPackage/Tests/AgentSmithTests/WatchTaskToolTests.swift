import Testing
import Foundation
@testable import AgentSmithKit

@Suite("watch_task / list_task_watches tools")
struct WatchTaskToolTests {

    private func context(_ store: TaskStore) -> ToolContext {
        TestToolContext.make(agentRole: .smith, taskStore: store)
    }

    @Test("Creating a start_task watch holds the target, and run_task then refuses it")
    func createChainHoldsTarget() async throws {
        let store = TaskStore()
        let upstream = await store.addTask(title: "A", description: "d")
        let downstream = await store.addTask(title: "B", description: "d")
        let created = try await WatchTaskTool().execute(arguments: [
            "action": .string("create"),
            "task_id": .string(upstream.id.uuidString),
            "when": .array([.string("completed")]),
            "do": .string("start_task"),
            "target_task_id": .string(downstream.id.uuidString)
        ], context: context(store))
        #expect(created.succeeded, "\(created.output)")
        let watch = try #require(await store.task(id: upstream.id)?.watches.first)
        #expect(watch.lifetime == .once, "a chain link defaults to once")
        #expect(watch.createdBy == .smith)
        #expect(await store.task(id: downstream.id)?.startHolds.count == 1)

        let run = try await RunTaskTool().execute(arguments: [
            "task_id": .string(downstream.id.uuidString),
            "instructions": .string("go")
        ], context: context(store))
        #expect(!run.succeeded)
        #expect(run.output.contains("waiting on \"A\""))
        #expect(await store.task(id: downstream.id)?.status == .pending, "never reset or started")
    }

    @Test("Empty optional placeholders read as absent, and missing per-action arguments are refused clearly")
    func argumentHandling() async throws {
        let store = TaskStore()
        let task = await store.addTask(title: "A", description: "d")
        let missingInstructions = try await WatchTaskTool().execute(arguments: [
            "action": .string("create"),
            "task_id": .string(task.id.uuidString),
            "when": .array([.string("failed")]),
            "do": .string("instruct_smith"),
            "instructions": .string(""),
            "target_task_id": .string(""),
            "lifetime": .string(""),
            "watch_id": .string("")
        ], context: context(store))
        #expect(!missingInstructions.succeeded)
        #expect(missingInstructions.output.contains("`instructions` is required"))

        let badState = try await WatchTaskTool().execute(arguments: [
            "action": .string("create"),
            "task_id": .string(task.id.uuidString),
            "when": .array([.string("exploded")]),
            "do": .string("macos_notification")
        ], context: context(store))
        #expect(!badState.succeeded)
        #expect(await store.task(id: task.id)?.watches.isEmpty == true)
    }

    @Test("Cancel removes the watch's effect on the task and list shows it cancelled")
    func cancelAndList() async throws {
        let store = TaskStore()
        let task = await store.addTask(title: "A", description: "d")
        _ = try await WatchTaskTool().execute(arguments: [
            "action": .string("create"),
            "task_id": .string(task.id.uuidString),
            "when": .array([.string("completed"), .string("needs_help")]),
            "do": .string("summarize_to_user")
        ], context: context(store))
        let watch = try #require(await store.task(id: task.id)?.watches.first)
        #expect(watch.triggers == [.completed, .needsHelp])

        let listed = try await ListTaskWatchesTool().execute(arguments: ["task_id": .string("")], context: context(store))
        #expect(listed.succeeded)
        #expect(listed.output.contains(watch.id.uuidString))
        #expect(listed.output.contains("active"))

        let cancelled = try await WatchTaskTool().execute(arguments: [
            "action": .string("cancel"),
            "task_id": .string(task.id.uuidString),
            "watch_id": .string(watch.id.uuidString)
        ], context: context(store))
        #expect(cancelled.succeeded)
        let relisted = try await ListTaskWatchesTool().execute(arguments: [:], context: context(store))
        #expect(relisted.output.contains("cancelled"))
    }

    @Test("Both tools are Smith's, registered in every roster")
    func registration() {
        let names = Set(SmithBehavior.toolNames)
        #expect(names.contains("watch_task"))
        #expect(names.contains("list_task_watches"))
        #expect(SecurityEvaluator.autoApprovedToolsByRole[.smith]?.contains("watch_task") == true)
        #expect(SecurityEvaluator.autoApprovedToolsByRole[.smith]?.contains("list_task_watches") == true)
        #expect(ToolSafetyClassification.knownBuiltInNames.contains("watch_task"))
        #expect(!ToolSafetyClassification.hasSideEffects(toolName: "list_task_watches"))
        #expect(ToolSafetyClassification.hasSideEffects(toolName: "watch_task"))
        #expect(BuiltInToolGroup.allToolNames.isSuperset(of: ["watch_task", "list_task_watches"]))
        #expect(AgentActor.smithTaskActionTools.contains("watch_task"), "Smith's watch work is billed to the watched task")
    }
}
