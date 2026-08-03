import Foundation

/// Step-list management for the task plan that acceptance validators read alongside the
/// result. Brown edits its OWN task's list as work proceeds; Smith edits a specific task's
/// plan (via `task_id`) when no worker is active — e.g. adjusting a premade or template
/// task's steps before it runs. Steps churn freely, but the record is append-only
/// underneath — skipping or removing a step requires a note, and removal is a tombstone
/// (hidden from the active list, permanently visible to validators).
public struct ManageStepsTool: AgentTool {
    public let name = "manage_steps"
    public let toolDescription = """
        Manage your task's step list — your ORDERED working plan, visible to the user and to the \
        acceptance validators that judge your submission. Keep it current: add steps as you \
        discover work, mark them in_progress/completed as you go, and keep them in the order you \
        will do them. If a plan was seeded for you, it is YOURS — refine THIS list \
        (update / set_status / reorder / delete). Do NOT start a second parallel plan; a \
        duplicated, half-checked list is a direct path to rejection. \
        \
        Targeting: the worker (Brown) always edits its OWN task — omit `task_id`. The orchestrator \
        (Smith) edits a specific task's plan by passing `task_id` (e.g. to adjust a premade or \
        template task's steps before a worker runs), and only while that task has no active worker \
        (pending, paused, interrupted, scheduled, failed, or awaiting review). \
        \
        Actions: `add` (one `text` or several `texts`, appended in order), `update` (reword a \
        step: `step_id` + `text`), `set_status` (`step_id` + `status` — the reversible states \
        pending/in_progress/completed/skipped; `skipped` REQUIRES a `note`), `delete` (`step_id` \
        + `note` — removes a step from the active list while leaving it on the record for \
        validators), `move` (reposition ONE step: `step_id` plus exactly one of \
        `before_step_id`, `after_step_id`, or `position`), `reorder` (`step_ids`: every active \
        step id, in the new order — prefer `move` unless you are genuinely rewriting the whole \
        sequence), and `list` (show the current list with ids). \
        \
        Proper use of `set_status`: You MUST call `set_status` as SOON as the status changes. \
        For example, if you have a step that is "Enumerate directory contents", you MUST call \
        `set_status` with a status of `in_progress` BEFORE you make the tool call to enumerate the \
        directory contents. Once that call returns successfully, you must immediately call `set_status` \
        again, with a status of `completed`. This way, the display to the user is perfectly accurate at all times. \
        Every action returns the full, numbered, current list, except `set_status`, which only shows the \
        updated item.\
        \
        Honesty matters: validators see every skipped/removed step and its note. Quietly \
        dropping planned work is the fastest way to get your submission rejected.
        """

