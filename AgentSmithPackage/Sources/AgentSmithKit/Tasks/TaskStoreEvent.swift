import Foundation

/// Everything a `TaskStore` reports to its subscriber, in the order it happened: status transitions
/// and lifecycle (disposition) changes share one ordered stream so a reader never sees a task's
/// deletion before the transition that preceded it.
public enum TaskStoreEvent: Sendable, Equatable {
    case transition(TaskStatusTransition)
    case lifecycle(TaskLifecycleEvent)
    /// A write left released, undelivered effects (`TaskStore.readyEffects`).
    case effectsReady
    /// A watch was cancelled while some of its firings had already been handed to the broker
    /// (`occurrences`): whoever holds them should withdraw what has not reached its recipient yet.
    case watchCancelled(taskID: UUID, watchID: UUID, handedOffOccurrences: [Int])
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
