import Foundation

/// Allows Smith to amend a task's description with additional context from the user.
///
/// Amendments are appended to the task description with a clear label so Security Agent (who
/// reads `taskDescription` on every tool-approval request) sees the updated intent.
/// When a Brown is actively running the amended task, the amendment is also delivered
/// directly into that live Brown's conversation. Brown's briefing is a one-time spawn
/// snapshot, so without this the running Brown would never see post-spawn amendments —
/// while Security Agent keeps citing them — which is exactly the desync that sends Brown
/// hunting for content it can't see. Delivery is automatic and deterministic; Smith
/// does not need to follow up with `message_brown`.
struct AmendTaskTool: AgentTool {
    let name = "amend_task"
    let toolDescription = "Add a clarification or updated instruction to a task's description. Use this when the user provides new context, corrections, or additional requirements for an in-progress task. The amendment is appended to the description (visible to Security Agent on every security check) and, if a Brown is currently running this task, delivered to that live Brown automatically — you do NOT need to message_brown afterward. Optionally attach files via `attachment_ids`; they're added to the task's description attachments and forwarded to the live Brown with the amendment (and re-injected into Brown's briefing on any future respawn)."

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

        let deliveredToBrown = await deliverToLiveBrown(
            taskID: taskID,
            amendment: trimmed,
            attachments: attachments,
            context: context
        )

        let attachmentSuffix: String
        if attachments.isEmpty {
            attachmentSuffix = ""
        } else {
            let names = attachments.map { $0.filename }.joined(separator: ", ")
            attachmentSuffix = " with \(attachments.count) attachment(s): \(names)"
        }

        if deliveredToBrown {
            return .success("Task \(taskIDString) amended\(attachmentSuffix). The change was delivered to the running Brown automatically — do NOT message_brown about it.")
        }
        return .success("Task \(taskIDString) amended\(attachmentSuffix). No running Brown is assigned to this task, so the amendment will be included in Brown's briefing when the task is next started.")
    }

    /// Injects the amendment into a running Brown's conversation so the live agent sees
    /// post-spawn changes immediately. Gated on Brown actually running THIS task —
    /// matching how Security Agent locates the task it evaluates against — so amending a queued or
    /// unrelated task never interrupts a Brown working something else. Sent as a private
    /// `.system` message (not attributed to Smith) so Brown treats it as authoritative
    /// task content rather than optional supervisor chatter. Returns whether it delivered.
    private func deliverToLiveBrown(
        taskID: UUID,
        amendment: String,
        attachments: [Attachment],
        context: ToolContext
    ) async -> Bool {
        guard let brownID = await context.agentIDForRole(.brown),
              let task = await context.taskStore.task(id: taskID),
              task.assigneeIDs.contains(brownID),
              task.status == .running else {
            return false
        }

        let content = "[Task description amended] The following has been added to your task description — treat it as authoritative task content:\n\n\(amendment)"
        await context.post(ChannelMessage(
            sender: .system,
            recipientID: brownID,
            recipient: .agent(.brown),
            content: content,
            attachments: attachments,
            taskID: taskID
        ))
        return true
    }
}
