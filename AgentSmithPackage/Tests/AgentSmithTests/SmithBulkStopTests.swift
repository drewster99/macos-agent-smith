import Foundation
import Testing
@testable import AgentSmithKit

/// Regressions from the 2026-10-11 bulk stop/delete incident (`docs/plans/SmithBulkStopFixes.md`).
@Suite("Smith bulk stop/delete")
struct SmithBulkStopTests {

    /// A task parked on `request_help` whose worker is gone — the state `provide_help` cannot
    /// resume at full capacity and `terminate_agent` has nothing to stop.
    private static func makeParkedTask(in taskStore: TaskStore) async -> AgentTask {
        let task = await taskStore.addTask(title: "Reconcile batch", description: "d")
        #expect(await taskStore.updateStatus(id: task.id, status: .running, cause: .workerStarted))
        #expect(await taskStore.updateStatus(id: task.id, status: .awaitingHelp, cause: .helpRequested))
        return task
    }

    // MARK: - F1

    @Test(
        "Smith's task-management tools are pre-cleared",
        arguments: ["manage_task_disposition", "set_acceptance_criteria", "set_preconditions", "manage_steps"]
    )
    func smithTaskManagementToolsArePreCleared(toolName: String) {
        #expect(SecurityEvaluator.isAutoApproved(toolName: toolName, role: .smith))
    }

    @Test("Smith's pre-clears do not extend to Brown")
    func taskManagementPreClearsAreSmithOnly() {
        #expect(SecurityEvaluator.isAutoApproved(toolName: "manage_steps", role: .brown) == false)
    }

    // MARK: - F2

    @Test("update_task fails a parked task even when it also restates is_template unchanged")
    func updateTaskFailsParkedTaskWithNoOpTemplateFlag() async throws {
        let taskStore = TaskStore()
        let task = await Self.makeParkedTask(in: taskStore)
        let context = TestToolContext.make(agentRole: .smith, taskStore: taskStore)

        let result = try await UpdateTaskTool().execute(
            arguments: [
                "task_id": .string(task.id.uuidString),
                "status": .string("failed"),
                "is_template": .bool(false)
            ],
            context: context
        )

        #expect(result.succeeded, "got: \(result.output)")
        #expect(await taskStore.task(id: task.id)?.status == .failed)
    }

    @Test("Promoting an in-progress task to a template is still refused")
    func promotingInProgressTaskIsRefused() async {
        let taskStore = TaskStore()
        let task = await Self.makeParkedTask(in: taskStore)

        let refusal = await taskStore.setTemplate(id: task.id, isTemplate: true)

        #expect(refusal != nil)
        #expect(await taskStore.task(id: task.id)?.isTemplate == false)
        #expect(await taskStore.task(id: task.id)?.status == .awaitingHelp)
    }

    // MARK: - F3

    @Test("Smith's prompt says to dequeue a group's pending tasks before terminating its workers")
    func promptOrdersBulkStop() {
        let prompt = SmithBehavior.systemPrompt()

        #expect(prompt.contains("Stopping a group of tasks"))
        #expect(prompt.contains("FIRST remove the group's pending"))
        #expect(prompt.contains("THEN `terminate_agent`"))
    }

    // MARK: - F5

    @Test("terminate_agent on a parked task with no worker points Smith at update_task")
    func terminateParkedTaskWithoutWorkerTeachesUpdateTask() async throws {
        let taskStore = TaskStore()
        let task = await Self.makeParkedTask(in: taskStore)
        let context = TestToolContext.make(agentRole: .smith, taskStore: taskStore)

        let result = try await TerminateAgentTool().execute(
            arguments: ["task_id": .string(task.id.uuidString), "reason": .string("user asked to stop")],
            context: context
        )

        #expect(result.succeeded == false)
        #expect(result.output.contains("update_task"), "got: \(result.output)")
        #expect(result.output.contains("status: failed"), "got: \(result.output)")
        #expect(await taskStore.task(id: task.id)?.status == .awaitingHelp)
    }
}
