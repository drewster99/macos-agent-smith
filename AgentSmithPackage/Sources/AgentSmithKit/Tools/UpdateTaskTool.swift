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
                "description": .string("The new status for the task: pending, paused, completed, or failed. `running` is NOT settable here — use `run_task`, which actually spawns the worker. `awaitingReview` and `validating` are reserved — submissions enter validation via Brown's `task_complete`, and only a validation escalation parks a task in review. Optional when `is_template` is provided.")
            ]),
            "is_template": .dictionary([
                "type": .string("boolean"),
                "description": .string("Toggle whether this task is a TEMPLATE. A template never runs itself — starting it clones a fresh instance (state blanked) that runs. true = make it a template; false = make it an ordinary task. May be sent alone (without `status`).")
            ])
        ]),
        "required": .array([.string("task_id")])
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
        guard await context.taskStore.task(id: taskID) != nil else {
            return .failure("Task not found: \(taskIDString)")
        }

        // Template toggle — independent of status. May be sent alone or with a status.
        var appliedTemplate: Bool?
        if case .bool(let flag) = arguments["is_template"] {
            if let problem = await context.taskStore.setTemplate(id: taskID, isTemplate: flag) {
                return .failure(problem)
            }
            appliedTemplate = flag
        }

        // Status is optional when a template toggle is present, so a caller can flip the
        // template flag without also restating the status.
        guard case .string(let statusString) = arguments["status"] else {
            if let appliedTemplate {
                return .success("Task \(taskIDString) is \(appliedTemplate ? "now a template" : "no longer a template").")
            }
            throw ToolCallError.missingRequiredArgument("status")
        }
        guard let status = AgentTask.Status(rawValue: statusString) else {
            return .failure("Invalid status: \(statusString). Valid values: pending, paused, completed, failed")
        }

        if status == .running {
            return .failure("`running` cannot be set directly — it would create a task that LOOKS in-flight but has no worker, and it blocks the auto-run queue. Use `run_task` to actually start a task (it spawns the worker); if it refuses because another task is running, wait for that task to finish.")
        }
        if status == .awaitingReview {
            return .failure("`awaitingReview` is reserved — it is where acceptance validation parks a task when it ESCALATES (and where help requests park). You cannot set it directly. If the task needs your review, wait for the escalation notice, then call `review_work`.")
        }
        if status == .validating {
            return .failure("`validating` is reserved — only Brown's `task_complete` submission enters validation. Setting it directly would strand the task with no validation run attached.")
        }

        await context.taskStore.updateStatus(id: taskID, status: status)
        let templateNote = appliedTemplate.map { " (\($0 ? "now a template" : "no longer a template"))" } ?? ""
        return .success("Task \(taskIDString) updated to \(statusString)\(templateNote).")
    }
}
