import Foundation

/// Smith tool: sends a private message to Agent Brown.
/// Replaces send_message(recipient_id: "brown") for Smith's tool set.
struct MessageBrownTool: AgentTool {
    /// Smith parks after messaging a worker so it waits for the worker's reply.
    public var successEffects: Set<ToolEffect> { [.deliveredMessage] }

    let name = "message_brown"
    let toolDescription = """
        Send a message to the worker running a specific task. Use for task instructions, corrections, and follow-ups. \
        `task_id` identifies WHICH worker to address — several tasks can be running at once, each with its own \
        worker, and a message goes only to the worker running the task you name. \
        Be specific and unambiguous — Brown is literal and may misinterpret vague instructions. \
        Optionally forward attachments via `attachment_ids` (UUID strings from `[filename](file://…) … id=<UUID>` markdown links).
        """

    let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "task_id": .dictionary([
                "type": .string("string"),
                "description": .string("UUID of the running task whose worker should receive this message.")
            ]),
            "message": .dictionary([
                "type": .string("string"),
                "description": .string("The message to send to Brown.")
            ]),
            "attachment_ids": .dictionary([
                "type": .string("array"),
                "items": .dictionary(["type": .string("string")]),
                "description": .string("Optional UUID strings of existing attachments to forward to Brown with this message. Use the EXACT id values from the `[filename](file://…) … id=<UUID>` markdown links in your context.")
            ])
        ]),
        "required": .array([.string("task_id"), .string("message")])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        // Deliberately NOT gated on a worker being alive. Gating that way was considered and
        // rejected: `create_task` and `run_task` both return before the worker is spawned, so the
        // tool would vanish from Smith's toolset at exactly the moment Smith most expects to use
        // it, for a race Smith cannot observe. A message to a task with no live worker is queued
        // instead (see `execute`), so the call always has a meaningful outcome.
        context.agentRole == .smith && !context.hasAwaitingReviewTasks
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        // Defense-in-depth: reject while a Brown is blocked on a help request (`.awaitingHelp`), even
        // if the tool was presented from a stale definition cache — that blocker's resolution is
        // `provide_help`, not message_brown. A user-owned `.awaitingReview` park has no live Brown and
        // must NOT gate messaging of unrelated running workers.
        let activeTasks = await context.taskStore.allTasks().filter { $0.disposition == .active }
        if activeTasks.contains(where: { $0.status == .awaitingHelp }) {
            return .failure("Cannot message Brown while a task is awaiting your help — resolve it with `provide_help` first.")
        }

        guard case .string(let message) = arguments["message"] else {
            throw ToolCallError.missingRequiredArgument("message")
        }

        // Resolve the recipient BEFORE touching attachments. `resolveAttachments` is not a
        // pure lookup — its `attachment_paths` branch ingests files from disk and persists
        // them into the session's attachment store — so validating the addressing first
        // keeps a bad `task_id` from leaving orphaned attachments behind for a message that
        // was never sent.
        guard case .string(let taskIDString) = arguments["task_id"] else {
            throw ToolCallError.missingRequiredArgument("task_id")
        }
        guard let taskID = UUID(uuidString: taskIDString) else {
            return .failure("`task_id` is not a valid UUID: \(taskIDString)")
        }
        guard let recipientTask = await context.taskStore.task(id: taskID) else {
            return .failure("No active task with id \(taskIDString). Call `list_tasks` to see the current tasks.")
        }

        // Address the worker running THIS task. Resolving by role instead would return the
        // oldest live worker, so with several tasks running a message meant for one worker
        // would land in another's context — cross-task contamination by direct message.
        let liveWorkerID = await context.workerIDForTask(taskID)

        let resolution = await TaskUpdateTool.resolveAttachments(arguments: arguments, context: context)
        if let failureMessage = resolution.failure {
            return .failure(failureMessage)
        }
        let attachments = resolution.attachments

        let attachmentSuffix: String
        if attachments.isEmpty {
            attachmentSuffix = ""
        } else {
            let names = attachments.map { $0.filename }.joined(separator: ", ")
            attachmentSuffix = " with \(attachments.count) attachment(s): \(names)"
        }

        // No live worker means the message is early, not wrong — `create_task` and `run_task`
        // return before the worker is spawned. Queue it on the task; the worker's briefing hands
        // it over when it starts. Same durability contract as `amend_task`, and the same explicit
        // reporting of WHICH happened, so Smith is never guessing whether it landed.
        guard let brownID = liveWorkerID else {
            let queued = await context.taskStore.enqueueWorkerMessage(
                taskID: taskID,
                message: QueuedWorkerMessage(text: message, attachments: attachments)
            )
            guard queued else {
                return .failure("Could not queue the message for task \(taskIDString) — the task no longer exists.")
            }
            return .success("No worker is running \"\(recipientTask.title)\" yet (status: \(recipientTask.status.rawValue)), so the message was QUEUED\(attachmentSuffix). It will be delivered in the worker's briefing when the task starts. Do not resend it.")
        }

        // Label the recipient with its task so the UI shows WHICH worker was addressed.
        await context.post(ChannelMessage(
            sender: .agent(context.agentRole),
            recipientID: brownID,
            recipient: .agent(.brown),
            content: message,
            attachments: attachments,
            metadata: [
                "messageKind": .kind(.orchestratorMessage),
                "recipientTaskTitle": .string(recipientTask.title)
            ]
        ))

        return .success("Message sent to the worker on \"\(recipientTask.title)\"\(attachmentSuffix).")
    }
}
