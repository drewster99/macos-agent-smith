import Foundation

/// Parks a coordinating worker until one of its child tasks reaches an outcome (completed, failed,
/// or waiting for review). The worker stays alive with its whole conversation and its task stays
/// running — no new status (user decision 2026-10-05: "keeping it alive and NOT explicitly
/// waiting"). While parked it takes no turns and gets no nudges; the child's outcome
/// (`ChannelMessageKind.childTaskOutcome`) or any message handed to it wakes it.
///
/// Parking is the tool's declared effect (`ToolEffect.waitsForChildTasks`), so it happens only on
/// success. With nothing left to wait for, the call fails and says how each child ended — a worker
/// must never park waiting for an outcome that already happened.
struct WaitForChildTasksTool: AgentTool {
    let name = "wait_for_child_tasks"
    var successEffects: Set<ToolEffect> { [.waitsForChildTasks] }
    let toolDescription = """
        Wait for your child tasks (created with `create_child_task`). You pause — no turns, no \
        tool calls — until a child completes, fails, or stops to wait for review; then you are \
        woken with that child's outcome. Call it again to keep waiting on the others. Use it only \
        when you have nothing else to do until a child finishes. If every child has already \
        finished, it does not wait and tells you how each one ended.
        """

    let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([:]),
        "required": .array([])
    ]

    init() {}

    func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .brown
    }

    func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard let coordinator = await context.taskStore.taskForAgent(agentID: context.agentID) else {
            return .failure("You are not running a task, so you have no child tasks to wait for.")
        }
        let children = await context.taskStore.childTasks(ofCoordinator: coordinator.id)
        guard !children.isEmpty else {
            return .failure("You have created no child tasks, so there is nothing to wait for.")
        }
        let summary = Self.summary(of: children)
        guard children.contains(where: { !$0.status.isTerminal }) else {
            return .failure("Nothing to wait for — every child task has finished:\n\(summary)\nUse `get_task_details` for a child's full result.")
        }
        return .success("Waiting for your child tasks. You will be woken with the next outcome.\n\(summary)")
    }

    /// One line per child: title, id, status.
    static func summary(of children: [AgentTask]) -> String {
        children.map { "- \"\($0.title)\" (ID: \($0.id.uuidString)) — \($0.status.displayName)" }.joined(separator: "\n")
    }
}
