import Foundation

/// Shared, numbered renderings of a task's acceptance criteria and step list, so the worker's
/// briefing, `get_task_details`, and `manage_steps` all present them the SAME way — including
/// the SAME 1-based numbers. "Criterion 5" and "Step 3" therefore mean the same thing in the
/// briefing, in a tool result, in the validator's rejection punch list, and in the UI.
extension AgentTask {

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
    func renderedAcceptanceCriteria(includeVerdicts: Bool, includePrompts: Bool = false) -> String? {
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
            var block = "**Criterion \(index + 1)**\(suffix)\(verdict)\n\(criterion.text)"
            if includePrompts {
                block += "\nValidation prompt:\n\(criterion.validationPrompt)"
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
