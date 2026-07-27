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
            switch parseFields(fields) {
            case .success(let criterion): parsed.append(criterion)
            case .failure(let problem): return .failure(problem)
            }
        }
        guard Set(parsed.map(\.name)).count == parsed.count else {
            return .failure(EvaluatorDefaults.AuthoringError("Duplicate criterion names in the list — each display name must be distinct."))
        }
        return .success(parsed)
    }

    /// The per-criterion edit verbs. `update` and `delete` name a `criterion_id` — that is what
    /// preserves identity (and with it the sticky verdict and the rejection history's target)
    /// across an edit that a wholesale replace would destroy by minting a new UUID.
    static func parseActions(_ rawActions: [AnyCodable], origin: TaskAuthorship) -> Result<[CriterionAction], EvaluatorDefaults.AuthoringError> {
        var actions: [CriterionAction] = []
        for raw in rawActions {
            guard case .dictionary(let fields) = raw else {
                return .failure(EvaluatorDefaults.AuthoringError("Every entry in 'actions' must be an object with an 'action' field."))
            }
            guard case .string(let verb) = fields["action"] else {
                return .failure(EvaluatorDefaults.AuthoringError("Every entry in 'actions' requires an 'action' of 'add', 'update', or 'delete'."))
            }
            func criterionID() -> Result<UUID, EvaluatorDefaults.AuthoringError> {
                guard case .string(let raw) = fields["criterion_id"], let id = UUID(uuidString: raw) else {
                    return .failure(EvaluatorDefaults.AuthoringError("'\(verb)' requires a 'criterion_id' UUID. Use get_task_details to read the current criterion ids."))
                }
                return .success(id)
            }
            switch verb {
            case "add":
                switch parseFields(fields) {
                case .success(let criterion):
                    actions.append(.add(
                        name: criterion.name,
                        validationPrompt: criterion.validationPrompt,
                        inputEnumeratorPrompt: criterion.inputEnumeratorPrompt,
                        waivable: criterion.waivable,
                        origin: origin
                    ))
                case .failure(let problem): return .failure(problem)
                }
            case "update":
                switch (criterionID(), parseFields(fields)) {
                case (.success(let id), .success(let criterion)):
                    actions.append(.update(
                        criterionID: id,
                        name: criterion.name,
                        validationPrompt: criterion.validationPrompt,
                        inputEnumeratorPrompt: criterion.inputEnumeratorPrompt,
                        waivable: criterion.waivable
                    ))
                case (.failure(let problem), _), (_, .failure(let problem)): return .failure(problem)
                }
            case "delete":
                switch criterionID() {
                case .success(let id): actions.append(.delete(criterionID: id))
                case .failure(let problem): return .failure(problem)
                }
            default:
                return .failure(EvaluatorDefaults.AuthoringError("Unknown action '\(verb)'. Use 'add', 'update', or 'delete'."))
            }
        }
        guard !actions.isEmpty else {
            return .failure(EvaluatorDefaults.AuthoringError("'actions' must contain at least one action."))
        }
        return .success(actions)
    }

    /// The four authored fields, shared by the replace-all list and the add/update verbs so one
    /// definition of "a well-formed criterion" serves both.
    private static func parseFields(_ fields: [String: AnyCodable]) -> Result<ParsedCriterion, EvaluatorDefaults.AuthoringError> {
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
        return .success(ParsedCriterion(
            name: rawName.trimmingCharacters(in: .whitespacesAndNewlines),
            validationPrompt: rawValidationPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            inputEnumeratorPrompt: inputEnumeratorPrompt,
            waivable: waivable
        ))
    }
}
