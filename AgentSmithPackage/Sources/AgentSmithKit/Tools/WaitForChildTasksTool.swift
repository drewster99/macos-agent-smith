import Foundation

/// Parks a coordinating worker until one of its child tasks reaches an outcome (completed, failed,
/// waiting for review) or stalls (paused or stopped). The worker stays alive with its whole
/// conversation and its task stays running — no new status (user decision 2026-10-05: "keeping it
/// alive and NOT explicitly waiting"). While parked it takes no turns and gets no nudges; a note
/// about one of its children (`KnownNotificationType.coordinatorBriefing`, drained from its broker
/// queue) or any message handed to it wakes it.
///
/// Parking is the tool's declared effect (`ToolEffect.waitsForChildTasks`), so it happens only on
/// success. With no child that can still finish on its own (`ChildTaskProgress.isWaitable`), the
/// call fails and says where each child stands — a worker must never park waiting for an outcome
/// that already happened, or on a child that won't move.
struct WaitForChildTasksTool: AgentTool {
    let name = "wait_for_child_tasks"
    var successEffects: Set<ToolEffect> { [.waitsForChildTasks] }
    let toolDescription = """
        Wait for your child tasks (created with `create_child_task`). You pause — no turns, no \
        tool calls — until a child completes, fails, stops to wait for review, or is paused or \
        stopped; then you are woken with what happened. Call it again to keep waiting on the \
        others. Use it only when you have nothing else to do until a child finishes. If no child \
        can still finish on its own (all finished, or the rest paused, stopped or archived), it \
        does not wait and tells you where each one stands.
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
        guard let resumingIDs = await context.automaticallyResumingChildTaskIDs() else {
            return .failure("Cannot wait: the runtime that starts child tasks is unavailable.")
        }
        let progress = children.map { ($0, $0.progressAsChildTask(resumesAutomatically: resumingIDs.contains($0.id))) }
        let summary = Self.summary(of: progress)
        if progress.contains(where: { $0.1.isWaitable }) {
            return .success("Waiting for your child tasks. You will be woken with the next outcome.\n\(summary)")
        }
        if progress.allSatisfy({ $0.1 == .finished }) {
            return .failure("Nothing to wait for — every child task has finished:\n\(summary)\nUse `get_task_details` for a child's full result.")
        }
        return .failure("Not waiting — none of your unfinished child tasks can finish unless the user or Smith acts on it:\n\(summary)\nDo that work yourself, create a different child task, or report the blocker with `request_help`.")
    }

    /// One line per child: title, id, status, where it lives when not in the active list.
    static func summary(of children: [AgentTask]) -> String {
        summary(of: children.map { ($0, nil) })
    }

    /// One line per child, with what its progress means for the coordinator when it is not simply
    /// finished or progressing.
    static func summary(of children: [(task: AgentTask, progress: ChildTaskProgress?)]) -> String {
        children.map { entry in
            let task = entry.task
            var line = "- \"\(task.title)\" (ID: \(task.id.uuidString)) — \(task.status.displayName)"
            switch task.disposition {
            case .active: break
            case .archived: line += ", archived"
            case .recentlyDeleted: line += ", deleted"
            }
            if let explanation = entry.progress?.explanation { line += " (\(explanation))" }
            return line
        }.joined(separator: "\n")
    }
}
