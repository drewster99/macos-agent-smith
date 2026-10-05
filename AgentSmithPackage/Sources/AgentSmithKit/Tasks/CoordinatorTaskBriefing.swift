import Foundation

extension AgentTask {
    /// The order child tasks are listed in everywhere: oldest first, ties broken by id so two
    /// children created in the same instant list identically in the store, tools and Task Detail.
    public static func coordinationOrder(_ lhs: AgentTask, _ rhs: AgentTask) -> Bool {
        (lhs.createdAt, lhs.id.uuidString) < (rhs.createdAt, rhs.id.uuidString)
    }
}

/// The built-in subscriber that tells a coordinator's worker how a child task it created turned
/// out — the counterpart of `SmithTaskBriefing` for tasks a worker created (decided 2026-10-05,
/// user: "coordinator only"). Recorded as a durable effect in the same write as the child's status
/// (`TaskEffect.coordinatorBriefing`) while the coordinator is active; the runtime hands it to the
/// coordinator's live worker, which wakes it from `wait_for_child_tasks`, or queues it for the
/// coordinator's next worker.
public enum CoordinatorTaskBriefing {

    /// The longest result excerpt a note carries; the rest is one `get_task_details` call away.
    static let resultExcerptLimit = 4_000

    /// The note for the coordinator, or nil when this transition is not one it must react to:
    /// the transitions INTO completed, failed and awaiting review (the child stopped working), and
    /// into paused or interrupted when nobody will resume it on its own (`stallDescription`). A start
    /// is not one: waking a waiting coordinator to say "started" buys nothing.
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
        case .paused, .interrupted:
            guard let how = stallDescription(transition.cause) else { return nil }
            return """
                [System: \(subject) was \(how). It does not continue unless the user or Smith resumes \
                it. Decide whether your task can still succeed without it: wait for it if you expect \
                it to be resumed, do the work yourself, create a different child task, or report the \
                blocker with `request_help`. \(tail)]
                """
        case .pending, .starting, .running, .awaitingHelp, .scheduled, .validating:
            return nil
        }
    }

    /// How a child came to stop, for a stop the coordinator must react to; nil for one that resumes
    /// on its own or takes the coordinator's worker down with it. Exhaustive on purpose: a new cause
    /// must be placed, not defaulted.
    private static func stallDescription(_ cause: TaskTransitionCause) -> String? {
        switch cause {
        case .userPaused: return "PAUSED by the user"
        case .userStopped: return "STOPPED by the user"
        case .scheduledAction(.pause): return "PAUSED by a scheduled action"
        case .scheduledAction(.interrupt): return "STOPPED by a scheduled action"
        case .smithSetStatus: return "stopped by Smith"
        case .smithTerminatedWorker: return "stopped — Smith ended its worker"
        case .workerSelfTerminated: return "INTERRUPTED — its worker ended itself"
        case .orphanRecovered: return "INTERRUPTED — its worker was lost"
        // Resumes on its own (`capacityShed`), or every worker is going down with it.
        case .capacityShed, .sessionShutdown, .sessionDeletion, .coldBootRecovery:
            return nil
        // Never moves a task to paused or interrupted.
        case .scheduledAction(.run), .scheduledAction(.summarize), .startClaimed, .startAbandoned,
             .spawnFailed, .spawnFailedAtRuntimeStart, .workerStarted, .workerStartedAtRuntimeStart,
             .submittedForValidation, .validationPassed, .validationFailedNoProgress,
             .validationEscalated, .userAcceptanceRequested, .signOffContractChanged,
             .validationBlocked, .validationReleased, .rejectionsReturned, .helpRequested,
             .helpProvided, .userAccepted, .userAcceptanceGranted, .userFailed, .userRevalidated,
             .userSentBack, .scheduledTimeReached, .resetForRun, .reopenedForRun,
             .templateLauncherNormalized, .coldBootSpawnAbandoned, .coldBootRevalidate:
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

    /// The note for a coordinator whose UNFINISHED child left the active list: it will not continue,
    /// and no outcome is coming.
    public static func departureNote(_ departure: CoordinatorChildDeparture) -> String {
        let child = departure.child
        let how: String
        switch departure.departure {
        case .leftActive(.archived): how = "ARCHIVED"
        case .leftActive(.recentlyDeleted): how = "DELETED"
        case .leftActive(.active): how = "moved"
        case .permanentlyDeleted: how = "PERMANENTLY DELETED"
        }
        return """
            [System: Child task "\(child.title)" (ID: \(child.id.uuidString)) was \(how) while it was \
            \(child.status.displayName.lowercased()), before it finished. It will not continue and no \
            outcome is coming. Decide whether your task can still succeed without it: do the work \
            yourself, create a different child task, or report the blocker with `request_help`. \
            Call `wait_for_child_tasks` again if you are still waiting on other child tasks.]
            """
    }

    /// Where a child's outcome goes NOW, for `get_task_details`: to its coordinator's worker while
    /// the coordinating task is open (`AgentTask.isCoordinatingChildren`), else to Smith as for any
    /// task. `coordinator` is nil when the coordinating task no longer exists.
    public static func routingDescription(coordinator: AgentTask?) -> String {
        guard let coordinator else {
            return "its coordinating task no longer exists, so it is an ordinary task and its outcome goes to Smith"
        }
        if coordinator.isCoordinatingChildren {
            return "while that task is open, its outcome is reported to that task's worker, not to Smith"
        }
        let state = coordinator.disposition == .active
            ? coordinator.status.displayName.lowercased()
            : (coordinator.disposition == .archived ? "archived" : "deleted")
        return "its coordinating task is closed (\(state)), so it is an ordinary task now and its outcome goes to Smith"
    }

    private static func resultSection(_ task: AgentTask) -> String {
        guard let result = task.result?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty else {
            return ""
        }
        guard result.count > resultExcerptLimit else { return "\n\nResult:\n\(result)\n" }
        return "\n\nResult (first \(resultExcerptLimit) of \(result.count) characters):\n\(result.prefix(resultExcerptLimit))\n"
    }
}
