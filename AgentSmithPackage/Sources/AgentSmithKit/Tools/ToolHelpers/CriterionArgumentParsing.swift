import Foundation

/// Shared parsing for acceptance-criteria tool arguments — used by both
/// `set_acceptance_criteria` and `create_task` so the two accept the same shapes.
///
/// Each array element is either a plain STRING (criterion text, default validator) or an
/// OBJECT: `{text, waivable?, validator_name?, prepare?, inline_validator?}` where
/// `inline_validator` is `{system_prompt, name?, description?}` — an INLINE Smith-authored
/// validator embedded on the criterion (task-scoped, capability-capped to the read-only
/// evidence tools by construction and re-checked at judge time). A validator reached via a
/// criterion's `prepare` automatically judges each enumerated item.
enum CriterionArgumentParsing {

    struct ParsedCriterion {
        let text: String
        let waivable: Bool
        let validator: AcceptanceCriterion.Validator?
        let prepare: String?
    }

    /// Parses and validates the `criteria`/`acceptance_criteria` array. Registry names
    /// are checked against the LIVE registry before anything is applied — a criterion
    /// pointing at a missing evaluator would otherwise fail every future validation
    /// round. Returns the parsed criteria or a human-readable refusal.
    static func parse(
        _ rawCriteria: [AnyCodable],
        registry: EvaluatorRegistry?
    ) -> Result<[ParsedCriterion], EvaluatorDefaults.AuthoringError> {
        var parsed: [ParsedCriterion] = []
        for raw in rawCriteria {
            switch raw {
            case .string(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                parsed.append(ParsedCriterion(text: trimmed, waivable: false, validator: nil, prepare: nil))

            case .dictionary(let fields):
                guard case .string(let text) = fields["text"],
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return .failure(EvaluatorDefaults.AuthoringError("Every criterion must be a string, or an object with a non-empty 'text'."))
                }
                var waivable = false
                if case .bool(let flag) = fields["waivable"] { waivable = flag }

                var validator: AcceptanceCriterion.Validator?
                if case .string(let named) = fields["validator_name"], !named.trimmingCharacters(in: .whitespaces).isEmpty {
                    guard let registry else {
                        return .failure(EvaluatorDefaults.AuthoringError("Cannot name validator '\(named)': no evaluator registry is configured."))
                    }
                    guard let definition = registry.definition(named: named), definition.kind == .validator else {
                        let available = registry.definitions(ofKind: .validator).map(\.name).joined(separator: ", ")
                        return .failure(EvaluatorDefaults.AuthoringError("Validator '\(named)' is not in the registry. Available validators: \(available.isEmpty ? "(none)" : available). Use list_validators for descriptions, or define_validator to create one."))
                    }
                    validator = .registry(named)
                }

                if case .dictionary(let customFields) = fields["inline_validator"] {
                    guard validator == nil else {
                        return .failure(EvaluatorDefaults.AuthoringError("A criterion can have EITHER a registry `validator_name` OR an `inline_validator`, not both."))
                    }
                    guard case .string(let prompt) = customFields["system_prompt"],
                          !prompt.trimmingCharacters(in: .whitespaces).isEmpty else {
                        return .failure(EvaluatorDefaults.AuthoringError("`inline_validator` requires a non-empty 'system_prompt' — the judgment instructions."))
                    }
                    var inlineName = "inline-validator"
                    if case .string(let named) = customFields["name"], !named.trimmingCharacters(in: .whitespaces).isEmpty {
                        inlineName = named
                    }
                    var inlineDescription = "Inline validator authored for this criterion."
                    if case .string(let description) = customFields["description"], !description.trimmingCharacters(in: .whitespaces).isEmpty {
                        inlineDescription = description
                    }
                    switch EvaluatorDefaults.makeCustomDefinition(
                        name: inlineName,
                        description: inlineDescription,
                        kind: .validator,
                        authoredPrompt: prompt
                    ) {
                    case .success(let definition):
                        validator = .inline(definition)
                    case .failure(let problem):
                        return .failure(EvaluatorDefaults.AuthoringError("Invalid inline_validator: \(problem.message)"))
                    }
                }

                var prepare: String?
                if case .string(let named) = fields["prepare"], !named.trimmingCharacters(in: .whitespaces).isEmpty {
                    guard let registry else {
                        return .failure(EvaluatorDefaults.AuthoringError("Cannot name prepare function '\(named)': no evaluator registry is configured."))
                    }
                    guard let definition = registry.definition(named: named), definition.kind == .prepare else {
                        let available = registry.definitions(ofKind: .prepare).map(\.name).joined(separator: ", ")
                        return .failure(EvaluatorDefaults.AuthoringError("Prepare function '\(named)' is not in the registry (or is not kind=prepare). Available prepare functions: \(available.isEmpty ? "(none)" : available). Use define_validator with kind: \"prepare\" to create one."))
                    }
                    prepare = named
                }
                parsed.append(ParsedCriterion(text: text.trimmingCharacters(in: .whitespacesAndNewlines), waivable: waivable, validator: validator, prepare: prepare))

            default:
                return .failure(EvaluatorDefaults.AuthoringError("Every criterion must be a string or a {text, waivable?, validator_name?, prepare?, inline_validator?} object."))
            }
        }
        let uniqueTexts = Set(parsed.map(\.text))
        guard uniqueTexts.count == parsed.count else {
            return .failure(EvaluatorDefaults.AuthoringError("Duplicate criterion texts in the list — each criterion must be distinct."))
        }
        return .success(parsed)
    }
}
