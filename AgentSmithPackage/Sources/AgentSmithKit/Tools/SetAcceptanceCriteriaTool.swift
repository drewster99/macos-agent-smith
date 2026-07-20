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
                            "description": .string("Required instructions for the LLM that judges this criterion. State what to check and what evidence is sufficient.")
                        ]),
                        "input_enumerator_prompt": .dictionary([
                            "type": .string("string"),
                            "description": .string("Optional instructions for an LLM that MUST return a JSON array containing only strings. Each string is passed separately to the validation LLM together with validation_prompt; every item must pass.")
                        ])
                    ]),
                    "required": .array([.string("name"), .string("validation_prompt")])
                ]),
                "description": .string("The COMPLETE list of acceptance criteria for the task, replacing any existing list.")
            ])
        ]),
        "required": .array([.string("task_id"), .string("criteria")])
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
            This REPLACES the task's whole criteria list: pass every criterion that should apply, \
            not just new ones. Criteria whose name is unchanged keep their identity; criteria whose \
            validation prompt, input enumerator prompt, or waivable flag changes are judged fresh \
            (from the next round, if validation is mid-round). \
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
        guard let task = await context.taskStore.task(id: taskID) else {
            return .failure("No task with id \(taskID.uuidString). Use list_tasks to find the right id.")
        }
        // A FAILED task is recoverable: fixing its criteria is exactly how you recover from a
        // failure whose criteria were wrong, then `run_task` (which resets failed → pending) re-runs
        // it against the corrected contract. Only a COMPLETED task — result accepted and delivered —
        // is truly closed to criteria edits.
        guard task.status != .completed else {
            return .failure("Task '\(task.title)' is completed — its acceptance criteria can no longer be changed.")
        }
        guard case .array(let rawCriteria) = arguments["criteria"], !rawCriteria.isEmpty else {
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
                updated.validator = nil
                updated.prepare = nil
                return updated
            }
            return AcceptanceCriterion(name: entry.name, validationPrompt: entry.validationPrompt, inputEnumeratorPrompt: entry.inputEnumeratorPrompt, waivable: entry.waivable, origin: .smith)
        }

        await context.taskStore.setAcceptanceCriteria(id: taskID, criteria: criteria)

        let rendered = criteria.map { criterion -> String in
            var line = "- \(criterion.name)"
            var qualifiers: [String] = []
            if criterion.waivable { qualifiers.append("waivable") }
            if criterion.inputEnumeratorPrompt != nil { qualifiers.append("enumerated inputs") }
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
