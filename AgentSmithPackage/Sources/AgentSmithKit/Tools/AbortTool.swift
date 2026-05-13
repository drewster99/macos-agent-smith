import Foundation

/// Emergency abort: stops all agents immediately. Requires user interaction to restart.
struct AbortTool: AgentTool {
    let name = "abort"
    let toolDescription = "Emergency abort: immediately stops ALL agents. The system cannot be restarted without user interaction. Use only for serious safety concerns / violations."

    let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "reason": .dictionary([
                "type": .string("string"),
                "description": .string("Clear explanation of why the abort is necessary.")
            ])
        ]),
        "required": .array([.string("reason")])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .smith
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard case .string(let reason) = arguments["reason"] else {
            throw ToolCallError.missingRequiredArgument("reason")
        }

        await context.abort(reason, context.agentRole)
        return .success("ABORT executed. All agents stopped. User must restart the system.")
    }
}
