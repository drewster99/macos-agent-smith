import Foundation

/// Shared parsing for the task-scoped acceptance-criterion contract used by both creation
/// and editing. Display names are deliberately separated from the prompts sent to LLMs.
enum CriterionArgumentParsing {
    struct ParsedCriterion {
        let name: String
        let validationPrompt: String
        let inputEnumeratorPrompt: String?
        let waivable: Bool
    }

    static func parse(_ rawCriteria: [AnyCodable]) -> Result<[ParsedCriterion], EvaluatorDefaults.AuthoringError> {
        var parsed: [ParsedCriterion] = []
        for raw in rawCriteria {
            guard case .dictionary(let fields) = raw else {
                return .failure(EvaluatorDefaults.AuthoringError("Every criterion must be an object with required 'name' and 'validation_prompt' fields."))
            }
            guard case .string(let rawName) = fields["name"],
                  !rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(EvaluatorDefaults.AuthoringError("Every criterion requires a non-empty 'name' for display."))
            }
            guard case .string(let rawValidationPrompt) = fields["validation_prompt"],
                  !rawValidationPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(EvaluatorDefaults.AuthoringError("Every criterion requires a non-empty 'validation_prompt' containing the instructions for the validation LLM."))
            }
            let inputEnumeratorPrompt: String?
            if case .string(let rawPrompt) = fields["input_enumerator_prompt"],
               !rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                inputEnumeratorPrompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                inputEnumeratorPrompt = nil
            }
            let waivable: Bool
            if case .bool(let value) = fields["waivable"] { waivable = value } else { waivable = false }
            parsed.append(ParsedCriterion(
                name: rawName.trimmingCharacters(in: .whitespacesAndNewlines),
                validationPrompt: rawValidationPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
                inputEnumeratorPrompt: inputEnumeratorPrompt,
                waivable: waivable
            ))
        }
        guard Set(parsed.map(\.name)).count == parsed.count else {
            return .failure(EvaluatorDefaults.AuthoringError("Duplicate criterion names in the list — each display name must be distinct."))
        }
        return .success(parsed)
    }
}
