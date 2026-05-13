import Foundation

/// Brown tool: acknowledges receipt of the assigned task, transitioning it to running.
struct TaskAcknowledgedTool: AgentTool {
    let name = "task_acknowledged"
    let toolDescription = "Acknowledge your assigned task — call this EXACTLY ONCE when you begin working on the task."

    let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([:]),
        "required": .array([])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .brown
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard let task = await context.taskStore.taskForAgent(agentID: context.agentID) else {
            return .failure("No active task assigned to you.")
        }

        guard task.status.isRunnable || task.status == .running else {
            return .failure("Task '\(task.title)' cannot be acknowledged in its current state (\(task.status.rawValue)).")
        }

        // Bump the explicit ack counter and use its post-increment value to decide
        // whether this is a fresh ack (count == 1) or a continuation (count > 1).
        // This is reliable across respawns, rejections, and crash-recovery paths;
        // the previous `!task.updates.isEmpty` heuristic wrongly classified any
        // respawn where Brown never called `task_update` as a fresh ack.
        let newAckCount = await context.taskStore.incrementAcknowledgmentCount(id: task.id)
        let isContinuation = newAckCount > 1

        await context.taskStore.updateStatus(id: task.id, status: .running)

        // Notify Smith privately
        guard let smithID = await context.agentIDForRole(.smith) else {
            return .success("Task acknowledged: \(task.title)")
        }

        let content: String
        let messageKind: String
        if isContinuation {
            content = "Continuing task '\(task.title)' — working on revisions."
            messageKind = "task_continuing"
        } else {
            content = "Task '\(task.title)' acknowledged. Beginning work."
            messageKind = "task_acknowledged"
        }

        await context.post(ChannelMessage(
            sender: .agent(context.agentRole),
            recipientID: smithID,
            recipient: .agent(.smith),
            content: content,
            metadata: ["messageKind": .string(messageKind)]
        ))

        return .success(isContinuation
            ? "Task continuing: \(task.title)"
            : "Task acknowledged: \(task.title)")
    }
}
