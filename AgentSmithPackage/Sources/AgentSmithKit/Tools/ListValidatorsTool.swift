import Foundation

/// Smith's view of the evaluator registry: the validators available for acceptance
/// criteria, with descriptions, plus any definition files that failed to load (a broken
/// registry must be visible at selection time, not discovered mid-validation).
public struct ListValidatorsTool: AgentTool {
    public let name = "list_validators"
    public let toolDescription = """
        List the acceptance validators available in the registry, with descriptions. Use \
        this when setting acceptance criteria (`set_acceptance_criteria`) to pick a \
        validator suited to a criterion — e.g. one specialized for accessibility, file \
        hygiene, or whatever the registry offers. Criteria that don't name a validator use \
        the default acceptance validator.
        """

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([:])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .smith
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard let registry = await context.loadEvaluatorRegistry() else {
            return .failure("No evaluator registry is configured — validation will escalate every submission for manual review.")
        }
        let validators = registry.definitions(ofKind: .validator)
        var sections: [String] = []
        if validators.isEmpty {
            sections.append("No validators are installed. Criteria cannot name one; validation will escalate.")
        } else {
            sections.append("Available validators:\n" + validators.map { definition in
                "- `\(definition.name)`: \(definition.description)"
            }.joined(separator: "\n"))
        }
        if !registry.failures.isEmpty {
            sections.append("Definition files that FAILED to load (tell the user — these need fixing in the evaluators directory):\n" + registry.failures.map {
                "- \($0.fileName): \($0.problem)"
            }.joined(separator: "\n"))
        }
        return .success(sections.joined(separator: "\n\n"))
    }
}
