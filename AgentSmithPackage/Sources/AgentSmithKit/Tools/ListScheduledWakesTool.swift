import Foundation

/// Smith tool: lists all currently-scheduled wakes (id, time, instructions, task association).
/// Use before scheduling a new timer to check for duplicates and resolve conflicts.
struct ListScheduledWakesTool: AgentTool {
    let name = "list_scheduled_wakes"
    let toolDescription = """
        List every scheduled timer currently registered (id, fire time, instructions, optional \
        task_id, recurrence). Call this before `schedule_task_action` (or `create_task` with a \
        `scheduled_run_at`) to check for duplicates, or to find an existing timer's id when the \
        user asks to cancel or change one. Read-only.
        """

    let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([:]),
        "required": .array([])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .smith
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        let wakes = await context.listScheduledWakes()
        guard !wakes.isEmpty else {
            return .success("No wakes currently scheduled.")
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let lines = wakes.map { wake -> String in
            let taskFragment = wake.taskID.map { " task=\($0.uuidString)" } ?? ""
            let recurFragment = wake.recurrence.map { " recurrence=\($0.displayDescription)" } ?? ""
            return "  • id=\(wake.id.uuidString) at=\(formatter.string(from: wake.wakeAt))\(taskFragment)\(recurFragment) instructions=\"\(wake.instructions)\""
        }
        return .success("Scheduled timers (\(wakes.count)):\n\(lines.joined(separator: "\n"))")
    }
}
