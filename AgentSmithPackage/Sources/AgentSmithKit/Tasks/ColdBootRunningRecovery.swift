import Foundation

/// What a task persisted as `.running` becomes at cold boot, when no worker survived to own it.
///
/// The ONE statement of this rule. Both the session loader (which repairs `tasks.json` before any
/// runtime exists, so a session that is never started doesn't show dead work as running) and the
/// runtime's cold-boot reconciliation (the crash/force-quit backstop) apply it. They used to state
/// it separately and disagree: the loader demoted every `.running` task to `.interrupted` first, so
/// the runtime's submitted-result recovery below could never see a `.running` task and never ran.
public enum ColdBootRunningRecovery: Sendable, Equatable {
    /// The worker's `task_complete` durably wrote a result before the status left `.running`.
    /// That is submitted work, so it resumes acceptance validation instead of re-running Brown.
    case resumeValidation
    /// No submitted result: the worker died mid-work.
    case interrupt

    /// The recovery for `task`, or nil when it is not `.running`.
    public static func recovery(for task: AgentTask) -> ColdBootRunningRecovery? {
        guard task.status == .running else { return nil }
        return task.hasSubmittedResult ? .resumeValidation : .interrupt
    }

    /// The status the task is moved to.
    public var recoveredStatus: AgentTask.Status {
        switch self {
        case .resumeValidation: return .validating
        case .interrupt: return .interrupted
        }
    }

    /// The progress note recorded on the task, or nil when the status alone says enough.
    public var progressNote: String? {
        switch self {
        case .resumeValidation:
            return "Recovered submitted result after restart; resuming acceptance validation without re-running Brown."
        case .interrupt:
            return nil
        }
    }
}
