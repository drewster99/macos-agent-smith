import Foundation

/// The built-in subscriber that tells Smith about a task's status change: maps a transition to the
/// note Smith receives, or to nothing. The ONE place those notes are composed; the store records
/// the note as a durable effect in the same write as the status (see `TaskEffectRecord`).
///
/// Covers exactly the transitions Smith was told about before this existed (decision 2026-09-24:
/// same set, same text). Widening the set is a separate decision. Notes about things that are NOT
/// status changes (a refused scheduled run, delete / undelete / retry / run again) and the user
/// actions posted as `.userTaskAction` rows stay where they are.
public enum SmithTaskBriefing {

    public static func note(for transition: TaskStatusTransition, task: AgentTask) -> String? {
        let subject = "Task \"\(task.title)\" (ID: \(task.id.uuidString))"
        switch transition.cause {
        case .workerStarted:
            return """
                [System: \(subject) has been started. A fresh worker \
                (Brown) was spawned and briefed automatically. Do NOT call `run_task`, `create_task`, or \
                `notify_brown` FOR THIS task — Brown will signal progress via task_update / task_complete, \
                and you'll get the periodic Brown-activity digest; do NOT poll. This start came from your own \
                run_task call, a scheduled timer, auto-advance, or the user's Play/Resume control; if it \
                resumes a task you were told was paused or stopped, it is in progress again. If the user \
                doesn't already know it started, tell them in one short line. Handle any NEW user message normally.]
                """
        case .spawnFailed:
            return """
                [System: \(subject) could not be started — the worker \
                failed to spawn (provider unreachable or tool-scoping failed; details were posted to the \
                channel). The task has been marked FAILED. Tell the user briefly what happened; saying \
                "retry" will re-run it via `run_task`, which auto-resets failed tasks.]
                """
        case .validationPassed(let validationWasRun):
            let completionNote = validationWasRun
                ? "passed acceptance validation and is COMPLETE"
                : "is COMPLETE — acceptance validation is disabled, so its criteria were NOT judged"
            return completionBriefing(subject: subject, completionNote: completionNote)
        case .userAccepted:
            return completionBriefing(
                subject: subject,
                completionNote: "is COMPLETE — the user accepted it from review after acceptance validation could not judge it"
            )
        case .validationFailedNoProgress(let rounds, let stillRejected):
            let reason = noProgressReason(roundsWithoutNewApprovals: rounds, stillRejected: stillRejected)
            return """
                [System: \(subject) FAILED acceptance validation. \(reason) \
                The result was NOT delivered. Tell the user briefly. Then decide WHY it stalled by reading the \
                rejection reasons in the task updates: if the criteria themselves were too strict, ambiguous, or \
                demanded evidence the worker's tools cannot produce, fix them with `set_acceptance_criteria` before \
                retrying; if the worker simply kept resubmitting incomplete work, a `run_task` retry (which resets \
                the validation counters) with clearer instructions may be enough. Do NOT re-run it unchanged and \
                expect a different outcome.]
                """
        case .startClaimed, .startAbandoned, .workerStartedAtRuntimeStart,
             .spawnFailedAtRuntimeStart, .submittedForValidation, .validationEscalated,
             .validationBlocked, .validationReleased, .rejectionsReturned, .helpRequested,
             .helpProvided, .userPaused, .userStopped, .userFailed, .userRevalidated, .userSentBack,
             .capacityShed, .scheduledAction, .scheduledTimeReached, .workerSelfTerminated,
             .smithTerminatedWorker, .smithSetStatus, .orphanRecovered, .resetForRun,
             .reopenedForRun, .templateLauncherNormalized, .coldBootRecovery,
             .coldBootSpawnAbandoned, .coldBootRevalidate, .sessionShutdown, .sessionDeletion:
            return nil
        }
    }

    /// The failure reason shared by the Smith note and the task's own update, so they can't disagree.
    public static func noProgressReason(roundsWithoutNewApprovals rounds: Int, stillRejected: Int) -> String {
        "No acceptance criterion was newly approved for \(rounds) validation rounds in a row — \(stillRejected) criterion(s) still rejected."
    }

    private static func completionBriefing(subject: String, completionNote: String) -> String {
        """
        [System: \(subject) \(completionNote). \
        The result was already delivered to the user in the Task Completed banner — do not repeat it. \
        No action is needed from you.]
        """
    }
}
