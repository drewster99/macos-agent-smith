import Foundation

/// Smith tool: reviews Brown's submitted work, either accepting or requesting changes.
/// Merges AcceptWorkTool and RequestChangesTool into a single decision point.
struct ReviewWorkTool: AgentTool {
    let name = "review_work"
    let toolDescription = """
        Review Brown's submitted work on a task (must be in awaitingReview status). \
        Set `accepted` to `true` to mark the task completed and terminate Brown + Jones. \
        Set `accepted` to `false` to return the task to running and send feedback to Brown. \
        `feedback` is required when `accepted` is `false`.
        
        To perform your review:
        1. Call `get_task_details` to see the current and latest task description, progress and details
        2. Carefully step through every requirement described in the task. For each requirement, review the work submitted by Agent Brown to determine if the requirement has been satisfied. If necessary, call `file_read` to validate the results. Be sure that each requirement is not only satisfied, but has been satisfied in the best most complete way possible.
        3. Compile a list of ALL potential deficiencies in the submitted work.
        4. Re-check the task details again and look for key points that could have been misinterpreted or easily missed. Double check those items are complete.
        5. If you have previously rejected submitted work, review your earlier rejection response. Anything you rejected previously must be resolved and any questions or concerns expressed in your earlier rejection must be addressed.
        5. If there are ANY identified deficiencies OR any unaddressed questions OR any concerns, then you MUST REJECT the work, by calling `review_work` with `accepted` = `false`. Include your complete and detailed feedback in the `feedback` field. The feedback must include ALL items identified in any of the steps above, including any outstanding issues from prior rejections you may have sent.
        """

