import Foundation

/// Brown's step-list management: the worker-owned plan that acceptance validators read
/// alongside the result. Steps churn freely while work proceeds, but the record is
/// append-only underneath — skipping or removing a step requires a note, and removal is
/// a tombstone (hidden from the active list, permanently visible to validators).
public struct ManageStepsTool: AgentTool {
    public let name = "manage_steps"
    public let toolDescription = """
        Manage your task's step list — your working plan, visible to the user and to the \
        acceptance validators that judge your submission. Keep it current: add steps as you \
        discover work, mark them in_progress/completed as you go. \
        \
        Actions: `add` (one `text` or several `texts`), `update` (reword a step: `step_id` + \
        `text`), `set_status` (`step_id` + `status`; skipping or removing REQUIRES a `note` \
        explaining why — validators read these notes, and a removed step is a permanent \
        tombstone that cannot be edited again), and `list` (show the current list with ids). \
        \
        Honesty matters: validators see every skipped/removed step and its note. Quietly \
        dropping planned work is the fastest way to get your submission rejected.
        """

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "action": .dictionary([
                "type": .string("string"),
                "enum": .array([.string("add"), .string("update"), .string("set_status"), .string("list")]),
                "description": .string("The step-list operation to perform.")
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
                "description": .string("For `update`/`set_status`: the step's UUID (shown by `list` and in every response).")
            ]),
            "status": .dictionary([
                "type": .string("string"),
                "enum": .array([.string("pending"), .string("in_progress"), .string("completed"), .string("skipped"), .string("removed")]),
                "description": .string("For `set_status`: the new status. `skipped` and `removed` require `note`.")
            ]),
            "note": .dictionary([
                "type": .string("string"),
                "description": .string("Why a step was skipped or removed. Required for those statuses; validators read it.")
            ])
        ]),
        "required": .array([.string("action")])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .brown
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard let task = await context.taskStore.taskForAgent(agentID: context.agentID) else {
            return .failure("No active task assigned to you.")
        }
        guard case .string(let action) = arguments["action"] else {
            return .failure("Missing required argument 'action' (add | update | set_status | list).")
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
                if let error = await context.taskStore.applyStepAction(taskID: task.id, action: .add(text: text)) {
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
            return .success("Step updated.\n\n\(await Self.renderedStepList(taskID: task.id, context: context))")

        case "set_status":
            guard let stepID = Self.stepID(from: arguments) else {
                return .failure("`set_status` requires `step_id` (a UUID from `list`).")
            }
            guard case .string(let statusRaw) = arguments["status"], let status = Self.stepStatus(from: statusRaw) else {
                return .failure("`set_status` requires `status`: pending | in_progress | completed | skipped | removed.")
            }
            var note: String?
            if case .string(let n) = arguments["note"], !n.trimmingCharacters(in: .whitespaces).isEmpty {
                note = n
            }
            if let error = await context.taskStore.applyStepAction(taskID: task.id, action: .setStatus(stepID: stepID, status: status, note: note)) {
                return .failure(error)
            }
            return .success("Step status set to \(statusRaw).\n\n\(await Self.renderedStepList(taskID: task.id, context: context))")

        default:
            return .failure("Unknown action '\(action)'. Use add | update | set_status | list.")
        }
    }

    // MARK: - Private

    private static func stepID(from arguments: [String: AnyCodable]) -> UUID? {
        guard case .string(let raw) = arguments["step_id"] else { return nil }
        return UUID(uuidString: raw)
    }

    /// The tool-facing status vocabulary is snake_case; `TaskStep.Status` raw values are
    /// camelCase (persistence format). Mapped explicitly so neither can drift silently.
    private static func stepStatus(from raw: String) -> TaskStep.Status? {
        switch raw {
        case "pending": return .pending
        case "in_progress": return .inProgress
        case "completed": return .completed
        case "skipped": return .skipped
        case "removed": return .removed
        default: return nil
        }
    }

    /// The worker's view: active steps with ids and statuses. Tombstoned (removed) steps
    /// are counted but not listed — they're gone from the plan, though validators still
    /// see them in full.
    private static func renderedStepList(taskID: UUID, context: ToolContext) async -> String {
        guard let task = await context.taskStore.task(id: taskID) else { return "(task not found)" }
        let active = task.steps.filter(\.isActive)
        let removedCount = task.steps.count - active.count
        guard !active.isEmpty else {
            return removedCount > 0
                ? "Step list is empty (\(removedCount) removed step(s) remain on the record for validators)."
                : "Step list is empty."
        }
        var lines = active.map { step -> String in
            var line = "- [\(step.status.rawValue)] \(step.text) (id: \(step.id.uuidString))"
            if let note = step.note, !note.isEmpty { line += " — note: \(note)" }
            return line
        }
        if removedCount > 0 {
            lines.append("(\(removedCount) removed step(s) remain on the record for validators)")
        }
        return "Current steps:\n" + lines.joined(separator: "\n")
    }
}
