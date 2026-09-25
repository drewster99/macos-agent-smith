import Foundation

/// One real change of a task's status, produced by `TaskStore`'s single status writer. Everything
/// that reacts to a status change reads this, never a status comparison of its own: the runtime's
/// reactions, the Smith briefing, and task watches. See TaskStateEventsPlan.md.
public struct TaskStatusTransition: Codable, Sendable, Equatable {
    public let taskID: UUID
    /// The task's `statusRevision` AFTER this transition — per task, monotonic, persisted. With
    /// `taskID` it names the transition uniquely and deterministically.
    public let statusRevision: Int
    public let from: AgentTask.Status
    public let to: AgentTask.Status
    public let at: Date
    public let cause: TaskTransitionCause

    public init(taskID: UUID, statusRevision: Int, from: AgentTask.Status, to: AgentTask.Status, at: Date, cause: TaskTransitionCause) {
        self.taskID = taskID
        self.statusRevision = statusRevision
        self.from = from
        self.to = to
        self.at = at
        self.cause = cause
    }

    /// First entry into a terminal status (`.completed` / `.failed`).
    public var entersTerminal: Bool { to.isTerminal && !from.isTerminal }
}

/// WHY a task's status changed. Typed and required: control flow (watch matching, the Smith
/// briefing) reads the cause, never the text of an update or a message. Every cause is validated
/// against the transitions it may legally make (`permits(from:to:)`), so a caller passing the
/// wrong cause is refused instead of silently steering a subscriber.
///
/// PERSISTED (inside effect records): case names are the wire format. Renaming a case is a
/// migration; add new cases freely.
public enum TaskTransitionCause: Codable, Sendable, Equatable, Hashable {
    // MARK: Starting
    /// A start was claimed and the worker is being spawned.
    case startClaimed
    /// The spawn failed transiently; the claim is released so the task can be picked up again.
    case startAbandoned
    /// The worker could not be spawned; the task fails.
    case spawnFailed
    /// As `spawnFailed`, while the runtime itself was starting: the NEW Smith's initial instruction
    /// reports it, so the Smith briefing stays silent.
    case spawnFailedAtRuntimeStart
    /// The worker is live and assigned. A "started" fact for watches.
    case workerStarted
    /// As `workerStarted`, while the runtime itself was starting (a run_task restart with no live
    /// Smith, or the launch auto-resume of interrupted tasks): the NEW Smith's initial instruction
    /// reports it, so the Smith briefing stays silent. Also a "started" fact for watches.
    case workerStartedAtRuntimeStart
    /// Brown's first-turn acknowledgement. Usually a no-op (the runtime already set `.running`).
    case workerAcknowledged

    // MARK: Validation
    /// Brown's `task_complete` handed the result to acceptance validation.
    case submittedForValidation
    /// Every criterion settled (or validation is switched off) and the task completed.
    case validationPassed(validationWasRun: Bool)
    /// Too many consecutive rounds settled nothing.
    case validationFailedNoProgress(roundsWithoutNewApprovals: Int, stillRejected: Int)
    /// A validator error parked the task for the user.
    case validationEscalated
    /// No validator model is assigned; the task is parked until one is.
    case validationBlocked
    /// A validator model appeared; the parked task resumes validation.
    case validationReleased
    /// Rejections went back to the worker (to `.running`), or were re-queued (to `.pending`) when no
    /// worker slot was free.
    case rejectionsReturned

    // MARK: Help
    case helpRequested
    case helpProvided

    // MARK: User actions
    case userPaused
    case userStopped
    case userAccepted
    case userFailed
    case userRevalidated
    case userSentBack

    // MARK: Runtime
    /// The user lowered worker capacity and this task's worker was stopped to free a slot.
    case capacityShed
    /// A scheduled task action (pause / interrupt) fired.
    case scheduledAction(TaskActionKind)
    /// A scheduled task's run time arrived.
    case scheduledTimeReached
    /// The worker ended itself (e.g. an unrecoverable error) with the task still running.
    case workerSelfTerminated
    /// Smith terminated the task's worker.
    case smithTerminatedWorker
    /// Smith set the status with `update_task`.
    case smithSetStatus
    /// The monitor found a running task with no worker on two consecutive ticks.
    case orphanRecovered
    /// `run_task` reset a failed task for a retry.
    case resetForRun
    /// `run_task` reopened a completed task for another run.
    case reopenedForRun
    /// A task turned into a template was reset to a launchable `.pending`.
    case templateLauncherNormalized

