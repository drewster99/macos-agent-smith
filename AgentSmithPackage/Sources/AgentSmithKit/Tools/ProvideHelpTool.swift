import Foundation

/// Smith tool: answers a help request Brown raised via `request_help`.
///
/// The counterpart to `request_help` (as `review_work` is to `task_complete`). It clears the
/// task's help flag, returns it to `running`, and delivers Smith's answer to Brown — waking it
/// to continue with the new information. Only valid for a task that is actually a help request;
/// completed-work submissions go through `review_work` instead.
struct ProvideHelpTool: AgentTool {
    let name = "provide_help"
    let toolDescription = """
        Answer a help request Brown raised via `request_help`. Provide everything Brown needs to \
        continue in `response` — the missing information, the decision, the clarification. This \
        returns the task to running and delivers your answer to Brown. If you still need \
        something from the user first, call `message_user` to ask, and only call `provide_help` \
        once you have the answer. (For reviewing completed work, use `review_work` instead.)
        """

    let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "task_id": .dictionary([
                "type": .string("string"),
                "description": .string("The UUID of the task Brown requested help on.")
            ]),
            "response": .dictionary([
                "type": .string("string"),
                "description": .string("Your answer to Brown's blocker — the information, decision, or clarification needed to proceed. Be specific and complete.")
            ])
        ]),
        "required": .array([.string("task_id"), .string("response")])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .smith && context.hasAwaitingReviewTasks
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard case .string(let taskIDString) = arguments["task_id"] else {
            throw ToolCallError.missingRequiredArgument("task_id")
        }
        guard let taskID = UUID(uuidString: taskIDString) else {
            return .failure("Invalid task ID format: \(taskIDString)")
        }
        guard case .string(let response) = arguments["response"] else {
            throw ToolCallError.missingRequiredArgument("response")
        }
        let trimmedResponse = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedResponse.isEmpty else {
            return .failure("Error: `response` must not be empty. Provide the information Brown needs to proceed.")
        }

        guard let task = await context.taskStore.task(id: taskID) else {
            return .failure("Task not found: \(taskIDString)")
        }
        guard task.helpRequest != nil else {
            return .failure("""
                Task '\(task.title)' is not a help request. `provide_help` only answers a blocker \
                Brown raised via `request_help`. For completed work in awaitingReview, use `review_work`.
                """)
        }

        await context.taskStore.clearHelpRequest(id: taskID)
        await context.taskStore.updateStatus(id: taskID, status: .running)

        // Find an existing Brown, or auto-spawn one (e.g. after app restart while parked).
        var brownID: UUID?
        var brownWasSpawned = false
        for agentID in task.assigneeIDs {
            if let role = await context.agentRoleForID(agentID), role == .brown {
                brownID = agentID
                break
            }
        }
        if brownID == nil, let newBrownID = await context.spawnBrown() {
            await context.taskStore.assignAgent(taskID: taskID, agentID: newBrownID)
            brownID = newBrownID
            brownWasSpawned = true
        }

        guard let brownID else {
            return .failure("Task returned to running, but failed to spawn a Brown agent. Check provider configuration.")
        }

        let content: String
        if brownWasSpawned {
            // New Brown has no prior conversation — give it full context plus the answer.
            var parts: [String] = []
            let currentTask = await context.taskStore.task(id: taskID) ?? task
            parts.append("## Task: \(currentTask.title)\n\n\(currentTask.description)")
            if !currentTask.updates.isEmpty {
                let history = currentTask.updates.map { "- \($0.message)" }.joined(separator: "\n")
                parts.append("## Prior Progress\n\(history)")
            }
            parts.append("## Help you requested\n\(trimmedResponse)")
            content = parts.joined(separator: "\n\n")
        } else {
            content = "Response to your help request on task '\(task.title)':\n\n\(trimmedResponse)"
        }

        await context.post(ChannelMessage(
            sender: .agent(context.agentRole),
            recipientID: brownID,
            recipient: .agent(.brown),
            content: content,
            metadata: [
                "messageKind": .string("help_provided"),
                "taskTitle": .string(task.title)
            ]
        ))

        return .success(brownWasSpawned
            ? "Help delivered. A new Brown was spawned, briefed with the full task context and your answer, and is back at work."
            : "Help delivered to Brown. The task is back to running.")
    }
}
