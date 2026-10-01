import Foundation

/// Lets Smith relay the ACTUAL user's own accept/reject decision on a task parked in
/// `.awaitingReview` with `awaitingReviewReason == .userAcceptanceRequested` — the park a task
/// enters when its author set `requires_user_acceptance` and every criterion has since settled.
///
/// This is the conversational counterpart to the task row's Accept / Send back buttons: the user
/// can reply "looks good" or "not ready — fix X" in chat instead of clicking one. Smith must call
/// this only in direct response to the user's own words on THIS task — it is relaying a decision,
/// never making one. The runtime refuses the call outright for any other status or escalation
/// reason (in particular a `.validatorError` park, where the MACHINE couldn't judge the work and
/// only the user's own row action may resolve it).
public struct RespondToUserAcceptanceTool: AgentTool {
    public let name = "respond_to_user_acceptance"
    public let toolDescription: String

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "task_id": .dictionary([
                "type": .string("string"),
                "description": .string("UUID of the task parked awaiting the user's acceptance.")
            ]),
            "decision": .dictionary([
                "type": .string("string"),
                "enum": .array([.string("accept"), .string("reject")]),
                "description": .string("accept = the user approved the result as-is; the task completes. reject = the user wants changes; the task goes back to the still-tracked Brown with 'feedback'.")
            ]),
            "feedback": .dictionary([
                "type": .string("string"),
                "description": .string("Required for decision=reject: what the user said needs to change. Not used for accept.")
            ])
        ]),
        "required": .array([.string("task_id"), .string("decision")])
    ]

    public init() {
        self.toolDescription = """
            Relay the user's own accept/reject decision on a task awaiting their acceptance (one \
            where you set `requires_user_acceptance` via set_acceptance_criteria and every criterion \
            has since settled). Call this ONLY in direct response to what the user actually said about \
            THIS task — you are relaying their decision, not forming your own judgment about whether the \
            work is good enough. If the user approves ("looks good", "ship it", "accept"), call with \
            decision=accept. If they want changes ("not ready", "this is broken", "fix X first"), call \
            with decision=reject and feedback=<what they said needs to change> — the task goes back to \
            Brown, who is still tracked and will be resumed. This tool refuses to act on any task that \
            isn't actually parked for user acceptance, including a validator-error escalation — that one \
            can only be resolved by the user directly from the task row, never by you.
            """
    }

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .smith
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard case .string(let taskIDString) = arguments["task_id"], let taskID = UUID(uuidString: taskIDString) else {
            return .failure("Missing or invalid 'task_id' — pass the task's UUID.")
        }
        guard case .string(let decision) = arguments["decision"] else {
            return .failure("Missing 'decision' — pass 'accept' or 'reject'.")
        }
        switch decision {
        case "accept":
            return await context.respondToUserAcceptance(taskID, true, nil)
        case "reject":
            let feedback = ToolArguments.optionalString(arguments, "feedback")
            return await context.respondToUserAcceptance(taskID, false, feedback)
        default:
            return .failure("Invalid 'decision': '\(decision)' — must be 'accept' or 'reject'.")
        }
    }
}
