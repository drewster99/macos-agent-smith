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

    /// The required capabilities as a bullet list, ONE rendering for every agent-facing reader
    /// (worker briefing, `get_task_details`, tool scoping, per-call security review, validators).
    /// People get `renderedRequiredCapabilitiesForPeople()`. A later addition is marked with who added it, when, and why, so a
    /// reader can tell the task as written from what was learned while running it. Nil when the
    /// task lists none.
    public func renderedRequiredCapabilities() -> String? {
        guard !requiredCapabilities.isEmpty else { return nil }
        return requiredCapabilities.map { "- \($0.renderedLine)" }.joined(separator: "\n")
    }

    /// The `requiredCapabilities` entry every `.taskCreated` banner carries, so the user sees what
    /// the worker was asked to be able to do where the task first appears. Empty when none.
    func taskCreatedBannerCapabilitiesMetadata() -> [String: AnyCodable] {
        guard let capabilities = renderedRequiredCapabilitiesForPeople() else { return [:] }
        return ["requiredCapabilities": .string(capabilities)]
    }

    /// The required capabilities as a bullet list for PEOPLE: the PDF export, Task Detail's copy
    /// button, and the `.taskCreated` banner. Nil when the task lists none.
    public func renderedRequiredCapabilitiesForPeople() -> String? {
        guard !requiredCapabilities.isEmpty else { return nil }
        return requiredCapabilities.map { capability in
            guard let caption = capability.laterAdditionCaption else { return "- \(capability.text)" }
            return "- \(capability.text) (\(caption))"
        }.joined(separator: "\n")
    }

    /// The description as the Security Agent reviews a single tool call against it: the same
    /// composition every other reader gets, followed by the required capabilities — what the
    /// worker is expected to need to do, which bears directly on whether a call fits the task.
    func renderedDescriptionForSecurityReview() -> String {
        let description = renderedDescriptionWithTemplateInputs()
        guard let capabilities = renderedRequiredCapabilities() else { return description }
        return "\(description)\n\n## Required capabilities\n\(capabilities)"
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

    /// Appended to every non-empty tool scope: the global policy is not on the task, so the lines
    /// above cannot show its effect, and without this a Never tool read as granted.
    static let toolScopeGlobalPolicyNote = "Not shown: the user's global tool policy (Settings) applies on top — a tool set to Never is withheld even if approved or turned on above; a tool set to Always is added unless turned off above."

    /// The per-task tool scope, rendered for `get_task_details`: the Security Agent's approved
    /// worker toolset (`approvedTools`) followed by any persisted user overrides that turn a tool
    /// on or off (`userToolOverrides`), then `toolScopeGlobalPolicyNote`. This reads the SAME per-task state the task-detail screen's
    /// tool editor (`TaskToolOverrideEditor`) shows — a **record** of what was scoped for this task's
    /// worker, not the live enforcement gate (the running worker's `ToolRegistry` is authoritative,
    /// and always-available forced lifecycle tools are not listed). The global `ToolPolicy` is
    /// deliberately NOT folded in: it isn't carried on the task, so folding it here would fabricate a
    /// resolved set from state `get_task_details` cannot see. An override-free line therefore reports
    /// exactly the security verdict, and overrides are shown separately rather than merged.
    ///
    /// Returns `nil` when the task carries no scope information at all — never scoped and no
    /// overrides — so `get_task_details` omits the section just as it does for absent criteria/steps.
    func renderedToolScope() -> String? {
        var lines: [String] = []
        if let approvedTools {
            let list = approvedTools.isEmpty ? "(none)" : approvedTools.sorted().joined(separator: ", ")
            lines.append("Approved tools (security-scoped worker toolset): \(list)")
        }
        if let userToolOverrides, !userToolOverrides.isEmpty {
            // An override for a tool no worker can have is stored but never applied; reporting it
            // as turned on told the reader the worker had a tool it did not.
            let effective = userToolOverrides.filter { BrownBehavior.acceptsToolOverride(named: $0.key) }
            let ignored = userToolOverrides.keys.filter { !BrownBehavior.acceptsToolOverride(named: $0) }.sorted()
            let turnedOn = effective.filter { $0.value }.keys.sorted()
            let turnedOff = effective.filter { !$0.value }.keys.sorted()
            var parts: [String] = []
            if !turnedOn.isEmpty { parts.append("turned on: \(turnedOn.joined(separator: ", "))") }
            if !turnedOff.isEmpty { parts.append("turned off: \(turnedOff.joined(separator: ", "))") }
            if !ignored.isEmpty { parts.append("ignored, not worker tools: \(ignored.joined(separator: ", "))") }
            lines.append("User tool overrides for this task — \(parts.joined(separator: "; "))")
        }
        guard !lines.isEmpty else { return nil }
        lines.append(Self.toolScopeGlobalPolicyNote)
        return lines.joined(separator: "\n")
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
