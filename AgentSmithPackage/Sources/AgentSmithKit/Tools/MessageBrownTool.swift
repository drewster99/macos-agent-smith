import Foundation

/// Smith tool: sends a private message to Agent Brown.
/// Replaces send_message(recipient_id: "brown") for Smith's tool set.
struct MessageBrownTool: AgentTool {
    let name = "message_brown"
    let toolDescription = """
        Send a message to Agent Brown. Use for task instructions, corrections, and follow-ups. \
        Be specific and unambiguous — Brown is literal and may misinterpret vague instructions. \
        Optionally forward attachments via `attachment_ids` (UUID strings from `[filename](file://…) … id=<UUID>` markdown links).
        """

    let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "message": .dictionary([
                "type": .string("string"),
                "description": .string("The message to send to Brown.")
            ]),
            "attachment_ids": .dictionary([
                "type": .string("array"),
                "items": .dictionary(["type": .string("string")]),
                "description": .string("Optional UUID strings of existing attachments to forward to Brown with this message. Use the EXACT id values from the `[filename](file://…) … id=<UUID>` markdown links in your context.")
            ])
        ]),
        "required": .array([.string("message")])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .smith && !context.hasAwaitingReviewTasks
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        // Defense-in-depth: reject if any task is awaiting review, even if the tool was
        // presented from a stale definition cache. Smith should use review_work instead.
        let activeTasks = await context.taskStore.allTasks().filter { $0.disposition == .active }
        if activeTasks.contains(where: { $0.status == .awaitingReview }) {
            return .failure("Cannot message Brown while a task is awaiting review. Use `review_work` to accept or reject the submission first.")
        }

        guard case .string(let message) = arguments["message"] else {
            throw ToolCallError.missingRequiredArgument("message")
        }

        let resolution = await TaskUpdateTool.resolveAttachments(arguments: arguments, context: context)
        if let failureMessage = resolution.failure {
            return .failure(failureMessage)
        }
        let attachments = resolution.attachments

        guard let brownID = await context.agentIDForRole(.brown) else {
            return .failure("No active Brown agent found. Use `run_task` to start a task — it will spawn Brown automatically.")
        }

        await context.post(ChannelMessage(
            sender: .agent(context.agentRole),
            recipientID: brownID,
            recipient: .agent(.brown),
            content: message,
            attachments: attachments
        ))

        if attachments.isEmpty {
            return .success("Message sent to Brown.")
        }
        let names = attachments.map { $0.filename }.joined(separator: ", ")
        return .success("Message sent to Brown with \(attachments.count) attachment(s): \(names)")
    }
}