    let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "task_id": .dictionary([
                "type": .string("string"),
                "description": .string("The UUID of the task to review.")
            ]),
            "accepted": .dictionary([
                "type": .string("boolean"),
                "description": .string(
                    "true = accept the work, complete the task, and terminate Brown. " +
                    "false = reject the work and return it to Brown for revision."
                )
            ]),
            "feedback": .dictionary([
                "type": .string("string"),
                "description": .string(
                    "Required when accepted is false. " +
                    "Be specific: explain exactly what is wrong and what needs to change."
                )
            ])
        ]),
        "required": .array([.string("task_id"), .string("accepted")])
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

        guard let accepted = resolveBool(arguments["accepted"]) else {
            throw ToolCallError.missingRequiredArgument("accepted")
        }

        guard let task = await context.taskStore.task(id: taskID) else {
            return .failure("Task not found: \(taskIDString)")
        }

        guard task.status == .awaitingReview else {
            return .failure("""
                Task '\(task.title)' is not awaiting review (current status: \(task.status.rawValue)). \
                `review_work` can only be called after Brown submits via `task_complete`.
                """)
        }

        // Defense-in-depth: a task in awaitingReview with no result is a malformed state
        // (Brown's task_complete is the only legal way in, and it sets result first).
        // If we ever land here, auto-reject so the user never sees a "Task Completed" banner
        // with no result content.
        let resultIsMissing = (task.result?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let effectiveAccepted = accepted && !resultIsMissing

        if accepted && resultIsMissing {
            return try await autoRejectMissingResult(taskID: taskID, task: task, context: context)
        }

        if effectiveAccepted {
            // ---- Accept path ----
            await context.taskStore.updateStatus(id: taskID, status: .completed)

            // Fetch the updated task to get completedAt/startedAt timestamps.
            let completedTask = await context.taskStore.task(id: taskID) ?? task

            for agentID in completedTask.assigneeIDs {
                _ = await context.terminateAgent(agentID, context.agentID)
            }

            // Post a structured completion banner for the channel log. Brown's result is
            // embedded in the banner itself (taskResult metadata) — it is NOT posted as a
            // separate Smith→user message.
            var bannerMetadata: [String: AnyCodable] = [
                "messageKind": .string("task_completed"),
                "taskID": .string(taskID.uuidString)
            ]
            if let startedAt = completedTask.startedAt, let completedAt = completedTask.completedAt {
                bannerMetadata["durationSeconds"] = .double(completedAt.timeIntervalSince(startedAt))
            }
            if let result = completedTask.result?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty {
                bannerMetadata["taskResult"] = .string(result)
            }
            await context.post(ChannelMessage(
                sender: .system,
                content: completedTask.title,
                metadata: bannerMetadata
            ))

            // Trigger background summarization and embedding of the completed task.
            await context.summarizeCompletedTask(taskID)

            return .success("Task '\(completedTask.title)' accepted and marked COMPLETE. Agents terminated. Result ALREADY delivered to user inside the Task Completed banner (do not deliver it again yourself, Agent Smith). **STOP** — your turn ends here. Do not call message_user, run_task, list_tasks, or any other tool. The system handles what happens next.")
        } else {
            // ---- Reject path ----
            let feedback: String
            if case .string(let f) = arguments["feedback"], !f.trimmingCharacters(in: .whitespaces).isEmpty {
                feedback = f
            } else {
                return .failure("`feedback` is required when `accepted` is `false`. Provide specific details about what needs to change.")
            }

            await context.taskStore.updateStatus(id: taskID, status: .running)
            await context.taskStore.clearResult(id: taskID)

            // Find an existing Brown, or auto-spawn one if needed (e.g. after app restart)
            var brownID: UUID?
            var brownWasSpawned = false
            for agentID in task.assigneeIDs {
                if let role = await context.agentRoleForID(agentID), role == .brown {
                    brownID = agentID
                    break
                }
            }

            if brownID == nil {
                if let newBrownID = await context.spawnBrown() {
                    await context.taskStore.assignAgent(taskID: taskID, agentID: newBrownID)
                    brownID = newBrownID
                    brownWasSpawned = true
                }
            }

            guard let brownID else {
                return .failure("Task returned to running, but failed to spawn a Brown agent. Check provider configuration.")
            }

            let content: String
            if brownWasSpawned {
                // New Brown needs full context — it has no prior conversation history
                var messageParts: [String] = []
                let currentTask = await context.taskStore.task(id: taskID) ?? task
                messageParts.append("## Task: \(currentTask.title)\n\n\(currentTask.description)")

                if !currentTask.updates.isEmpty {
                    let history = currentTask.updates.map { "- \($0.message)" }.joined(separator: "\n")
                    messageParts.append("## Prior Progress\n\(history)")
                }

                messageParts.append("## Changes Required\n\(feedback)")
                content = messageParts.joined(separator: "\n\n")
            } else {
                // Existing Brown already has context — just send the rejection feedback
                content = "Results rejected - changes required on task '\(task.title)': \(feedback)"
            }

            await context.post(ChannelMessage(
                sender: .agent(context.agentRole),
                recipientID: brownID,
                recipient: .agent(.brown),
                content: content,
                metadata: [
                    "messageKind": .string("changes_requested"),
                    "taskTitle": .string(task.title)
                ]
            ))

            return .success(brownWasSpawned
                ? "Changes requested. A new Brown has been spawned and briefed with the full task context and your feedback."
                : "Changes requested. Feedback sent to Brown.")
        }
    }

    // MARK: - Private

    /// Auto-rejection used when Smith calls `accepted: true` against a task that has no
    /// stored result. This should be unreachable under normal flow (only Brown's
    /// `task_complete` puts tasks into `awaitingReview`, and it always sets a non-empty
    /// result), but guards against ever silently posting a "Task Completed" banner with
    /// no body to the user.
    private func autoRejectMissingResult(taskID: UUID, task: AgentTask, context: ToolContext) async throws -> ToolExecutionResult {
        let feedback = "Auto-rejected by runtime: `review_work` was called with accepted=true but no result has been submitted on this task. The runtime will not deliver an empty result to the user. Continue your work and call `task_complete` with the FULL result before Smith reviews again."

        await context.taskStore.updateStatus(id: taskID, status: .running)
        await context.taskStore.clearResult(id: taskID)

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
            return .failure("Auto-rejected (no result was submitted), but failed to spawn a Brown agent to retry. Check provider configuration.")
        }

        let content: String
        if brownWasSpawned {
            var messageParts: [String] = []
            let currentTask = await context.taskStore.task(id: taskID) ?? task
            messageParts.append("## Task: \(currentTask.title)\n\n\(currentTask.description)")
            if !currentTask.updates.isEmpty {
                let history = currentTask.updates.map { "- \($0.message)" }.joined(separator: "\n")
                messageParts.append("## Prior Progress\n\(history)")
            }
            messageParts.append("## Changes Required\n\(feedback)")
            content = messageParts.joined(separator: "\n\n")
        } else {
            content = "Auto-rejection on task '\(task.title)': \(feedback)"
        }

        await context.post(ChannelMessage(
            sender: .agent(context.agentRole),
            recipientID: brownID,
            recipient: .agent(.brown),
            content: content,
            metadata: [
                "messageKind": .string("changes_requested"),
                "taskTitle": .string(task.title),
                "autoRejected": .bool(true)
            ]
        ))

        return .failure("Cannot accept '\(task.title)': no result has been submitted (task.result is empty). The task has been auto-returned to running and Brown has been notified. Wait for Brown to call `task_complete` with the full result, then review again.")
    }

    /// Resolves a boolean from AnyCodable, tolerating .bool, .int (0/1), and string "true"/"false".
    /// This makes the tool robust regardless of how the LLM serializes the boolean parameter.
    private func resolveBool(_ value: AnyCodable?) -> Bool? {
        guard let value else { return nil }
        switch value {
        case .bool(let b):
            return b
        case .int(let i):
            if i == 1 { return true }
            if i == 0 { return false }
            return nil
        case .string(let s):
            switch s.lowercased() {
            case "true", "yes", "1":  return true
            case "false", "no", "0": return false
            default: return nil
            }
        default:
            return nil
        }
    }
}
