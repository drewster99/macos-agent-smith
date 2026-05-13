import Foundation

/// Smith tool: cancels a single scheduled wake by id. Use when the user has changed their mind
/// or the reason for the wake no longer applies.
struct CancelWakeTool: AgentTool {
    let name = "cancel_wake"
    let toolDescription = """
        Cancel a scheduled wake by id. Use `list_scheduled_wakes` to find ids. \
        No-op if the id does not exist (returns a clear message).
        """

    let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "wake_id": .dictionary([
                "type": .string("string"),
                "description": .string("UUID of the wake to cancel.")
            ])
        ]),
        "required": .array([.string("wake_id")])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .smith
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard case .string(let idString) = arguments["wake_id"] else {
            throw ToolCallError.missingRequiredArgument("wake_id")
        }
        guard let id = UUID(uuidString: idString) else {
            return .failure("Invalid wake_id: '\(idString)' is not a valid UUID.")
        }
        let cancelled = await context.cancelScheduledWake(id)
        return cancelled
            ? .success("Wake \(id.uuidString) cancelled.")
            : .failure("No wake found with id \(id.uuidString). Use list_scheduled_wakes to see current ids.")
    }
}