    // MARK: Launch and shutdown
    /// A task found `.running` with no surviving worker (crash, force-quit, runtime restart).
    case coldBootRecovery(ColdBootRunningRecovery)
    /// A task found `.starting` had no worker; it returns to `.pending` for a fresh start.
    case coldBootSpawnAbandoned
    /// A validator-error escalation re-validates on restart instead of waiting for a human.
    case coldBootRevalidate
    /// Stop All interrupted a running task.
    case sessionShutdown
    /// Deleting the session interrupted an in-progress task so it could be archived.
    case sessionDeletion

    /// Whether this cause may move a task from `from` to `to`. The single matrix every live status
    /// write is checked against (`TaskStore.applyStatus`). TaskStateEventsPlan.md mirrors it.
    public func permits(from: AgentTask.Status, to: AgentTask.Status) -> Bool {
        switch self {
        case .startClaimed:
            return from.isRunnable && to == .starting
        case .startAbandoned:
            return from == .starting && to == .pending
        case .spawnFailed, .spawnFailedAtRuntimeStart:
            return [.starting, .pending, .paused, .interrupted, .running].contains(from) && to == .failed
        case .workerStarted, .workerStartedAtRuntimeStart:
            return [.starting, .pending, .paused, .interrupted].contains(from) && to == .running
        case .workerAcknowledged:
            return (from.isRunnable || from == .running) && to == .running
        case .submittedForValidation:
            return from == .running && to == .validating
        case .validationPassed:
            return [.validating, .awaitingReview].contains(from) && to == .completed
        case .validationFailedNoProgress:
            return from == .validating && to == .failed
        case .validationEscalated, .validationBlocked:
            return from == .validating && to == .awaitingReview
        case .validationReleased:
            return from == .awaitingReview && to == .validating
        case .rejectionsReturned:
            return from == .validating && (to == .running || to == .pending)
        case .helpRequested:
            return !from.isTerminal && from != .awaitingHelp && to == .awaitingHelp
        case .helpProvided:
            return from == .awaitingHelp && to == .running
        case .userPaused:
            return [.running, .validating].contains(from) && to == .paused
        case .userStopped:
            return [.running, .validating].contains(from) && to == .interrupted
        case .userAccepted:
            return from == .awaitingReview && to == .completed
        case .userFailed:
            return from == .awaitingReview && to == .failed
        case .userRevalidated:
            return from == .awaitingReview && to == .validating
        case .userSentBack:
            return from == .awaitingReview && (to == .running || to == .pending)
        case .capacityShed:
            return [.starting, .running, .validating, .awaitingHelp, .awaitingReview].contains(from) && to == .interrupted
        case .scheduledAction(let kind):
            switch kind {
            case .pause: return [.running, .validating].contains(from) && to == .paused
            case .interrupt: return [.running, .validating].contains(from) && to == .interrupted
            case .run, .summarize: return false
            }
        case .scheduledTimeReached:
            return from == .scheduled && to == .pending
        case .workerSelfTerminated:
            return from == .running && to == .failed
        case .smithTerminatedWorker:
            return [.running, .awaitingHelp].contains(from) && to == .failed
        case .smithSetStatus:
            return UpdateTaskStatusPolicy.settable.contains(to)
        case .orphanRecovered:
            return from == .running && to == .interrupted
        case .resetForRun:
            return from == .failed && to == .pending
        case .reopenedForRun:
            return from == .completed && to == .pending
        case .templateLauncherNormalized:
            return to == .pending
        case .coldBootRecovery(let recovery):
            return from == .running && to == recovery.recoveredStatus
        case .coldBootSpawnAbandoned:
            return from == .starting && to == .pending
        case .coldBootRevalidate:
            return from == .awaitingReview && to == .validating
        case .sessionShutdown:
            return from == .running && to == .interrupted
        case .sessionDeletion:
            return from.isInProgress && to == .interrupted
        }
    }
}

/// The statuses Smith may set directly with `update_task`. Everything else has a dedicated path
/// (`run_task` for running, `task_complete` for validating, `request_help` for awaitingHelp, and
/// validation escalation for awaitingReview). One list, read by both the tool and the matrix.
public enum UpdateTaskStatusPolicy {
    public static let settable: Set<AgentTask.Status> = [.pending, .paused, .interrupted, .completed, .failed]
}
