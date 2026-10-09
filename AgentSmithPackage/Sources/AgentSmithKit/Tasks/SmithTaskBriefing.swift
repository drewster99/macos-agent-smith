import Foundation

/// The built-in subscriber that tells Smith about a task's status change: maps a transition to the
/// note Smith receives, or to nothing. The ONE place those notes are composed; the store records
/// the note as a durable effect in the same write as the status (see `TaskEffectRecord`).
///
/// Covers the transitions Smith was told about before this existed (decision 2026-09-24: same set,
/// same text), WIDENED 2026-10-02 to the user-acceptance park and its sign-off: without a note Smith
/// could not tell the user a gated task is waiting on them, nor recognize their reply as the decision
/// to relay. Notes about things that are NOT
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
        case .preconditionUnmet:
            let why = task.preconditionFailure?.reason ?? "a precondition didn't hold"
            return """
                [System: \(subject) is BLOCKED, not failed: \(why). It never got as far as a result, and \
                no validation ran. Tell the user briefly what is missing. Do NOT re-run it unchanged — it \
                is checked again on every start, so it would block again. Once the missing thing is in \
                place, `run_task` retries it. If the precondition itself is wrong, correct it with \
                `set_preconditions` first — unless the user set it, in which case ask them.]
                """
        case .validationPassed(let validationWasRun):
            let completionNote = validationWasRun
                ? "passed acceptance validation and is COMPLETE"
                : "is COMPLETE — acceptance validation is disabled, so its criteria were NOT judged"
            return completionBriefing(subject: subject, completionNote: completionNote)
        case .userAcceptanceRequested(let validationWasRun):
            let judgment = validationWasRun
                ? "every acceptance criterion passed validation"
                : "acceptance validation is switched off, so its criteria were NOT judged"
            return """
                [System: \(subject) is WAITING FOR THE USER'S SIGN-OFF — \(judgment), and the task \
                requires the user's own acceptance before it completes. Its worker has stopped. Tell the \
                user in one short message that it is ready for their review and that they can accept it or \
                ask for changes, from the task row or by replying to you; point them to the task's result \
                rather than pasting it. Do NOT accept or reject it yourself: call \
                `respond_to_user_acceptance` for this task only after the user tells you their decision about it.]
                """
        case .userAcceptanceGranted(let validationWasRun):
            return completionBriefing(subject: subject, completionNote: validationWasRun
                ? "is COMPLETE — the user signed off on it after every acceptance criterion passed validation"
                : "is COMPLETE — the user signed off on it; acceptance validation is switched off, so its criteria were NOT judged")
        case .userAccepted:
            return completionBriefing(
                subject: subject,
                // An OVERRIDE: at least one criterion was unsettled — a validator could not judge it, or
                // the criteria changed after a sign-off park — so the note claims neither cause.
                completionNote: "is COMPLETE — the user accepted it from review, overriding acceptance validation (at least one criterion had not been settled by a validator)"
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
        case .providerUnavailable:
            return """
                [System: \(subject) is ON HOLD (interrupted), not failed: its worker's model couldn't be used \
                (an account or model problem — the user has been told what it is). It restarts automatically \
                when the worker's model works again: at once if the user already switched it, otherwise when \
                they switch it or press Play on the task; no task starts on that model until then. Do NOT \
                `run_task`, recreate, or fail it. No action is needed from you; if the user asks, point them \
                to the notice about the worker's model.]
                """
        case .startClaimed, .startAbandoned, .workerStartedAtRuntimeStart,
             .spawnFailedAtRuntimeStart, .submittedForValidation, .validationEscalated,
             .validationBlocked, .validationReleased, .rejectionsReturned, .helpRequested,
             .helpProvided, .userPaused, .userStopped, .userFailed, .userRevalidated, .signOffContractChanged, .userSentBack,
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
