import Foundation

/// Smith's authoring surface for a task's acceptance criteria — the contract the
/// validation system judges submissions against. Replaces the task's full criteria list;
/// criteria whose text is unchanged keep their identity (and any sticky ACCEPT), while
/// changed or new criteria will be judged fresh. Mid-round edits apply from the next
/// validation round.
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
                        "text": .dictionary([
                            "type": .string("string"),
                            "description": .string("The criterion — one concrete, evidence-checkable requirement.")
                        ]),
                        "waivable": .dictionary([
                            "type": .string("boolean"),
                            "description": .string("Whether the validator may WAIVE this criterion as not applicable. Default false.")
                        ]),
                        "validator_name": .dictionary([
                            "type": .string("string"),
                            "description": .string("Optional registry validator name (from `list_validators`). Omit for the default acceptance validator.")
                        ]),
                        "prepare": .dictionary([
                            "type": .string("string"),
                            "description": .string("Optional registry name of a prepare-kind evaluator, making this criterion DYNAMIC: the prepare function emits a list of items (e.g. every file in a folder, every step in the plan) and EACH item is judged independently by the criterion's validator. Every item must pass. Create prepare functions with `define_validator`.")
                        ]),
                        "inline_validator": .dictionary([
                            "type": .string("object"),
                            "properties": .dictionary([
                                "system_prompt": .dictionary([
                                    "type": .string("string"),
                                    "description": .string("The judgment instructions: what to check and how strictly. Do NOT restate the output format — the ACCEPT/REJECT/WAIVE contract is appended automatically.")
                                ]),
                                "name": .dictionary([
                                    "type": .string("string"),
                                    "description": .string("Optional kebab-case display name for this inline validator.")
                                ])
                            ]),
                            "required": .array([.string("system_prompt")]),
                            "description": .string("An INLINE Smith-authored validator for this one criterion (task-scoped; not saved to the registry). You write only the judgment prompt — grammar, standard inputs, and the read-only evidence toolset are supplied by the system. Mutually exclusive with `validator_name`. For a reusable validator, use `define_validator` instead.")
                        ])
                    ]),
                    "required": .array([.string("text")])
                ]),
                "description": .string("The COMPLETE list of acceptance criteria for the task, replacing any existing list.")
            ])
        ]),
        "required": .array([.string("task_id"), .string("criteria")])
    ]

    /// The `validatorCatalogSummary`, when supplied, is baked into the tool description so
    /// Smith sees the installed validators on every turn without a `list_validators` round
    /// trip (the GhTool auth-snapshot pattern). Registry edits mid-session still surface
    /// through `list_validators`; the baked list refreshes at the next Smith spawn.
    public init(validatorCatalogSummary: String? = nil) {
        var description = """
            Set a task's acceptance criteria — the checklist the automated validation system \
            judges the worker's submission against (you do NOT review routine submissions; \
            validation does). Derive criteria from what the user actually asked for, including any \
            validation the user explicitly requested. Each criterion is judged independently by a \
            validator, so make each one concrete and checkable on evidence. The validator is \
            EXTREMELY strict and literal: write each criterion so a CORRECT result passes even in \
            edge cases — ties, zero/empty results, nonexistent targets (e.g. "identifies the \
            most-starred repository, or reports a tie / that none exists, whichever the data \
            shows"). If the worker can do the task correctly and still fail the criterion as \
            written, the criterion is wrong; repeated no-progress rejections FAIL the task. \
            \
            This REPLACES the task's whole criteria list: pass every criterion that should apply, \
            not just new ones. Criteria whose text is unchanged keep their already-accepted status; \
            edited or new ones are judged fresh (from the next round, if validation is mid-round). \
            \
            Each criterion may name a `validator` from the registry (see `list_validators`); \
            omitted means the default acceptance validator. Set `waivable: true` only where the \
            criterion might genuinely not apply and the validator may say so.
            """
        if let validatorCatalogSummary, !validatorCatalogSummary.isEmpty {
            description += "\n\nInstalled validators (snapshot at your spawn — `list_validators` for the live list):\n" + validatorCatalogSummary
        }
        self.toolDescription = description
    }

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .smith
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard case .string(let taskIDString) = arguments["task_id"], let taskID = UUID(uuidString: taskIDString) else {
            return .failure("Missing or invalid 'task_id' — pass the task's UUID.")
        }
        guard let task = await context.taskStore.task(id: taskID) else {
            return .failure("No task with id \(taskID.uuidString). Use list_tasks to find the right id.")
        }
        guard task.status != .completed && task.status != .failed else {
            return .failure("Task '\(task.title)' is \(task.status.rawValue) — its acceptance criteria can no longer be changed.")
        }
        guard case .array(let rawCriteria) = arguments["criteria"], !rawCriteria.isEmpty else {
            return .failure("'criteria' must be a non-empty array of {text, waivable?, validator?} objects.")
        }

        // Parse + validate against the live registry BEFORE touching the task — a
        // criterion pointing at a missing evaluator would fail every round until fixed.
        // Shared with create_task: strings or {text, waivable?, validator_name?, prepare?,
        // inline_validator?} objects, where inline_validator is a Smith-authored INLINE
        // validator (task-scoped, capability-capped by construction).
        let registry = await context.loadEvaluatorRegistry()
        let parsed: [CriterionArgumentParsing.ParsedCriterion]
        switch CriterionArgumentParsing.parse(rawCriteria, registry: registry) {
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
        let existingByText = Dictionary(task.acceptanceCriteria.map { ($0.text, $0) }, uniquingKeysWith: { a, _ in a })
        let criteria = parsed.map { entry -> AcceptanceCriterion in
            if let existing = existingByText[entry.text] {
                var updated = existing
                updated.waivable = entry.waivable
                updated.validator = entry.validator
                updated.prepare = entry.prepare
                return updated
            }
            return AcceptanceCriterion(text: entry.text, waivable: entry.waivable, origin: .smith, validator: entry.validator, prepare: entry.prepare)
        }

        await context.taskStore.setAcceptanceCriteria(id: taskID, criteria: criteria)

        let rendered = criteria.map { criterion -> String in
            var line = "- \(criterion.text)"
            var qualifiers: [String] = []
            if criterion.waivable { qualifiers.append("waivable") }
            if case .registry(let name) = criterion.validator { qualifiers.append("validator: \(name)") }
            if let prepare = criterion.prepare { qualifiers.append("prepare: \(prepare)") }
            if !qualifiers.isEmpty { line += " (\(qualifiers.joined(separator: ", ")))" }
            return line
        }.joined(separator: "\n")

        await context.taskStore.addUpdate(id: taskID, message: "Acceptance criteria set (\(criteria.count)):\n\(rendered)")
        await context.post(ChannelMessage(
            sender: .agent(context.agentRole),
            content: "Acceptance criteria for \"\(task.title)\" (\(criteria.count)):\n\(rendered)",
            metadata: [
                "messageKind": .string("criteria_updated"),
                "taskID": .string(taskID.uuidString),
                "taskTitle": .string(task.title)
            ]
        ))

        let midRoundNote = task.status == .validating
            ? " Validation is currently running — changes apply from the next round."
            : ""
        return .success("Acceptance criteria set for '\(task.title)' (\(criteria.count) criterion(s)).\(midRoundNote)")
    }
}
