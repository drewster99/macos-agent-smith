import Foundation

/// The built-in subscriber that tells a coordinator's worker how a child task it created turned
/// out — the counterpart of `SmithTaskBriefing` for tasks a worker created (decided 2026-10-05,
/// user: "coordinator only"). Recorded as a durable effect in the same write as the child's status
/// (`TaskEffect.coordinatorBriefing`) while the coordinator is active; the runtime hands it to the
/// coordinator's live worker, which wakes it from `wait_for_child_tasks`, or queues it for the
/// coordinator's next worker.
public enum CoordinatorTaskBriefing {

    /// The longest result excerpt a note carries; the rest is one `get_task_details` call away.
    static let resultExcerptLimit = 4_000

    /// The note for the coordinator, or nil when this transition is not an outcome it waits on.
    /// Outcomes are the transitions INTO completed, failed, and awaiting review — the points where
    /// the child stops working. A start is not one: waking a waiting coordinator to say "started"
    /// buys nothing.
    public static func note(for transition: TaskStatusTransition, task: AgentTask) -> String? {
        let subject = "Child task \"\(task.title)\" (ID: \(task.id.uuidString))"
        let tail = "Call `wait_for_child_tasks` again if you are still waiting on other child tasks."
        switch transition.to {
        case .completed:
            return """
                [System: \(subject) COMPLETED.\(resultSection(task)) \
                Use `get_task_details` with its ID for its full result and deliverables. \(tail)]
                """
        case .failed:
            return """
                [System: \(subject) FAILED.\(resultSection(task)) \
                Its updates (`get_task_details`) say why. Decide whether your own task can still \
                succeed: create a different child task, do the work yourself, or report the blocker \
                with `request_help`. \(tail)]
                """
        case .awaitingReview:
            return """
                [System: \(subject) stopped working and is waiting for review by the user (its result \
                needs their sign-off, or a validator could not judge it). Nothing is needed from you; \
                you are told again when it completes or fails. \(tail)]
                """
        case .pending, .starting, .running, .paused, .awaitingHelp, .interrupted, .scheduled, .validating:
            return nil
        }
    }

    /// Whether Smith's own note about this transition is replaced by the coordinator's. Only the
    /// routine ones are: the start, and how the work ended. A sign-off park and its resolution stay
    /// with Smith, because they wait on the user and Smith is the one who talks to the user.
    public static func replacesSmithBriefing(_ cause: TaskTransitionCause) -> Bool {
        switch cause {
        case .workerStarted, .spawnFailed, .validationPassed, .validationFailedNoProgress:
            return true
        default:
            // Fails toward Smith: a cause added later keeps its Smith note until someone decides
            // the coordinator should own it.
            return false
        }
    }

    private static func resultSection(_ task: AgentTask) -> String {
        guard let result = task.result?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty else {
            return ""
        }
        guard result.count > resultExcerptLimit else { return "\n\nResult:\n\(result)\n" }
        return "\n\nResult (first \(resultExcerptLimit) of \(result.count) characters):\n\(result.prefix(resultExcerptLimit))\n"
    }
}
