import Foundation

/// Everything a `TaskStore` reports to its subscriber, in the order it happened: status transitions
/// and lifecycle (disposition) changes share one ordered stream so a reader never sees a task's
/// deletion before the transition that preceded it.
public enum TaskStoreEvent: Sendable, Equatable {
    case transition(TaskStatusTransition)
    case lifecycle(TaskLifecycleEvent)
    /// A write left released, undelivered effects (`TaskStore.readyEffects`).
    case effectsReady
    /// A session task's required capabilities changed, so a worker running it must have its tools
    /// re-scoped against the new list. Never emitted for a library template: no worker runs one.
    case requiredCapabilitiesChanged(taskID: UUID)
    /// A coordinator's child left the active list while the coordinator was still coordinating —
    /// unfinished, or carrying an outcome its coordinator had not been handed yet.
    case childLeftCoordination(CoordinatorChildDeparture)
    /// A task became a template, so it no longer coordinates the children it created (a template
    /// is a launcher, never a piece of work): notes queued for its worker will never be read.
    case promotedToTemplate(taskID: UUID)
}

/// A child task leaving its open coordinator's reach (archived, deleted, permanently deleted). The
/// move drops a task's undelivered effects, so the outcome records it dropped travel here, to be
/// delivered under their original ids (a delivery already made dedups).
public struct CoordinatorChildDeparture: Sendable, Equatable {
    public enum Departure: Sendable, Equatable {
        case leftActive(AgentTask.TaskDisposition)
        case permanentlyDeleted
    }

    /// This departure's own identity. A disposition change bumps no status revision, so archive →
    /// restore → archive of one pending child is told apart only by this.
    public let id: UUID
    public let coordinatorTaskID: UUID
    /// The child as it was just before it left (its effects not yet stripped).
    public let child: AgentTask
    public let departure: Departure
    /// The `.coordinatorBriefing` records the move dropped.
    public let undeliveredOutcomes: [TaskEffectRecord]
}

/// A task entering or leaving this session's active store. Deliberately NOT a status transition:
/// archiving or deleting a task says nothing about how its work went, and watches key on status.
public enum TaskLifecycleEvent: Sendable, Equatable {
    /// Archived or soft-deleted: moved out to the global inactive store.
    case leftActive(taskID: UUID, disposition: AgentTask.TaskDisposition)
    /// Removed for good, from wherever it lived.
    case permanentlyDeleted(taskID: UUID)
    /// Returned to the active store (unarchive, undelete, or restored by `run_task`).
    case restoredToActive(taskID: UUID)

    public var taskID: UUID {
        switch self {
        case .leftActive(let taskID, _), .permanentlyDeleted(let taskID), .restoredToActive(let taskID):
            return taskID
        }
    }
}
