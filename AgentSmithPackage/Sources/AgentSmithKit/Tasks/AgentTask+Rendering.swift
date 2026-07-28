import Foundation

/// Shared, numbered renderings of a task's acceptance criteria and step list, so the worker's
/// briefing, `get_task_details`, and `manage_steps` all present them the SAME way — including
/// the SAME 1-based numbers. "Criterion 5" and "Step 3" therefore mean the same thing in the
/// briefing, in a tool result, in the validator's rejection punch list, and in the UI.
extension AgentTask {
    /// The `## Template inputs` block — the named values this run was instantiated with — rendered
    /// in ONE place so the worker briefing and `renderedDescriptionWithTemplateInputs` cannot drift
    /// into two different headers. Nil when the task carries no input values, i.e. everything that
    /// isn't a template instance.
    ///
    /// Kept even though `{{name}}` placeholders are now substituted inline through the title,
    /// description, steps, criteria, and instance amendments, because substitution DESTROYS the
    /// name→value binding: the rendered text shows `/Users/me/Foo.app`, never `app_path`. An input
    /// no placeholder references has no inline carrier at all, and instances written before
    /// substitution existed still hold literal `{{name}}` on disk. This block is the only place
    /// the NAMES survive — including for `SecurityEvaluator.pathResolutionAppendix`, which
    /// harvests path candidates out of it.
    ///
    /// Carries no explanatory prose on purpose. Any sentence about what `{{placeholder}}` means is
    /// false for one of those three populations, and this string also reaches the Security Agent on
    /// every tool call, the user's New Task banner, and the semantic-retrieval embedding query —
    /// which is cosine-gated at fixed thresholds, so boilerplate identical across every instance
    /// would shift every query vector.
    func renderedTemplateInputsSection() -> String? {
        guard let templateInputValues = renderedTemplateInputValues() else { return nil }
        return "## Template inputs\n\(templateInputValues)"
    }

    /// The inputs render ABOVE the description (2026-07-28, user decision): the name→value list
    /// is the run's identity ("which app is this?"), so it leads everywhere the description is
    /// consumed — worker briefing, validator input slot, transcript banners, task detail — rather
    /// than trailing thousands of characters of prose. Composed at render time, never baked into
    /// the stored `description`: the stored values are the single source, amendments still append
    /// to the authored text without threading past a machine-written header, and pre-existing
    /// instances pick the placement up retroactively.
    /// Public because the task-detail UI displays this same composition; the description EDITOR
    /// must keep seeding from the raw `description` — the block is not authored text.
    public func renderedDescriptionWithTemplateInputs() -> String {
        guard let section = renderedTemplateInputsSection() else { return description }
        return "\(section)\n\n\(description)"
    }

    var hasSubmittedResult: Bool {
        !(result?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    func renderedTemplateInputDefinitions() -> String? {
        guard !templateInputDefinitions.isEmpty else { return nil }
        return templateInputDefinitions.map { definition in
            let requirement = definition.required ? "required" : "optional"
            return "- \(definition.name) [\(requirement)]: \(definition.description)"
        }.joined(separator: "\n")
    }

    func renderedTemplateInputValues() -> String? {
        guard !templateInputValues.isEmpty else { return nil }
        return templateInputValues.keys.sorted().map { name in
            "- \(name): \(templateInputValues[name] ?? "")"
        }.joined(separator: "\n")
    }

    var missingRequiredTemplateInputNames: [String] {
        templateInputDefinitions
            .filter {
                $0.required && (templateInputValues[$0.name]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            }
            .map(\.name)
            .sorted()
    }

    /// The acceptance criteria as a numbered list. Criterion N is its 1-based position in
    /// `acceptanceCriteria`. When `includeVerdicts` is true, each line carries the latest
    /// verdict (ACCEPT / REJECT — reason / …) from the validation ledger, so a resuming worker
    /// sees at a glance which criteria still need work. When `includePrompts` is true, the
    /// task-scoped validator and input-enumerator prompts are included for full contract
    /// inspection. Returns `nil` when there are no criteria.
    /// Each criterion renders as a markdown block — a bold `**Criterion N**` header (with any
    /// qualifiers/verdict) followed by the criterion's own text on the next line. A header (rather
    /// than a `N. ` list prefix) so a criterion whose text is itself structured markdown — nested
    /// lists making "must be ONE of …" / "must include ALL of …" explicit — renders cleanly instead
    /// of colliding with the outer numbering.
    /// `includeIDs` prints each criterion's UUID, which `set_acceptance_criteria`'s per-criterion
    /// `actions` need in order to target `update`/`delete` — the same reason `renderedSteps` carries
    /// step ids for `manage_steps`. Without them the edit verbs have nothing to name.
    func renderedAcceptanceCriteria(includeVerdicts: Bool, includePrompts: Bool = false, includeIDs: Bool = false) -> String? {
        guard !acceptanceCriteria.isEmpty else { return nil }
        let ledger = validation
        let blocks = acceptanceCriteria.enumerated().map { index, criterion -> String in
            var qualifiers: [String] = []
            if criterion.waivable { qualifiers.append("waivable") }
            if criterion.inputEnumeratorPrompt != nil { qualifiers.append("enumerated inputs") }
            let suffix = qualifiers.isEmpty ? "" : " _(\(qualifiers.joined(separator: ", ")))_"
            let verdict = includeVerdicts
                ? (ledger?.latestVerdict(for: criterion.id)).map { " — \(OrchestrationRuntime.describeVerdict($0))" } ?? ""
                : ""
            let identifier = includeIDs ? " (id: \(criterion.id.uuidString))" : ""
            var block = "**Criterion \(index + 1)**\(identifier)\(suffix)\(verdict)\n\(criterion.text)"
            if includePrompts {
                // A default-validated criterion carries no authored prompt (empty); its stance is
                // the shipped default, so there's nothing to print here.
                if !criterion.usesDefaultValidator {
                    block += "\nValidation prompt:\n\(criterion.validationPrompt)"
                }
                if let inputEnumeratorPrompt = criterion.inputEnumeratorPrompt, !inputEnumeratorPrompt.isEmpty {
                    block += "\nInput enumerator prompt:\n\(inputEnumeratorPrompt)"
                }
            }
            return block
        }
        return blocks.joined(separator: "\n\n")
    }

    /// The step list as a numbered list. Step N is its 1-based position among the ACTIVE
    /// (non-removed) steps. Removed steps are tombstones — counted for the validators' benefit
    /// but not numbered here. When `includeIDs` is true, each line also carries the step's UUID,
    /// which `manage_steps` needs so the worker can target `update`/`set_status`/`delete`.
    /// Returns `nil` when there are no steps at all.
    func renderedSteps(includeIDs: Bool) -> String? {
        guard !steps.isEmpty else { return nil }
        let active = steps.filter(\.isActive)
        let removedCount = steps.count - active.count
        var lines = active.enumerated().map { index, step -> String in
            var line = "\(index + 1). [\(step.status.rawValue)] \(step.text)"
            if includeIDs { line += " (id: \(step.id.uuidString))" }
            if let note = step.note, !note.isEmpty { line += " — note: \(note)" }
            return line
        }
        if active.isEmpty {
            lines.append("(no active steps)")
        }
        if removedCount > 0 {
            lines.append("(\(removedCount) removed step(s) remain on the record for validators)")
        }
        return lines.joined(separator: "\n")
    }
}
