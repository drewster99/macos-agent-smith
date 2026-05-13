import Foundation

/// Smith tool: sends a private message to the human user.
/// Replaces send_message(recipient_id: "user") for Smith's tool set.
struct MessageUserTool: AgentTool {
    let name = "message_user"
    let toolDescription = """
        Send a message to the human user. Use for status updates, questions, and delivering \
        final results. Write as if speaking directly to a person — do not expose internal \
        orchestration details. Optionally forward attachments via `attachment_ids` (UUID \
        strings from `[filename](file://…) … id=<UUID>` markdown links) — useful when sharing \
        a file Brown produced or referencing a file the user originally provided.
        """

    let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "message": .dictionary([
                "type": .string("string"),
                "description": .string("The message to send to the user.")
            ]),
            "attachment_ids": .dictionary([
                "type": .string("array"),
                "items": .dictionary(["type": .string("string")]),
                "description": .string("Optional UUID strings of existing attachments to deliver to the user. Use the EXACT id values from `[filename](file://…) … id=<UUID>` markdown links you've seen.")
            ])
        ]),
        "required": .array([.string("message")])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .smith
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard case .string(let message) = arguments["message"] else {
            throw ToolCallError.missingRequiredArgument("message")
        }

        let resolution = await TaskUpdateTool.resolveAttachments(arguments: arguments, context: context)
        if let failureMessage = resolution.failure {
            return .failure(failureMessage)
        }
        let attachments = resolution.attachments

        await context.post(ChannelMessage(
            sender: .agent(context.agentRole),
            recipientID: OrchestrationRuntime.userID,
            recipient: .user,
            content: message,
            attachments: attachments
        ))

        if attachments.isEmpty {
            return .success("Message sent to user.")
        }
        let names = attachments.map { $0.filename }.joined(separator: ", ")
        return .success("Message sent to user with \(attachments.count) attachment(s): \(names)")
    }
}
