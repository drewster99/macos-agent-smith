import Foundation

/// Smith's authoring surface for a task's acceptance criteria — the contract the validation system
/// judges submissions against.
///
/// Two modes, exactly one per call. `criteria` replaces the whole list and is for FIRST-TIME
/// authoring; once the task has been validated it is refused if it would drop a criterion, because
/// a name-matched replacement mints a new UUID and silently retires the old criterion's verdicts.
/// `actions` is a batch of per-criterion add/update/delete applied all-or-nothing, where `update`
/// names a `criterion_id` and so preserves identity (and the sticky ACCEPT, when the contract text
/// is unchanged).
///
/// Criteria can only be edited in a state where no worker or validator is consuming them
/// (`Status.isValidationContractEditable`) — the same gate `manage_steps` has always had. There are
/// no mid-round edits: changing the rules while a validator is judging against them is the race the
/// gate exists to prevent.
public struct SetAcceptanceCriteriaTool: AgentTool {
    public let name = "set_acceptance_criteria"
    public let toolDescription: String

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "task_id": .dictionary([
                "type": .string("string"),
                "description": .string("UUID of the task whose criteria to set.")
            ]),
            "criteria": .dictionary([
                "type": .string("array"),
                "items": .dictionary([
                    "type": .string("object"),
                    "properties": .dictionary([
                        "name": .dictionary([
                            "type": .string("string"),
                            "description": .string("Short display name. Display-only; not an LLM instruction.")
                        ]),
                        "waivable": .dictionary([
                            "type": .string("boolean"),
                            "description": .string("Whether the validator may WAIVE this criterion as not applicable. Default false.")
                        ]),
                        "validation_prompt": .dictionary([
                            "type": .string("string"),
                            "description": .string("Required instructions for the LLM that judges this criterion. State what to check and what evidence is sufficient. The judge sees ONLY this criterion — never the others — so the prompt must be self-contained and scoped to this ONE deliverable. Never write \"all work is complete\" or reference other criteria.")
                        ]),
                        "input_enumerator_prompt": .dictionary([
                            "type": .string("string"),
                            "description": .string("Optional instructions for an LLM that MUST return a JSON array containing only strings. Each string is passed separately to the validation LLM together with validation_prompt; every item must pass.")
                        ])
                    ]),
                    "required": .array([.string("name"), .string("validation_prompt")])
                ]),
                "description": .string("The COMPLETE list of acceptance criteria for the task, replacing any existing list. First-time authoring only — once the task has been validated, edit with 'actions' instead. Mutually exclusive with 'actions'.")
            ]),
            "actions": .dictionary([
                "type": .string("array"),
                "items": .dictionary([
                    "type": .string("object"),
                    "properties": .dictionary([
                        "action": .dictionary([
                            "type": .string("string"),
                            "enum": .array([.string("add"), .string("update"), .string("delete")]),
                            "description": .string("add = append a new criterion; update = restate an existing criterion by id, keeping its identity and any verdict it already earned; delete = remove it.")
                        ]),
                        "criterion_id": .dictionary([
                            "type": .string("string"),
                            "description": .string("UUID of the criterion to update or delete. Read current ids from get_task_details. Required for update and delete; ignored for add.")
                        ]),
                        "name": .dictionary([
                            "type": .string("string"),
                            "description": .string("Short display name. Display-only; not an LLM instruction. Required for add and update.")
                        ]),
                        "waivable": .dictionary([
                            "type": .string("boolean"),
                            "description": .string("Whether the validator may WAIVE this criterion as not applicable. Default false.")
                        ]),
                        "validation_prompt": .dictionary([
                            "type": .string("string"),
                            "description": .string("Required for add and update: the instructions for the LLM that judges this criterion. The judge sees ONLY this criterion, so the prompt must be self-contained and scoped to this ONE deliverable — never \"all work is complete\" or a reference to another criterion.")
                        ]),
                        "input_enumerator_prompt": .dictionary([
                            "type": .string("string"),
                            "description": .string("Optional instructions for an LLM that MUST return a JSON array containing only strings. Each string is passed separately to the validation LLM together with validation_prompt; every item must pass.")
                        ])
                    ]),
                    "required": .array([.string("action")])
                ]),
                "description": .string("Per-criterion edits applied as one atomic batch — either all of them land or none do. Mutually exclusive with 'criteria'.")
            ])
        ]),
        "required": .array([.string("task_id")])
    ]

    public init() {
        let description = """
            Set a task's acceptance criteria — the checklist the automated validation system \
            judges the worker's submission against (you do NOT review routine submissions; \
            validation does). Derive criteria from what the user actually asked for, including any \
            validation the user explicitly requested. Each criterion is judged independently by a \
            validator on EVIDENCE — files, command output, recorded tool activity — never on the \
            worker's say-so, so each criterion must name the concrete proof that satisfies it (the \
            file and its contents, the command output, a log at a path, a URL/path to the artifact). \
            Phrase as "X must be true; evidence of completion: <the artifact/output that proves it>". \
            A criterion asserting an outcome with no checkable proof cannot be accepted and will stall \
            the task. Write each criterion as STRUCTURED MARKDOWN — not a run-on sentence — and make \
            its logic explicit: all-required parts → a list under "must include ALL of:"; alternatives \
            (this OR that) → a nested list under "must be ONE of:". \
            The validator is EXTREMELY strict and literal: write each criterion so a CORRECT \
            result passes even in edge cases — ties, zero/empty results, nonexistent targets (e.g. \
            "identifies the most-starred repository, or reports a tie / that none exists, whichever \
            the data shows"). If the worker can do the task correctly and still fail the criterion as \
            written, the criterion is wrong; repeated no-progress rejections FAIL the task. \
            \
            Criteria must be ORTHOGONAL and SELF-CONTAINED. The judge of a criterion sees ONLY \
            that criterion — never the rest of the contract — so it cannot know what another \
            criterion covers: never write "as required by the other criteria" or "matches the \
            format above". Scope each criterion to exactly ONE deliverable, and never let two \
            criteria assert the same underlying fact. An umbrella criterion ("final commit of \
            ALL work", "everything is complete") invites the judge to re-audit the entire task: \
            one unresolved defect then rejects several criteria at once, every rejection round \
            re-litigates that same defect once per overlapping criterion, and the no-progress \
            failure budget burns down several times faster. A commit criterion judges commit \
            evidence (hash + diff), not whether the committed work is complete — other criteria \
            already judge that. \
            \
            TWO MODES, and you must pass exactly one. `criteria` REPLACES the whole list and is for \
            FIRST-TIME authoring — pass every criterion that should apply, not just new ones. Once a \
            task has been validated, replace-all is refused, because rewriting the list mints new \
            criterion ids and throws away every verdict and rejection recorded against the old ones. \
            To change a contract after that, use `actions`: a batch of {action: add|update|delete} \
            entries applied all-or-nothing, where `update` names a `criterion_id` and so keeps the \
            criterion's identity, its sticky ACCEPT if the contract text is unchanged, and its \
            rejection history. Read current criterion ids from `get_task_details`. \
            Criteria whose validation prompt, input enumerator prompt, or waivable flag changes are \
            judged fresh next round; unchanged ones keep their verdicts. \
            \
            `name` is display-only. `validation_prompt` is required and is the sole authored \
            instruction sent to the judging LLM. Optional `input_enumerator_prompt` must produce a \
            JSON array of strings; each string is handed separately to the judging LLM together \
            with `validation_prompt`, and every item must pass. Set `waivable: true` only where the \
            criterion might genuinely not apply and the validator may say so. \
            HARD GATES: when the task description states a MUST-FAIL / abort precondition ("MUST FAIL", \
            "fail immediately", "do not proceed if"), encode it as a `waivable: false` criterion that FAILS \
            when the condition is not met — with NO OR-alternative or "document and continue" escape. \
            Honoring a user-declared failure IS correctness; the "don't be over-strict" rule does not apply to it.
            """
        self.toolDescription = description
    }

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .smith
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard case .string(let taskIDString) = arguments["task_id"], let taskID = UUID(uuidString: taskIDString) else {
            return .failure("Missing or invalid 'task_id' — pass the task's UUID.")
        }
        guard let task = await context.taskStore.taskOrLibraryTemplate(id: taskID) else {
            return .failure("No task with id \(taskID.uuidString). Use list_tasks to find the right id.")
        }
        // A FAILED task is recoverable: fixing its criteria is exactly how you recover from a
        // failure whose criteria were wrong, then `run_task` (which resets failed → pending) re-runs
        // it against the corrected contract. Only a COMPLETED task — result accepted and delivered —
        // is truly closed to criteria edits.
        guard task.status != .completed else {
            return .failure("Task '\(task.title)' is completed — its acceptance criteria can no longer be changed.")
        }
        // Same gate `manage_steps` has carried all along, and for a stronger reason: this tool edits
        // the validation contract itself, so letting it land while a worker or validator is actively
        // consuming that contract changes the rules mid-judgment. The store re-checks atomically —
        // this one exists to fail early with an explanation rather than after parsing.
        guard task.status.isValidationContractEditable else {
            return .failure("Task '\(task.title)' is \(task.status.rawValue) — its acceptance criteria can't be edited while a worker or validator is active. Criteria are editable when the task is pending, paused, interrupted, scheduled, failed, or awaiting review.")
        }
        let rawCriteria: [AnyCodable]? = { if case .array(let value) = arguments["criteria"] { return value }; return nil }()
        let rawActions: [AnyCodable]? = { if case .array(let value) = arguments["actions"] { return value }; return nil }()
        switch (rawCriteria, rawActions) {
        case (nil, nil):
            return .failure("Pass either 'criteria' (replace the whole list — first-time authoring) or 'actions' (per-criterion add/update/delete).")
        case (.some, .some):
            return .failure("Pass 'criteria' OR 'actions', not both: one replaces the whole list, the other edits criteria individually.")
        case (nil, .some(let actions)):
            return await applyActions(actions, to: task, context: context)
        case (.some, nil):
            break
        }

        guard let rawCriteria, !rawCriteria.isEmpty else {
            return .failure("'criteria' must be a non-empty array of {name, validation_prompt, input_enumerator_prompt?, waivable?} objects.")
        }

        // Parse the complete task-scoped prompt contract before touching the task.
        let parsed: [CriterionArgumentParsing.ParsedCriterion]
        switch CriterionArgumentParsing.parse(rawCriteria) {
        case .success(let criteria):
            parsed = criteria
        case .failure(let problem):
            return .failure(problem.message)
        }
        guard !parsed.isEmpty else {
            return .failure("'criteria' must contain at least one non-empty criterion.")
        }

        // Unchanged text keeps the criterion's identity so its sticky ACCEPT survives;
        // the store drops verdicts for anything that actually changed.
        let existingByName = Dictionary(task.acceptanceCriteria.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let criteria = parsed.map { entry -> AcceptanceCriterion in
            if let existing = existingByName[entry.name] {
                var updated = existing
                updated.waivable = entry.waivable
                updated.validationPrompt = entry.validationPrompt
                updated.inputEnumeratorPrompt = entry.inputEnumeratorPrompt
                return updated
            }
            return AcceptanceCriterion(name: entry.name, validationPrompt: entry.validationPrompt, inputEnumeratorPrompt: entry.inputEnumeratorPrompt, waivable: entry.waivable, origin: .smith)
        }

        if let problem = await context.taskStore.setAcceptanceCriteria(id: taskID, criteria: criteria) {
            return .failure(problem)
        }

        let rendered = Self.renderCriteriaList(criteria)

        await context.taskStore.addUpdate(id: taskID, message: "Acceptance criteria set (\(criteria.count)):\n\(rendered)")
        await context.post(ChannelMessage(
            sender: .agent(context.agentRole),
            content: "Acceptance criteria for \"\(task.title)\" (\(criteria.count)):\n\(rendered)",
            metadata: [
                "messageKind": .kind(.criteriaUpdated),
                "taskID": .string(taskID.uuidString),
                "taskTitle": .string(task.title)
            ]
        ))

        return .success("Acceptance criteria set for '\(task.title)' (\(criteria.count) criterion(s)).")
    }

    /// The per-criterion path. The store applies the batch atomically, so a rejected action leaves
    /// the contract exactly as it was — the caller never has to reason about a partial edit.
    private func applyActions(_ rawActions: [AnyCodable], to task: AgentTask, context: ToolContext) async -> ToolExecutionResult {
        guard !rawActions.isEmpty else {
            return .failure("'actions' must be a non-empty array of {action, ...} objects.")
        }
        let actions: [CriterionAction]
        switch CriterionArgumentParsing.parseActions(rawActions, origin: .smith) {
        case .success(let parsed): actions = parsed
        case .failure(let problem): return .failure(problem.message)
        }
        if let problem = await context.taskStore.applyCriterionActions(taskID: task.id, actions: actions) {
            return .failure(problem)
        }
        guard let updated = await context.taskStore.taskOrLibraryTemplate(id: task.id) else {
            return .failure("Task \(task.id.uuidString) disappeared while its criteria were being edited.")
        }

        let summary = Self.describe(actions)
        let rendered = Self.renderCriteriaList(updated.acceptanceCriteria)
        await context.taskStore.addUpdate(id: task.id, message: "Acceptance criteria edited (\(summary)). Now \(updated.acceptanceCriteria.count):\n\(rendered)")
        await context.post(ChannelMessage(
            sender: .agent(context.agentRole),
            content: "Acceptance criteria for \"\(updated.title)\" edited (\(summary)) — now \(updated.acceptanceCriteria.count):\n\(rendered)",
            metadata: [
                "messageKind": .kind(.criteriaUpdated),
                "taskID": .string(task.id.uuidString),
                "taskTitle": .string(updated.title)
            ]
        ))
        return .success("Acceptance criteria for '\(updated.title)' edited (\(summary)); the task now has \(updated.acceptanceCriteria.count) criterion(s).")
    }

    private static func describe(_ actions: [CriterionAction]) -> String {
        var added = 0, updated = 0, deleted = 0
        for action in actions {
            switch action {
            case .add: added += 1
            case .update: updated += 1
            case .delete: deleted += 1
            }
        }
        return [(added, "added"), (updated, "updated"), (deleted, "deleted")]
            .filter { $0.0 > 0 }
            .map { "\($0.0) \($0.1)" }
            .joined(separator: ", ")
    }

    private static func renderCriteriaList(_ criteria: [AcceptanceCriterion]) -> String {
        criteria.map { criterion -> String in
            var line = "- \(criterion.name)"
            var qualifiers: [String] = []
            if criterion.waivable { qualifiers.append("waivable") }
            if criterion.inputEnumeratorPrompt != nil { qualifiers.append("enumerated inputs") }
            if !qualifiers.isEmpty { line += " (\(qualifiers.joined(separator: ", ")))" }
            return line
        }.joined(separator: "\n")
    }
}
