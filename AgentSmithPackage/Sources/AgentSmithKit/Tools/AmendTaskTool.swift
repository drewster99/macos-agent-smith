import Foundation

/// Allows Smith to amend a task's description with additional context from the user.
///
/// Amendments are appended to the task description with a clear label, so both
/// Brown (via `message_brown`) and Jones (who reads `taskDescription` on every
/// tool-approval request) see the updated intent.
struct AmendTaskTool: AgentTool {
    let name = "amend_task"
    let toolDescription = "Add a clarification or updated instruction to a task's description. Use this when the user provides new context, corrections, or additional requirements for an in-progress task. The amendment is visible to Jones (security) and should also be relayed to Brown via `message_brown`. Optionally attach files via `attachment_ids` — they're appended to the task's description attachments and re-injected into Brown's briefing on the next respawn (the LIVE Brown won't see them automatically; relay via `message_brown(attachment_ids: [...])`)."

    let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "task_id": .dictionary([
                "type": .string("string"),
                "description": .string("The UUID of the task to amend.")
            ]),
            "amendment": .dictionary([
                "type": .string("string"),
                "description": .string("The clarification or updated instruction to append to the task description.")
            ]),
            "attachment_ids": .dictionary([
                "type": .string("array"),
                "items": .dictionary(["type": .string("string")]),
                "description": .string("Optional UUID strings of existing attachments to add to the task's description attachments. Forward EXACT id values from `[filename](file://…) … id=<UUID>` markdown links you've seen.")
            ])
        ]),
        "required": .array([.string("task_id"), .string("amendment")])
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
        guard case .string(let amendment) = arguments["amendment"] else {
            throw ToolCallError.missingRequiredArgument("amendment")
        }
        let trimmed = amendment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure("Error: amendment must not be empty.")
        }

        guard await context.taskStore.task(id: taskID) != nil else {
            return .failure("Task not found: \(taskIDString)")
        }

        let resolution = await TaskUpdateTool.resolveAttachments(arguments: arguments, context: context)
        if let failureMessage = resolution.failure {
            return .failure(failureMessage)
        }
        let attachments = resolution.attachments

        await context.taskStore.amendDescription(id: taskID, amendment: trimmed, attachments: attachments)
        if attachments.isEmpty {
            return .success("Task \(taskIDString) amended. Immediately use the `message_brown` tool to relay this change to Brown.")
        }
        let names = attachments.map { $0.filename }.joined(separator: ", ")
        return .success("Task \(taskIDString) amended with \(attachments.count) attachment(s): \(names). Immediately use `message_brown(attachment_ids: [...])` to deliver them to the LIVE Brown — the amendment alone only updates the task store for future respawns.")
    }
}
