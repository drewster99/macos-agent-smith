import Foundation

/// Brown tool: reports that one of the task's declared preconditions is false (#18), which BLOCKS the
/// task at once — no result, no validation rounds spent on a task whose premise doesn't hold.
///
/// Only a DECLARED precondition can be reported (the runtime refuses any other id, and re-checks one
/// it can check itself), so this is never a way out of hard work: an undeclared blocker goes through
/// `request_help`. After a report is accepted the worker stops; the runtime ends it.
public struct ReportPreconditionUnmetTool: AgentTool {
    public let name = "report_precondition_unmet"
    public let toolDescription = """
        Report that one of this task's DECLARED preconditions (listed in your briefing under \
        "Preconditions", each with its id) is false. The task is then BLOCKED immediately — no result is \
        submitted and nothing is validated — and you stop. Use it only for a listed precondition, with \
        concrete evidence (what you checked and what you found). For any other blocker use `request_help`; \
        for finished work use `task_complete`.
        """

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "precondition_id": .dictionary([
                "type": .string("string"),
                "description": .string("The id of the precondition, exactly as your briefing lists it.")
            ]),
            "evidence": .dictionary([
                "type": .string("string"),
                "description": .string("What you checked and what you found that shows it is false.")
            ])
        ]),
        "required": .array([.string("precondition_id"), .string("evidence")])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .brown
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard case .string(let rawID) = arguments["precondition_id"] else {
            throw ToolCallError.missingRequiredArgument("precondition_id")
        }
        guard case .string(let evidence) = arguments["evidence"] else {
            throw ToolCallError.missingRequiredArgument("evidence")
        }
        guard let preconditionID = UUID(uuidString: rawID.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .failure("'\(rawID)' is not a precondition id. Use the id your briefing lists for the precondition.")
        }
        let trimmedEvidence = evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEvidence.isEmpty else {
            return .failure("`evidence` must say what you checked and what you found.")
        }
        switch await context.reportPreconditionUnmet(preconditionID, trimmedEvidence) {
        case .blocked(let reason):
            return .success("The task is BLOCKED — \(reason). Stop now: do not call any more tools or submit a result.")
        case .refused(let why):
            return .failure(why)
        }
    }
}
