import Foundation

/// Brown tool: sends a private message directly to the user.
/// Only available when the user has directly messaged this agent within the last 10 minutes.
struct ReplyToUserTool: AgentTool {
    let name = "reply_to_user"
    let toolDescription = """
        Send a private reply to the user. Only available when the user has messaged you directly \
        within the last 10 minutes. Optionally attach files via `attachment_ids` (existing UUIDs) \
        or `attachment_paths` (local file paths to read, persist, and attach).
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
                "description": .string("Optional UUID strings of existing attachments to deliver to the user.")
            ]),
            "attachment_paths": .dictionary([
                "type": .string("array"),
                "items": .dictionary(["type": .string("string")]),
                "description": .string("Optional local file paths to read and deliver to the user (e.g. screenshots or files you produced).")
            ])
        ]),
        "required": .array([.string("message")])
    ]

    private static let availabilityWindow: TimeInterval = 10 * 60

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        guard context.agentRole == .brown else { return false }
        guard let lastMessage = context.lastDirectUserMessageAt else { return false }
        return Date().timeIntervalSince(lastMessage) <= Self.availabilityWindow
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
            return .success("Reply sent to user.")
        }
        let names = attachments.map { $0.filename }.joined(separator: ", ")
        return .success("Reply sent to user with \(attachments.count) attachment(s): \(names)")
    }
}
