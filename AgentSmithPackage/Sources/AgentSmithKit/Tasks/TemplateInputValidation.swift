import Foundation

public enum TemplateInputValidation {
    public struct ResolvedInputs: Sendable, Equatable {
        /// Resolved, trimmed input values keyed by template input name.
        public var values: [String: String]
        /// Required input names that were not provided with non-empty values.
        public var missingRequiredNames: [String]
    }

    public enum ResolutionResult: Sendable, Equatable {
        /// Resolved input values and any missing required input names.
        case success(ResolvedInputs)
        /// A validation problem that prevents using the provided input values.
        case failure(String)
    }

    /// Validates template input definitions before they are stored on a task.
    public static func validateDefinitions(_ definitions: [TemplateInputDefinition]) -> String? {
        var seen = Set<String>()
        for definition in definitions {
            let name = definition.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name == definition.name, isValidName(name) else {
                return "Invalid template input name '\(definition.name)'. Names must match ^[a-z][a-z0-9_]*$."
            }
            guard seen.insert(name).inserted else {
                return "Duplicate template input name '\(name)'."
            }
            guard !definition.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "Template input '\(name)' requires a non-empty description."
            }
        }
        return nil
    }

    /// Resolves raw user-provided values against the template input definitions.
    public static func resolveValues(
        definitions: [TemplateInputDefinition],
        rawValues: [String: String]
    ) -> ResolutionResult {
        let knownNames = Set(definitions.map(\.name))
        let unknownNames = rawValues.keys.filter { !knownNames.contains($0) }.sorted()
        guard unknownNames.isEmpty else {
            return .failure("Unknown template input(s): \(unknownNames.joined(separator: ", ")). Valid inputs: \(definitions.map(\.name).sorted().joined(separator: ", ")).")
        }

        var normalizedValues: [String: String] = [:]
        for (name, value) in rawValues {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                normalizedValues[name] = trimmed
            }
        }

        let missing = definitions
            .filter { $0.required && normalizedValues[$0.name] == nil }
            .map(\.name)
            .sorted()

        return .success(ResolvedInputs(values: normalizedValues, missingRequiredNames: missing))
    }

    /// Returns a problem when `text` — a field of a TEMPLATE task that will be rendered at
    /// instantiation — references a `{{placeholder}}` naming no defined input. `field` names the
    /// field for the message ("description", "step 2", "criterion \"Builds clean\"").
    ///
    /// Placeholders only exist relative to a definition set, so an EMPTY `definedNames` means
    /// nothing in the text is a placeholder and there is nothing to check. That is what lets an
    /// ordinary task's description mention `{{foo}}` freely, and what lets a task carrying such a
    /// description still be promoted to a template.
    ///
    /// This is the ONLY place an unknown placeholder is rejected. Rendering is deliberately lenient
    /// (see `TemplateStringRenderer.renderSubstitutingDefinedPlaceholders`), so without this check a
    /// typo would reach the worker as literal `{{app_nmae}}` text and be discovered only by reading
    /// the transcript. Checking at authoring time puts the error in front of the author, at the
    /// moment they can still fix it, without ever blocking a run.
    public static func placeholderProblem(in text: String, field: String, definedNames: Set<String>) -> String? {
        guard !definedNames.isEmpty else { return nil }
        guard let problem = TemplateStringRenderer.validate(text, allowedNames: definedNames) else { return nil }
        return "Template \(field): \(problem)"
    }

    /// Returns a problem when any field of `criterion` references an undefined placeholder.
    /// Pass an empty `definedNames` for a non-template task — nothing is a placeholder then.
    public static func placeholderProblem(inCriterion criterion: AcceptanceCriterion, definedNames: Set<String>) -> String? {
        firstProblem(in: AgentTask.templateRenderedTextFields(ofCriterion: criterion), definedNames: definedNames)
    }

    /// Returns a problem when a step's text references an undefined placeholder. `position` is the
    /// step's 1-based place among the ACTIVE steps, matching the numbering everything else shows.
    public static func placeholderProblem(inStep text: String, atPosition position: Int, definedNames: Set<String>) -> String? {
        firstProblem(in: AgentTask.templateRenderedTextFields(ofStep: text, atPosition: position), definedNames: definedNames)
    }

    /// The first labelled field referencing an undefined placeholder, or nil when all are clean.
    /// For the creation paths, which must check every field of a task that does not exist yet —
    /// `TaskStore.addTask` has no way to refuse one, so nothing may be stored until this passes.
    public static func firstProblem(in fields: [(field: String, text: String)], definedNames: Set<String>) -> String? {
        for (field, text) in fields {
            if let problem = placeholderProblem(in: text, field: field, definedNames: definedNames) {
                return problem
            }
        }
        return nil
    }

    /// Returns whether a template input or placeholder name uses the supported identifier format.
    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, isLowercaseLetter(first) else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            isLowercaseLetter(scalar) || isDigit(scalar) || scalar == "_"
        }
    }

    private static func isLowercaseLetter(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= Unicode.Scalar("a").value && scalar.value <= Unicode.Scalar("z").value
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= Unicode.Scalar("0").value && scalar.value <= Unicode.Scalar("9").value
    }
}

/// The field LABELS shared by everything that reports a placeholder problem, so the same offending
/// step reads the same way whether it was caught by the store, by `create_task`, or live in the
/// task editor. Substitution covers `title`, `description`, each ACTIVE step, and each criterion's
/// name / validation prompt / input enumerator prompt (`TaskStore.instantiateTemplate`); the two
/// simple fields are labelled inline by their callers, and the two structured ones get a helper
/// here because they carry a position or a name.
///
/// There is deliberately no whole-task variant. Nothing validates a task's ENTIRE authored text
/// against a definition set any more — see the note in `setTemplateInputDefinitions` for why that
/// made renaming an input impossible. Each write checks the text it writes.
extension AgentTask {
    /// The renderable fields of a single step. `position` is its 1-based place among the ACTIVE
    /// steps, matching the numbering the worker, the briefing, and `get_task_details` all show.
    public static func templateRenderedTextFields(ofStep text: String, atPosition position: Int) -> [(field: String, text: String)] {
        [("step \(position)", text)]
    }

    /// The renderable fields of a single acceptance criterion. `name` is included because for a
    /// default-validated criterion the name IS the judging instruction.
    public static func templateRenderedTextFields(ofCriterion criterion: AcceptanceCriterion) -> [(field: String, text: String)] {
        var fields: [(field: String, text: String)] = [
            ("criterion \"\(criterion.name)\" name", criterion.name),
            ("criterion \"\(criterion.name)\" validation prompt", criterion.validationPrompt)
        ]
        if let inputEnumeratorPrompt = criterion.inputEnumeratorPrompt {
            fields.append(("criterion \"\(criterion.name)\" input enumerator prompt", inputEnumeratorPrompt))
        }
        return fields
    }
}
