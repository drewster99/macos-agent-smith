import Foundation

/// Allows Smith to update a task's status.
struct UpdateTaskTool: AgentTool {
    let name = "update_task"
    let toolDescription = "Manually update a task's status. ESCAPE HATCH ONLY — for normal workflow, use `review_work` (to accept/reject), `run_task` (to start, retry, or reopen — including reopening completed tasks; do not flip status manually first), or the lifecycle tool calls Brown makes itself. Use this only when nothing else applies — e.g., marking a truly stuck task as `failed` so you can move on."

    let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "task_id": .dictionary([
                "type": .string("string"),
                "description": .string("The UUID of the task to update.")
            ]),
            "status": .dictionary([
                "type": .string("string"),
                "enum": .array([
                    .string("pending"),
                    .string("running"),
                    .string("completed"),
                    .string("failed")
                ]),
                "description": .string("The new status for the task. Note: `awaitingReview` is reserved — only Brown's `task_complete` may transition a task into review.")
            ])
        ]),
        "required": .array([.string("task_id"), .string("status")])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .smith
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard case .string(let taskIDString) = arguments["task_id"] else {
            throw ToolCallError.missingRequiredArgument("task_id")
        }
        guard let taskID = UUID(uuidString: taskIDString) else {
            return .failure("Invalid `task_id` format: \(taskIDString)")
        }
        guard case .string(let statusString) = arguments["status"] else {
            throw ToolCallError.missingRequiredArgument("status")
        }
        guard let status = AgentTask.Status(rawValue: statusString) else {
            return .failure("Invalid status: \(statusString). Valid values: pending, running, completed, failed")
        }

        if status == .awaitingReview {
            return .failure("`awaitingReview` is reserved — only Brown's `task_complete` may transition a task into review. Wait for Brown to submit, then call `review_work`.")
        }

        guard await context.taskStore.task(id: taskID) != nil else {
            return .failure("Task not found: \(taskIDString)")
        }

        await context.taskStore.updateStatus(id: taskID, status: status)
        return .success("Task \(taskIDString) updated to \(statusString).")
    }
}
