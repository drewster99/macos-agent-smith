import Foundation

/// Allows Smith to update a task's status.
struct UpdateTaskTool: AgentTool {
    let name = "update_task"
    let toolDescription = "Manually update a task's status. ESCAPE HATCH ONLY — for normal workflow, use `run_task` (to start, retry, or reopen — including reopening completed tasks; do not flip status manually first) or the lifecycle tool calls Brown makes itself; acceptance validation handles completion. Use this only when nothing else applies — e.g., marking a truly stuck task as `failed` so you can move on."

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
                    .string("paused"),
                    .string("interrupted"),
                    .string("completed"),
                    .string("failed")
                ]),
                "description": .string("The new status for the task: pending, paused, interrupted, completed, or failed. `running` is NOT settable here — use `run_task`, which actually spawns the worker. `awaitingReview` and `validating` are reserved — submissions enter validation via Brown's `task_complete`, and only a validation escalation parks a task in review. Optional when `is_template` is provided.")
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
        guard let existing = await context.taskStore.taskOrLibraryTemplate(id: taskID) else {
            return .failure("Task not found: \(taskIDString)")
        }
        // Refused BEFORE the template toggle below is applied, so the call cannot half-land.
        let requestedStatus = ToolArguments.optionalString(arguments, "status").flatMap(AgentTask.Status.init(rawValue:))
        if requestedStatus == .completed, existing.requiresUserAcceptance {
            return .failure("Task \(taskIDString) requires the user's own acceptance, so update_task cannot complete it. It completes only when the user accepts it — from the task row, or by telling you, after which you relay it with `respond_to_user_acceptance` once it is waiting for their sign-off.")
        }
        if requestedStatus != nil, existing.status == .awaitingReview {
            return .failure("Task \(taskIDString) is parked awaiting review. That park is resolved by the user from the task row (or, for a sign-off they gave you in chat, `respond_to_user_acceptance`) — update_task cannot move it.")
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
            return .failure("Invalid status: \(statusString). Valid values: pending, paused, interrupted, completed, failed")
        }

        if status == .running {
            return .failure("`running` cannot be set directly — it would create a task that LOOKS in-flight but has no worker, and it blocks the auto-run queue. Use `run_task` to actually start a task (it spawns the worker); if it refuses because another task is running, wait for that task to finish.")
        }
        if status == .awaitingReview {
            return .failure("`awaitingReview` is reserved — it is where acceptance validation parks a task when it ESCALATES, for the USER to resolve from the task row. (Help requests park in `awaitingHelp`.) You cannot set it directly.")
        }
        if status == .awaitingHelp {
            return .failure("`awaitingHelp` is reserved — only Brown's `request_help` parks a task there (and it sets the help request); answer it with `provide_help`. Setting it directly would strand a task that occupies a slot but has no blocker to resolve.")
        }
        if status == .validating {
            return .failure("`validating` is reserved — only Brown's `task_complete` submission enters validation. Setting it directly would strand the task with no validation run attached.")
        }

        guard UpdateTaskStatusPolicy.settable.contains(status) else {
            return .failure("`\(statusString)` cannot be set with update_task. Valid values: \(UpdateTaskStatusPolicy.settable.map(\.rawValue).sorted().joined(separator: ", ")).")
        }
        let templateNote = appliedTemplate.map { " (\($0 ? "now a template" : "no longer a template"))" } ?? ""
        // Already there is success — including a template the toggle above just moved to the library,
        // where the session store's status writer does not reach.
        if await context.taskStore.taskOrLibraryTemplate(id: taskID)?.status == status {
            return .success("Task \(taskIDString) updated to \(statusString)\(templateNote).")
        }
        guard await context.taskStore.updateStatus(id: taskID, status: status, cause: .smithSetStatus) else {
            let current = await context.taskStore.task(id: taskID)?.status.rawValue ?? "not an active task"
            return .failure("Task \(taskIDString) could not be set to \(statusString) from \(current) — that change is not permitted.\(templateNote)")
        }
        return .success("Task \(taskIDString) updated to \(statusString)\(templateNote).")
    }
}
