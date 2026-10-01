import Foundation

/// Allows Smith to terminate the live Brown worker assigned to a task.
struct TerminateAgentTool: AgentTool {
    let name = "terminate_agent"
    let toolDescription = "Terminate the running Brown worker assigned to a task."

    public func description(for role: AgentRole) -> String {
        switch role {
        case .smith:
            return "Terminate the running Brown worker assigned to a task, using the task ID."
        default:
            return toolDescription
        }
    }

    let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "task_id": .dictionary([
                "type": .string("string"),
                "description": .string("The UUID of the task whose running Brown worker should be terminated.")
            ]),
            "reason": .dictionary([
                "type": .string("string"),
                "description": .string("Reason for termination.")
            ])
        ]),
        "required": .array([.string("task_id"), .string("reason")])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .smith
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard case .string(let taskIDString) = arguments["task_id"] else {
            throw ToolCallError.missingRequiredArgument("task_id")
        }
        guard case .string(let reason) = arguments["reason"] else {
            throw ToolCallError.missingRequiredArgument("reason")
        }
        guard let taskID = UUID(uuidString: taskIDString) else {
            return .failure("Invalid task ID format: \(taskIDString)")
        }
        guard let task = await context.taskStore.task(id: taskID) else {
            return .failure("No active task found with ID \(taskIDString). Call `list_tasks` to see the current tasks.")
        }

        // Resolve the worker FROM the task. Looking up `.brown` by role returns the oldest
        // live worker, which is arbitrary once several tasks are running concurrently.
        guard let workerID = await context.workerIDForTask(taskID) else {
            return .failure("No live Brown worker is assigned to task \(taskIDString) (\"\(task.title)\"). It may have already been terminated.")
        }

        // Defense in depth: the production resolver only returns live Brown workers, but keep
        // the termination boundary closed if a future resolver accidentally returns another role.
        guard await context.agentRoleForID(workerID) == .brown else {
            return .failure("The live assignee resolved for task \(taskIDString) is not a Brown worker; no agent was terminated.")
        }

        let success = await context.terminateAgent(workerID, context.agentID)
        if success {
            // `terminateAgent` owns agent teardown and deliberately does not impose a task
            // disposition: UI pause/stop flows use the same callback and choose their own state.
            // This tool, however, promises Smith that an explicitly killed worker leaves a failed,
            // retryable task. Use compare-and-set so a submission that raced into validation or
            // completion is never overwritten by the stale task snapshot above.
            let markedFailed = await context.taskStore.updateStatus(
                id: taskID,
                to: .failed,
                ifCurrentlyIn: [.running, .awaitingHelp],
                cause: .smithTerminatedWorker
            )
            if markedFailed {
                await context.taskStore.addUpdate(
                    id: taskID,
                    message: "Brown worker terminated by \(context.agentRole.displayName): \(reason)"
                )
            }
            await context.post(ChannelMessage(
                sender: .system,
                content: "Brown worker \(workerID.uuidString) for task \"\(task.title)\" (\(taskIDString)) terminated by \(context.agentRole.displayName): \(reason)",
                metadata: ["messageKind": .kind(.agentLifecycle)],
                taskID: taskID
            ))
            let taskOutcome = markedFailed
                ? " The task was marked failed and can be retried with `run_task`."
                : " The task had already moved beyond active work, so its status was left unchanged."
            return .success("Brown worker for task \(taskIDString) (\"\(task.title)\") terminated successfully.\(taskOutcome)")
        } else {
            return .failure("Failed to terminate the Brown worker for task \(taskIDString) — the worker was not found or had already stopped.")
        }
    }
}