    /// Appended for the orchestrator only. Brown never sees `purge` in its description OR its
    /// schema: a capability the worker must not have is best not advertised to it, and the
    /// runtime check in `execute` is then a backstop rather than the only line of defence.
    private static let purgeAddendum = """


        `purge` (`step_id`) is yours alone: it HARD-deletes a step — no tombstone, no note, no \
        trace. It works only on a plan nobody has run or judged yet (a template, or a task that \
        has never started and has no validation history); anywhere else it is refused. Use it to \
        shape a draft or template plan — to tidy a step you worded badly, or drop one that never \
        belonged. Never reach for it to make a real run's record look tidier; `delete` is the \
        honest verb for that, and the record it leaves is the point.
        """

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "action": .dictionary([
                "type": .string("string"),
                "enum": .array(Self.actionNames(includePurge: false).map { .string($0) }),
                "description": .string("The step-list operation to perform.")
            ]),
            "task_id": .dictionary([
                "type": .string("string"),
                "description": .string("Smith only: the UUID of the task whose step list to edit. The worker omits this and always edits its own assigned task.")
            ]),
            "text": .dictionary([
                "type": .string("string"),
                "description": .string("For `add`: the new step. For `update`: the replacement wording.")
            ]),
            "texts": .dictionary([
                "type": .string("array"),
                "items": .dictionary(["type": .string("string")]),
                "description": .string("For `add`: several steps at once, in order.")
            ]),
            "step_id": .dictionary([
                "type": .string("string"),
                "description": .string("For `update`/`set_status`/`delete`/`purge`/`move`: the step's UUID (shown by `list` and in every response).")
            ]),
            "step_ids": .dictionary([
                "type": .string("array"),
                "items": .dictionary(["type": .string("string")]),
                "description": .string("For `reorder`: EVERY active step's UUID, exactly once, in the new order.")
            ]),
            "before_step_id": .dictionary([
                "type": .string("string"),
                "description": .string("For `move`: place the moved step immediately BEFORE this active step's UUID.")
            ]),
            "after_step_id": .dictionary([
                "type": .string("string"),
                "description": .string("For `move`: place the moved step immediately AFTER this active step's UUID.")
            ]),
            "position": .dictionary([
                "type": .string("integer"),
                "description": .string("For `move`: the 1-based slot among the active steps to move this step into, matching the numbering shown by `list`. 1 makes it first.")
            ]),
            "status": .dictionary([
                "type": .string("string"),
                "enum": .array([.string("pending"), .string("in_progress"), .string("completed"), .string("skipped")]),
                "description": .string("For `set_status`: the new status. `skipped` requires `note`. To remove a step use the `delete` action — removal is permanent and is not a status.")
            ]),
            "note": .dictionary([
                "type": .string("string"),
                "description": .string("Why a step was skipped or deleted. Required for both; validators read it.")
            ])
        ]),
        "required": .array([.string("action")])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .brown || context.agentRole == .smith
    }

    public func description(for role: AgentRole) -> String {
        role == .smith ? toolDescription + Self.purgeAddendum : toolDescription
    }

    public func parameters(for role: AgentRole) -> [String: AnyCodable] {
        guard role == .smith else { return parameters }
        var withPurge = parameters
        guard case .dictionary(var properties) = withPurge["properties"],
              case .dictionary(var actionSchema) = properties["action"] else {
            return parameters
        }
        actionSchema["enum"] = .array(Self.actionNames(includePurge: true).map { .string($0) })
        properties["action"] = .dictionary(actionSchema)
        withPurge["properties"] = .dictionary(properties)
        return withPurge
    }

    /// Single source for the action vocabulary, so the schema Brown sees and the schema Smith
    /// sees can't drift apart except in the one intended way.
    private static func actionNames(includePurge: Bool) -> [String] {
        var names = ["add", "update", "set_status", "delete"]
        if includePurge { names.append("purge") }
        names.append(contentsOf: ["move", "reorder", "list"])
        return names
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        // Brown edits its own assigned task and authors steps as the worker. Smith names a task by
        // `task_id`, may only touch it when no worker/validator is active (the same predicate the
        // UI uses to gate step editing), and authors steps as the orchestrator.
        let task: AgentTask
        let author: TaskAuthorship
        switch context.agentRole {
        case .brown:
            guard let bound = await context.taskStore.taskForAgent(agentID: context.agentID) else {
                return .failure("No active task assigned to you.")
            }
            task = bound
            author = .worker
        case .smith:
            guard case .string(let raw) = arguments["task_id"], let taskID = UUID(uuidString: raw) else {
                return .failure("`task_id` is required — the UUID of the task whose step list to edit (find it with `list_tasks` or `get_task_details`). The worker omits this and edits its own task; you must name the task.")
            }
            guard let resolved = await context.taskStore.taskOrLibraryTemplate(id: taskID) else {
                return .failure("No active task found with id \(taskID).")
            }
            guard resolved.status.isValidationContractEditable else {
                return .failure("Task \"\(resolved.title)\" is \(resolved.status.rawValue) — its step list can't be edited while a worker or validator is active. Steps are editable when the task is pending, paused, interrupted, scheduled, failed, or awaiting review.")
            }
            task = resolved
            author = .smith
        default:
            return .failure("manage_steps is not available to this agent.")
        }
        guard case .string(let action) = arguments["action"] else {
            return .failure("Missing required argument 'action' (add | update | set_status | delete | reorder | list).")
        }

        switch action {
        case "list":
            return .success(await Self.renderedStepList(taskID: task.id, context: context))

        case "add":
            var newTexts: [String] = []
            if case .array(let raw) = arguments["texts"] {
                newTexts = raw.compactMap { if case .string(let s) = $0 { return s }; return nil }
            }
            if case .string(let single) = arguments["text"] {
                newTexts.append(single)
            }
            newTexts = newTexts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !newTexts.isEmpty else {
                return .failure("`add` requires `text` or a non-empty `texts` array.")
            }
            for text in newTexts {
                if let error = await context.taskStore.applyStepAction(taskID: task.id, action: .add(text: text, origin: author)) {
                    return .failure(error)
                }
            }
            return .success("Added \(newTexts.count) step(s).\n\n\(await Self.renderedStepList(taskID: task.id, context: context))")

        case "update":
            guard let stepID = Self.stepID(from: arguments) else {
                return .failure("`update` requires `step_id` (a UUID from `list`).")
            }
            guard case .string(let text) = arguments["text"], !text.trimmingCharacters(in: .whitespaces).isEmpty else {
                return .failure("`update` requires non-empty `text` — the replacement wording.")
            }
            if let error = await context.taskStore.applyStepAction(taskID: task.id, action: .update(stepID: stepID, newText: text)) {
                return .failure(error)
            }
            return .success("Step updated. \(await Self.renderedStep(taskID: task.id, stepID: stepID, context: context))")

        case "set_status":
            guard let stepID = Self.stepID(from: arguments) else {
                return .failure("`set_status` requires `step_id` (a UUID from `list`).")
            }
            guard case .string(let statusRaw) = arguments["status"], let status = Self.stepStatus(from: statusRaw) else {
                return .failure("`set_status` requires `status`: pending | in_progress | completed | skipped. To remove a step, use the `delete` action.")
            }
            var note: String?
            if case .string(let n) = arguments["note"], !n.trimmingCharacters(in: .whitespaces).isEmpty {
                note = n
            }
            if let error = await context.taskStore.applyStepAction(taskID: task.id, action: .setStatus(stepID: stepID, status: status, note: note)) {
                return .failure(error)
            }
            return .success("Step status set to \(statusRaw). \(await Self.renderedStep(taskID: task.id, stepID: stepID, context: context))")

        case "delete":
            guard let stepID = Self.stepID(from: arguments) else {
                return .failure("`delete` requires `step_id` (a UUID from `list`).")
            }
            guard case .string(let note) = arguments["note"], !note.trimmingCharacters(in: .whitespaces).isEmpty else {
                return .failure("`delete` requires a `note` explaining why — validators read it, and the step stays on the record as a tombstone.")
            }
            if let error = await context.taskStore.applyStepAction(taskID: task.id, action: .delete(stepID: stepID, note: note)) {
                return .failure(error)
            }
            // Keeps the full list, unlike the other point mutations. Deleting is a tombstone, and
            // the list rendering is where the tombstone accounting appears ("N removed step(s)
            // remain on the record for validators") — that count IS the useful part of the answer,
            // and delete is not the parallel-issued action the point-report change was aimed at.
            return .success("Step deleted (tombstoned).\n\n\(await Self.renderedStepList(taskID: task.id, context: context))")

        case "purge":
            // Worker-proof by construction: Brown reaches this switch with `author == .worker`,
            // and the honest-record contract it works under is exactly what purge bypasses.
            guard context.agentRole == .smith else {
                return .failure("`purge` is not available to you — it hard-deletes a step with no record. Use `delete` to remove a step from your active list; the tombstone and your note stay on the record for validators.")
            }
            guard let stepID = Self.stepID(from: arguments) else {
                return .failure("`purge` requires `step_id` (a UUID from `list`).")
            }
            if let error = await context.taskStore.applyStepAction(taskID: task.id, action: .purge(stepID: stepID)) {
                return .failure(error)
            }
            return .success("Step purged (hard-deleted, no record kept).\n\n\(await Self.renderedStepList(taskID: task.id, context: context))")

        case "move":
            guard let stepID = Self.stepID(from: arguments) else {
                return .failure("`move` requires `step_id` (a UUID from `list`).")
            }
            switch Self.destination(from: arguments) {
            case .failure(let message):
                return .failure(message)
            case .success(let destination):
                if let error = await context.taskStore.applyStepAction(taskID: task.id, action: .move(stepID: stepID, destination: destination)) {
                    return .failure(error)
                }
                return .success("Step moved.\n\n\(await Self.renderedStepList(taskID: task.id, context: context))")
            }

        case "reorder":
            guard case .array(let raw) = arguments["step_ids"] else {
                return .failure("`reorder` requires `step_ids`: an array of every active step's UUID, in the new order.")
            }
            let ids = raw.compactMap { item -> UUID? in
                if case .string(let s) = item { return UUID(uuidString: s) }
                return nil
            }
            guard ids.count == raw.count else {
                return .failure("`reorder` `step_ids` must all be valid UUIDs. Call `list` to see the current ids.")
            }
            if let error = await context.taskStore.applyStepAction(taskID: task.id, action: .reorder(orderedActiveIDs: ids)) {
                return .failure(error)
            }
            return .success("Steps reordered.\n\n\(await Self.renderedStepList(taskID: task.id, context: context))")

        default:
            return .failure("Unknown action '\(action)'. Use add | update | set_status | delete | move | reorder | list\(context.agentRole == .smith ? " | purge" : "").")
        }
    }

    // MARK: - Private

    private static func stepID(from arguments: [String: AnyCodable]) -> UUID? {
        guard case .string(let raw) = arguments["step_id"] else { return nil }
        return UUID(uuidString: raw)
    }

    private enum DestinationParse {
        case success(TaskStepDestination)
        case failure(String)
    }

    /// Parses `move`'s destination. Exactly one of the three forms must be supplied — accepting
    /// two would make the call's meaning depend on an argument precedence the model can't see.
    private static func destination(from arguments: [String: AnyCodable]) -> DestinationParse {
        var found: [TaskStepDestination] = []
        var malformed: [String] = []
        if case .string(let raw) = arguments["before_step_id"] {
            if let anchorID = UUID(uuidString: raw) {
                found.append(.before(stepID: anchorID))
            } else {
                malformed.append("`before_step_id` must be a step UUID from `list` (got \"\(raw)\").")
            }
        }
        if case .string(let raw) = arguments["after_step_id"] {
            if let anchorID = UUID(uuidString: raw) {
                found.append(.after(stepID: anchorID))
            } else {
                malformed.append("`after_step_id` must be a step UUID from `list` (got \"\(raw)\").")
            }
        }
        if let position = arguments["position"] {
            switch position {
            case .int(let value): found.append(.position(value))
            case .double(let value): found.append(.position(Int(value)))
            case .string(let raw):
                if let value = Int(raw) {
                    found.append(.position(value))
                } else {
                    malformed.append("`position` must be a whole number (got \"\(raw)\").")
                }
            default: malformed.append("`position` must be a whole number.")
            }
        }
        if let problem = malformed.first { return .failure(problem) }
        switch found.count {
        case 1: return .success(found[0])
        case 0: return .failure("`move` requires exactly one destination: `before_step_id`, `after_step_id`, or `position`.")
        default: return .failure("`move` takes exactly one destination — you supplied \(found.count). Pick one of `before_step_id`, `after_step_id`, or `position`.")
        }
    }

    /// The tool-facing status vocabulary is snake_case; `TaskStep.Status` raw values are
    /// camelCase (persistence format). Mapped explicitly so neither can drift silently.
    /// `removed` is intentionally absent — tombstoning goes through the `delete` action.
    private static func stepStatus(from raw: String) -> TaskStep.Status? {
        switch raw {
        case "pending": return .pending
        case "in_progress": return .inProgress
        case "completed": return .completed
        case "skipped": return .skipped
        default: return nil
        }
    }

    /// The worker's view: numbered active steps with ids and statuses, via the shared renderer
    /// so the numbering matches the briefing, `get_task_details`, and the validator's punch list.
    /// Tombstoned (removed) steps are counted but not numbered — they're gone from the active
    /// plan, though validators still see them in full.
    /// Renders ONLY the step a point mutation touched.
    ///
    /// These actions can run in parallel — a worker marking four steps complete in one turn issues
    /// four concurrent calls — and each used to answer with a full re-render of the whole list,
    /// read separately after its own mutation. The transcript then shows those snapshots in CALL
    /// order while they were captured in COMPLETION order, so the last listing a worker reads is
    /// usually the oldest one. Observed 2026-07-27: a worker read the stale tail, concluded "the
    /// step statuses got messed up due to the parallel calls", and redid work that was already
    /// done. The underlying state had been correct throughout.
    ///
    /// A call that changes one step therefore reports one step. Callers wanting the whole picture
    /// have `list`, which is a single call whose answer is about the list by definition.
    private static func renderedStep(taskID: UUID, stepID: UUID, context: ToolContext) async -> String {
        guard let task = await context.taskStore.taskOrLibraryTemplate(id: taskID),
              let step = task.steps.first(where: { $0.id == stepID }) else {
            return "(step \(stepID) not found)"
        }
        let note = step.note.map { " — \($0)" } ?? ""
        return "[\(step.status.rawValue)] \(step.text) (id: \(step.id))\(note)"
    }

    private static func renderedStepList(taskID: UUID, context: ToolContext) async -> String {
        guard let task = await context.taskStore.taskOrLibraryTemplate(id: taskID) else { return "(task not found)" }
        guard let rendered = task.renderedSteps(includeIDs: true) else { return "Step list is empty." }
        return "Current steps:\n\(rendered)"
    }
}
