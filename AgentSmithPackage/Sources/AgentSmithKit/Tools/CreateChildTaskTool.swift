import Foundation

/// Lets a worker coordinate: create a task of its own — a CHILD — that another worker runs, then wait
/// for its outcome (`wait_for_child_tasks`). Decided 2026-10-05 (user): a worker must be able to
/// coordinate other tasks. The worker gets this tool only through its task's required capabilities
/// — the Security Agent scopes it like any other tool, within the user's tool policy.
///
/// The child records its coordinator (`AgentTask.coordinatorTaskID`). Its outcome goes to the
/// coordinator's worker rather than to Smith (`CoordinatorTaskBriefing`), and the runtime starts it
/// as soon as a worker slot is free — or above capacity when every live worker is a coordinator
/// waiting on its children, so the work always makes progress. The calling worker keeps running.
struct CreateChildTaskTool: AgentTool {
    let name = "create_child_task"
    let toolDescription = """
        Create a CHILD task: a separate task, run by another worker, whose outcome is reported back \
        to you. Use it when your task is to coordinate work that splits into independent pieces. \
        The child starts as soon as a worker slot is free; you keep running. When you have nothing \
        else to do until children finish, call `wait_for_child_tasks` — you are woken with each \
        child's outcome (its result when it completes, or that it failed). Each child is judged \
        against its own acceptance criteria, exactly like any task.

        The child's worker sees ONLY what you write here: write the description so it stands on its \
        own (goal, inputs, paths, constraints), list what it must be able to do in \
        `required_capabilities`, and say what done means in `acceptance_criteria`. There is a limit \
        on how many child tasks one task may create.
        """

    let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "title": .dictionary([
                "type": .string("string"),
                "description": .string("Short title for the child task.")
            ]),
            "description": .dictionary([
                "type": .string("string"),
                "description": .string("Everything the child's worker needs to do the work. It sees nothing of your task or conversation except what you write here.")
            ]),
            "required_capabilities": CreateTaskTool.requiredCapabilitiesSchema(callerNote: "You cannot add to this list once the child task exists, so include everything its worker will need. If that worker later lacks something, it asks Smith for help."),
            "acceptance_criteria": CreateTaskTool.acceptanceCriteriaSchema,
            "steps": CreateTaskTool.stepsSchema,
            "attachment_ids": .dictionary([
                "type": .string("array"),
                "items": .dictionary(["type": .string("string")]),
                "description": .string("UUIDs of attachments the child's worker needs (from `attach_file` results or attachments you were given). Forward the EXACT id values.")
            ])
        ]),
        "required": .array([.string("title"), .string("description")])
    ]

    init() {}

    func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .brown
    }

    func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard let coordinator = await context.taskStore.taskForAgent(agentID: context.agentID) else {
            return .failure("You are not running a task, so there is nothing to create a child task for.")
        }
        guard let childLimit = await context.maxChildTasksPerTask() else {
            return .failure("Child task NOT created — the orchestration runtime is unavailable.")
        }
        guard case .string(let rawTitle) = arguments["title"],
              !rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure("Child task NOT created — 'title' is required.")
        }
        guard case .string(let rawDescription) = arguments["description"],
              !rawDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure("Child task NOT created — 'description' is required.")
        }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = rawDescription.trimmingCharacters(in: .whitespacesAndNewlines)

        var attachments: [Attachment] = []
        switch ToolArguments.strictOptionalStringList(arguments, "attachment_ids") {
        case .absent:
            break
        case .malformed(let problem):
            return .failure("Child task NOT created — \(problem)")
        case .value(let attachmentIDs):
            let outcome = await context.resolveAttachments(attachmentIDs)
            guard outcome.rejected.isEmpty else {
                return .failure("Child task NOT created — unknown attachment_ids: \(outcome.rejected.joined(separator: ", ")).")
            }
            attachments = outcome.resolved
        }

        var criteria: [AcceptanceCriterion] = []
        if let rawCriteria = ToolArguments.optionalArray(arguments, "acceptance_criteria") {
            switch CriterionArgumentParsing.parse(rawCriteria) {
            case .success(let parsed):
                criteria = parsed.map {
                    AcceptanceCriterion(name: $0.name, validationPrompt: $0.validationPrompt, inputEnumeratorPrompt: $0.inputEnumeratorPrompt, waivable: $0.waivable, origin: .worker)
                }
            case .failure(let problem):
                return .failure("Child task NOT created — the acceptance_criteria are invalid: \(problem.message)")
            }
        }
        let steps: [TaskStep]
        switch TaskCreationSupport.stepTexts(from: arguments) {
        case .success(let texts): steps = texts.map { TaskStep(text: $0, origin: .worker) }
        case .failure(let problem): return .failure("Child task NOT created — \(problem.message)")
        }
        let capabilities: [RequiredCapability]
        switch TaskCreationSupport.requiredCapabilities(from: arguments, addedBy: .worker) {
        case .success(let read): capabilities = read
        case .failure(let problem): return .failure("Child task NOT created — \(problem.message)")
        }

        // Retrieved BEFORE the write, so the child lands with its context in the same write that
        // makes it startable (the drain may start it at once).
        let retrieved = await context.retrieveContext(.newTask, title + " " + description)
        let creation = await context.taskStore.addChildTask(
            coordinatorTaskID: coordinator.id,
            limit: childLimit,
            title: title,
            description: description,
            descriptionAttachments: attachments,
            acceptanceCriteria: criteria,
            steps: steps,
            requiredCapabilities: capabilities,
            relevantContext: TaskContextRetrieval.relevantContext(from: retrieved)
        )
        let child: AgentTask
        switch creation {
        case .created(let created):
            child = created
        case .limitReached(let limit):
            return .failure("Child task NOT created — this task has already created \(limit) child task(s), the limit set in Settings. Work with the children you have, or report the blocker with `request_help`.")
        case .duplicateOfUnfinishedChild(let existing):
            return .failure("Child task NOT created — your child task \"\(existing.title)\" (ID: \(existing.id.uuidString)) is still \(existing.status.displayName.lowercased()). Wait for it with `wait_for_child_tasks`, or give a genuinely different piece of work a distinct title.")
        case .coordinatorNotFound:
            return .failure("Child task NOT created — your task is no longer in the active task list.")
        }

        await TaskCreationSupport.announceCreated(
            taskID: child.id,
            title: title,
            description: description,
            scheduledRunAt: nil,
            context: context
        )
        await context.startChildTask(child.id)
        return .success("Child task created (ID: \(child.id.uuidString), title: \"\(title)\"). It starts as soon as a worker slot is free. Its outcome will be delivered to you; call `wait_for_child_tasks` when you have nothing else to do until then.")
    }
}
