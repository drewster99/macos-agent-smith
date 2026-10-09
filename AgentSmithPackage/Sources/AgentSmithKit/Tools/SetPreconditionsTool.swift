import Foundation

/// Smith's authoring surface for a task's preconditions (#18) — what must be true for the task to be
/// worth running. Replace-all: pass the complete list, keeping an existing precondition by its `id`.
///
/// Gated like the acceptance contract (`Status.isValidationContractEditable`), and the store refuses
/// to change a user's precondition or the one the task is blocked on (`TaskStore.setPreconditions`).
public struct SetPreconditionsTool: AgentTool {
    public let name = "set_preconditions"
    public let toolDescription = """
        Set the PRECONDITIONS of a task: things that must be true for it to be worth running at all. \
        They are checked before every worker start (a file exists, a command is installed, the \
        worker's model can read images or PDFs); a worker_checked one is verified by the worker, \
        which reports it false. If one doesn't hold, the task is BLOCKED at once — no work is done \
        and no validation rounds are spent. Use preconditions for any MUST-FAIL / do-not-proceed \
        condition in the request; never encode one as an acceptance criterion. Replaces the whole \
        list: include every precondition to keep, with its `id` from get_task_details. Allowed only \
        while the task isn't running or being validated.
        """

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "task_id": .dictionary([
                "type": .string("string"),
                "description": .string("UUID of the task.")
            ]),
            "preconditions": PreconditionArguments.arraySchema
        ]),
        "required": .array([.string("task_id"), .string("preconditions")])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .smith
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard case .string(let rawTaskID) = arguments["task_id"] else {
            throw ToolCallError.missingRequiredArgument("task_id")
        }
        guard let taskID = UUID(uuidString: rawTaskID.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .failure("'\(rawTaskID)' is not a task id.")
        }
        guard let raw = arguments["preconditions"] else {
            throw ToolCallError.missingRequiredArgument("preconditions")
        }
        guard let task = await context.taskStore.taskOrLibraryTemplate(id: taskID) else {
            return .failure("No task with id \(taskID.uuidString). Use list_tasks to find the right id.")
        }
        let preconditions: [TaskPrecondition]
        switch PreconditionArguments.parse(raw, origin: .smith, existing: task.preconditions) {
        case .success(let parsed): preconditions = parsed
        case .failure(let problem): return .failure("Nothing was changed — \(problem.message)")
        }
        if let refusal = await context.taskStore.setPreconditions(id: taskID, preconditions, by: .smith) {
            return .failure("Nothing was changed — \(refusal)")
        }
        guard !preconditions.isEmpty else {
            return .success("Task '\(task.title)' has no preconditions now.")
        }
        let list = preconditions.map { "- \($0.kind.summary)" }.joined(separator: "\n")
        return .success("Preconditions of '\(task.title)' set; they are checked before every start:\n\(list)")
    }
}
