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

    // MARK: Validation
    /// Brown's `task_complete` handed the result to acceptance validation.
    case submittedForValidation
    /// Every criterion settled (or validation is switched off) and the task completed.
    case validationPassed(validationWasRun: Bool)
    /// Too many consecutive rounds settled nothing.
    case validationFailedNoProgress(roundsWithoutNewApprovals: Int, stillRejected: Int)
    /// A validator error parked the task for the user.
    case validationEscalated
    /// The task's author required the user's own acceptance (`AgentTask.requiresUserAcceptance`), so
    /// instead of completing it parked for the user's sign-off: every criterion settled
    /// (`validationWasRun`), or acceptance validation is switched off and nothing was judged.
    case userAcceptanceRequested(validationWasRun: Bool)
    /// The acceptance criteria of a task waiting for the user's sign-off changed (a criterion added,
    /// or its judging text edited), so a criterion the sign-off would cover was never judged: the task
    /// goes back to validation, which judges what changed (settled verdicts are sticky) and parks it
    /// for sign-off again. Written by `TaskStore.editAcceptanceContract` in the same write as the edit.
    case signOffContractChanged
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
    /// The user accepted a review park, overriding acceptance validation: a validator-error park, or a
    /// sign-off park whose contract changed after it parked (`AgentTask.acceptanceResolutionCause`).
    case userAccepted
    /// The user signed off on a task parked ONLY for their sign-off
    /// (`AgentTask.isAwaitingOnlyUserSignOff`) — not an override.
    case userAcceptanceGranted(validationWasRun: Bool)
    case userFailed
    case userRevalidated
    case userSentBack

    // MARK: Runtime
    /// The user lowered worker capacity and this task's worker was stopped to free a slot.
    case capacityShed
    /// The worker's model can't be used (out of credits, rejected key, model not in the plan —
    /// `ProviderUnavailableKind`): the task is paused rather than failed, and resumes when the
    /// worker's model changes or the user presses Play.
    case providerUnavailable
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
        case .providerUnavailable:
            return from == .running && to == .interrupted
        case .startAbandoned:
            // `.interrupted` only for a refused resume going back onto its resume queue.
            return from == .starting && (to == .pending || to == .interrupted)
        case .spawnFailed, .spawnFailedAtRuntimeStart:
            return [.starting, .pending, .paused, .interrupted, .running].contains(from) && to == .failed
        case .workerStarted, .workerStartedAtRuntimeStart:
            return [.starting, .pending, .paused, .interrupted].contains(from) && to == .running
        case .submittedForValidation:
            return from == .running && to == .validating
        case .validationPassed:
            // Only from `.validating`: no machine cause may complete a parked task — a park is
            // resolved by the user (`.userAccepted` / `.userAcceptanceGranted`).
            return from == .validating && to == .completed
        case .validationFailedNoProgress:
            return from == .validating && to == .failed
        case .validationEscalated, .validationBlocked, .userAcceptanceRequested:
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
        case .userAccepted, .userAcceptanceGranted:
            return from == .awaitingReview && to == .completed
        case .userFailed:
            return from == .awaitingReview && to == .failed
        case .userRevalidated, .signOffContractChanged:
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
            return UpdateTaskStatusPolicy.permits(from: from, to: to)
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

    /// Which `.awaitingReview` park this cause enters; nil when it enters none. The ONLY source of
    /// `AgentTask.awaitingReviewReason` (`TaskStore.changeStatus`). Exhaustive on purpose: a new
    /// cause must decide whether it parks.
    public var awaitingReviewPark: AwaitingReviewPark? {
        switch self {
        case .validationEscalated:
            return .review(.validatorError)
        case .userAcceptanceRequested(let validationWasRun):
            return .review(validationWasRun ? .userAcceptanceRequested : .userAcceptanceRequestedValidationSkipped)
        case .validationBlocked:
            return .validationBlocked
        case .startClaimed, .startAbandoned, .spawnFailed, .spawnFailedAtRuntimeStart, .workerStarted,
             .workerStartedAtRuntimeStart, .submittedForValidation, .validationPassed,
             .validationFailedNoProgress, .validationReleased, .rejectionsReturned, .helpRequested,
             .helpProvided, .userPaused, .userStopped, .userAccepted, .userAcceptanceGranted, .userFailed,
             .userRevalidated, .signOffContractChanged, .userSentBack, .capacityShed, .providerUnavailable, .scheduledAction, .scheduledTimeReached,
             .workerSelfTerminated, .smithTerminatedWorker, .smithSetStatus, .orphanRecovered, .resetForRun,
             .reopenedForRun, .templateLauncherNormalized, .coldBootRecovery, .coldBootSpawnAbandoned,
             .coldBootRevalidate, .sessionShutdown, .sessionDeletion:
            return nil
        }
    }

    /// The user's acceptance of a submitted result: the only causes that may complete a task gated on
    /// `requiresUserAcceptance` (enforced by `TaskStore.changeStatus`).
    public var isUsersAcceptanceOfResult: Bool {
        switch self {
        case .userAccepted, .userAcceptanceGranted:
            return true
        case .startClaimed, .startAbandoned, .spawnFailed, .spawnFailedAtRuntimeStart, .workerStarted,
             .workerStartedAtRuntimeStart, .submittedForValidation, .validationPassed,
             .validationFailedNoProgress, .validationEscalated, .userAcceptanceRequested, .validationBlocked,
             .validationReleased, .rejectionsReturned, .helpRequested, .helpProvided, .userPaused,
             .userStopped, .userFailed, .userRevalidated, .signOffContractChanged, .userSentBack, .capacityShed, .providerUnavailable, .scheduledAction,
             .scheduledTimeReached, .workerSelfTerminated, .smithTerminatedWorker, .smithSetStatus,
             .orphanRecovered, .resetForRun, .reopenedForRun, .templateLauncherNormalized,
             .coldBootRecovery, .coldBootSpawnAbandoned, .coldBootRevalidate, .sessionShutdown, .sessionDeletion:
            return false
        }
    }
}

/// The two kinds of `.awaitingReview` park.
public enum AwaitingReviewPark: Equatable, Sendable {
    /// A submission for a person to resolve; the reason says why.
    case review(AgentTask.AwaitingReviewReason)
    /// No validator model is assigned (`AgentTask.validationBlockedReason`); nobody's to resolve.
    case validationBlocked
}

/// The statuses Smith may set directly with `update_task`. Everything else has a dedicated path
/// (`run_task` for running, `task_complete` for validating, `request_help` for awaitingHelp, and
/// validation escalation for awaitingReview). One list, read by both the tool and the matrix.
public enum UpdateTaskStatusPolicy {
    public static let settable: Set<AgentTask.Status> = [.pending, .paused, .interrupted, .completed, .failed]

    /// Whether `update_task` may move a task from `from` to `to`. Never out of `.awaitingReview`: its
    /// resolvers (the user, configuration) own that park. Never `.validating` → `.completed`: that
    /// would finish a submission its validator is judging, skipping the judgment (decided 2026-10-04).
    public static func permits(from: AgentTask.Status, to: AgentTask.Status) -> Bool {
        guard settable.contains(to), from != .awaitingReview else { return false }
        return !(from == .validating && to == .completed)
    }
}
