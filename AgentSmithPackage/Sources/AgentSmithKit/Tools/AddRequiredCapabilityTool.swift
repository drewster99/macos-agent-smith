import Foundation

/// Lets Smith record a need a task's worker turned out to have.
///
/// This is how Smith responds when a worker cannot do something its task needs — never by granting
/// a tool (decided 2026-10-05, user). The capability is added to the task's required capabilities,
/// marked as a later addition with Smith's reason, and a worker running the task has its tools
/// re-scoped by the Security Agent against the updated list at its next turn
/// (`TaskStoreEvent.requiredCapabilitiesChanged`). Whether a tool is then granted stays the
/// Security Agent's decision, within the user's tool policy.
struct AddRequiredCapabilityTool: AgentTool {
    let name = "add_required_capability"
    let toolDescription = """
        Add a capability a task's worker needs to its required capabilities — what the worker must \
        be able to DO, never a tool name ("Read the user's calendar", not "mcp__calendar__list"). \
        Use this when a worker reports it cannot do something the task needs, or when you realize \
        the task as written left a need out. The addition is marked as added later, with your \
        reason, wherever the task is shown. If a worker is running the task, the Security Agent \
        re-scopes its tools against the updated list before its next turn; whether a tool is granted \
        is the Security Agent's decision, and a tool the user has set to Never stays unavailable. \
        If the worker is waiting on your help, answer it with `provide_help` afterwards. Works on \
        any task that is not completed, including templates and running tasks.
        """

    let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "task_id": .dictionary([
                "type": .string("string"),
                "description": .string("UUID of the task.")
            ]),
            "capability": .dictionary([
                "type": .string("string"),
                "description": .string("What the worker must be able to do, as an ability. One capability per call.")
            ]),
            "reason": .dictionary([
                "type": .string("string"),
                "description": .string("Why it is needed now — e.g. what the worker reported it could not do.")
            ])
        ]),
        "required": .array([.string("task_id"), .string("capability"), .string("reason")])
    ]

    init() {}

    func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .smith
    }

    func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard case .string(let taskIDString) = arguments["task_id"] else {
            throw ToolCallError.missingRequiredArgument("task_id")
        }
        guard let taskID = UUID(uuidString: taskIDString) else {
            return .failure("Invalid task ID format: \(taskIDString)")
        }
        guard case .string(let capability) = arguments["capability"],
              !capability.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure("'capability' is required and must not be empty.")
        }
        guard case .string(let reason) = arguments["reason"],
              !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure("'reason' is required and must not be empty: say why the worker needs this.")
        }

        switch await context.taskStore.addRequiredCapability(id: taskID, text: capability, addedBy: .smith, reason: reason) {
        case .refused(let problem):
            return .failure(problem)
        case .alreadyListed(let existing):
            return .success("The task already lists this capability (\"\(existing.text)\"), so nothing was added and its worker's tools were not re-scoped. If the worker still cannot do it, the Security Agent did not grant a tool for it, or the user's tool policy forbids one — tell the user.")
        case .added(let added):
            if await context.workerIDForTask(taskID) != nil {
                return .success("Added \"\(added.text)\" to the task's required capabilities. The Security Agent re-scopes the running worker's tools against the updated list before its next turn.")
            }
            return .success("Added \"\(added.text)\" to the task's required capabilities. No worker is running it; the next one is scoped against the updated list.")
        }
    }
}
