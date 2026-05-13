import Foundation

/// Allows Smith to terminate a Brown agent by ID.
struct TerminateAgentTool: AgentTool {
    let name = "terminate_agent"
    let toolDescription = "Terminate a running agent by its ID."

    public func description(for role: AgentRole) -> String {
        switch role {
        case .smith:
            return "Terminate a running Brown agent by its ID."
        default:
            return toolDescription
        }
    }

    let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "agent_id": .dictionary([
                "type": .string("string"),
                "description": .string("The UUID of the agent to terminate.")
            ]),
            "reason": .dictionary([
                "type": .string("string"),
                "description": .string("Reason for termination.")
            ])
        ]),
        "required": .array([.string("agent_id"), .string("reason")])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .smith
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard case .string(let agentIDString) = arguments["agent_id"] else {
            throw ToolCallError.missingRequiredArgument("agent_id")
        }
        guard case .string(let reason) = arguments["reason"] else {
            throw ToolCallError.missingRequiredArgument("reason")
        }
        guard let agentID = UUID(uuidString: agentIDString) else {
            return .failure("Invalid agent ID format: \(agentIDString)")
        }

        guard let targetRole = await context.agentRoleForID(agentID) else {
            return .failure("No agent found with ID \(agentIDString). It may have already been terminated.")
        }

        // Smith may only terminate Brown agents.
        guard targetRole == .brown else {
            return .failure("Smith may only terminate Brown agents. Agent \(agentIDString) is a \(targetRole.displayName) agent.")
        }

        let success = await context.terminateAgent(agentID, context.agentID)
        if success {
            await context.post(ChannelMessage(
                sender: .system,
                content: "Agent \(agentIDString) terminated by \(context.agentRole.displayName): \(reason)"
            ))
            return .success("Agent \(agentIDString) terminated successfully.")
        } else {
            return .failure("Failed to terminate agent \(agentIDString) — agent not found or already stopped.")
        }
    }
}
