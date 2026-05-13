import Foundation

/// Allows Smith to archive, soft-delete, unarchive, or undelete tasks.
struct ManageTaskDispositionTool: AgentTool {
    let name = "manage_task_disposition"
    let toolDescription = """
        Move a task between active, archived, and recently-deleted buckets. \
        Tasks must be completed or failed before they can be archived or deleted. \
        Use unarchive or undelete to restore tasks back to the active list.
        """

    let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "task_id": .dictionary([
                "type": .string("string"),
                "description": .string("The UUID of the task.")
            ]),
            "action": .dictionary([
                "type": .string("string"),
                "enum": .array([
                    .string("archive"),
                    .string("delete"),
                    .string("unarchive"),
                    .string("undelete")
                ]),
                "description": .string(
                    "archive: move to archive. delete: soft-delete (recoverable). " +
                    "unarchive: restore archived task to active. undelete: recover a deleted task."
                )
            ])
        ]),
        "required": .array([.string("task_id"), .string("action")])
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
            return .failure("Invalid task ID format: \(taskIDString)")
        }
        guard case .string(let action) = arguments["action"] else {
            throw ToolCallError.missingRequiredArgument("action")
        }

        guard let task = await context.taskStore.task(id: taskID) else {
            return .failure("Task not found: \(taskIDString)")
        }

        switch action {
        case "archive":
            let success = await context.taskStore.archive(id: taskID)
            if success {
                return .success("Task '\(task.title)' archived.")
            }
            return .failure("Cannot archive task '\(task.title)' — it is currently \(task.status.rawValue). Only completed or failed tasks can be archived.")

        case "delete":
            let success = await context.taskStore.softDelete(id: taskID)
            if success {
                return .success("Task '\(task.title)' moved to Recently Deleted.")
            }
            return .failure("Cannot delete task '\(task.title)' — it is currently \(task.status.rawValue). Only completed or failed tasks can be deleted.")

        case "unarchive":
            guard task.disposition == .archived else {
                return .failure("Task '\(task.title)' is not archived (current disposition: \(task.disposition.rawValue)).")
            }
            await context.taskStore.unarchive(id: taskID)
            return .success("Task '\(task.title)' restored to active list.")

        case "undelete":
            guard task.disposition == .recentlyDeleted else {
                return .failure("Task '\(task.title)' is not in Recently Deleted (current disposition: \(task.disposition.rawValue)).")
            }
            await context.taskStore.undelete(id: taskID)
            return .success("Task '\(task.title)' recovered to active list.")

        default:
            return .failure("Unknown action '\(action)'. Use: archive, delete, unarchive, or undelete.")
        }
    }
}
