import Foundation

/// Brown tool: escalates a genuine blocker to Smith and waits for help.
///
/// The honest counterpart to `task_complete`. When Brown cannot proceed without information,
/// a decision, or access that only the user or Smith can provide — and has exhausted its own
/// tools — it calls this instead of submitting a non-result via `task_complete`. The task is
/// parked in `awaitingReview` (reusing the review wait/slot machinery) but flagged as a help
/// request, so Smith answers via `provide_help` rather than `review_work`. Mirrors the
/// `task_complete` → `review_work` round-trip exactly: submit, go idle, wake on Smith's reply.
public struct RequestHelpTool: AgentTool {
    public let name = "request_help"
    public let toolDescription = """
        Escalate a blocker to Smith when you genuinely cannot proceed without information, a \
        decision, or access that only the user or Smith can provide — and you have already \
        exhausted your own tools. Do NOT use `task_complete` to report a blocker; that tool is \
        only for finished work. After calling this, stop and wait for Smith's response, which \
        will arrive as a message and return the task to running.
        """

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "blocker": .dictionary([
                "type": .string("string"),
                "description": .string("What is blocking you — be specific about what you tried and why you cannot proceed.")
            ]),
            "needed": .dictionary([
                "type": .string("string"),
                "description": .string("Exactly what you need to continue, and from whom (e.g. a file or its contents, a credential, a decision, clarification).")
            ])
        ]),
        "required": .array([.string("blocker"), .string("needed")])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .brown
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard case .string(let blocker) = arguments["blocker"] else {
            throw ToolCallError.missingRequiredArgument("blocker")
        }
        guard case .string(let needed) = arguments["needed"] else {
            throw ToolCallError.missingRequiredArgument("needed")
        }
        let trimmedBlocker = blocker.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNeeded = needed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBlocker.isEmpty, !trimmedNeeded.isEmpty else {
            return .failure("Error: both `blocker` and `needed` must be non-empty. Describe what's blocking you and exactly what you need to continue.")
        }

        guard let task = await context.taskStore.taskForAgent(agentID: context.agentID) else {
            return .failure("No active task assigned to you.")
        }

        // Idempotency: a task already submitted (for review or help) isn't a fresh escalation.
        if task.status == .awaitingReview || task.status == .completed {
            return .success("Already submitted — waiting for Smith.")
        }

        let request = "Blocker: \(trimmedBlocker)\nNeeded: \(trimmedNeeded)"
        await context.taskStore.requestHelp(id: task.id, request: request)

        guard let smithID = await context.agentIDForRole(.smith) else {
            return .success("Help requested for task: \(task.title). Stop and wait for Smith's response.")
        }

        let message = """
            🆘 ACTION REQUIRED — Brown needs help to proceed on '\(task.title)'. This is NOT \
            completed work to review; Brown is blocked and waiting.

            \(request)

            Resolve it with `provide_help` (answer Brown and return the task to running). If you \
            need something from the user first, `message_user` to ask, then `provide_help` once \
            you have it. Do not call `review_work` on this task.
            """

        await context.post(ChannelMessage(
            sender: .agent(context.agentRole),
            recipientID: smithID,
            recipient: .agent(.smith),
            content: message,
            metadata: [
                "messageKind": .string("help_requested"),
                "taskTitle": .string(task.title)
            ]
        ))

        return .success("Help requested for task: \(task.title). Stop and wait for Smith's response.")
    }
}
