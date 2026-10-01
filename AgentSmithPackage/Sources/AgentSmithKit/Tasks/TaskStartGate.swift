import Foundation

/// Who asked for a task to start. Every start path passes one, and the start gate
/// (`OrchestrationRuntime.restartForNewTask`) checks it against the task's start holds BEFORE
/// anything is cloned or claimed — a hold enforced at only some doors is not a hold.
public enum TaskStartOrigin: Codable, Sendable, Equatable {
    /// The user pressed Play / Resume.
    case explicitUser
    /// Smith's `run_task` or `create_task`.
    case smithTool
    /// A scheduled run fired.
    case scheduled
    /// "Auto-run next task" filled a free worker slot.
    case autoAdvance
    /// An interrupted task resumed at launch.
    case launchResume
    /// A task stopped when the user lowered capacity resumed once a slot freed.
    case capacityResume
    /// A `startTask` watch fired.
    case watchSatisfied(watchID: UUID)

    /// Only the user's explicit start overrides a hold (decision 3): every automatic path, and
    /// Smith, wait for it.
    public var overridesStartHolds: Bool {
        if case .explicitUser = self { return true }
        return false
    }
}

/// "Don't start this task until that watch fires": placed on the TARGET of a `startTask` watch
/// (`AgentTask.startHolds`), so every start path can see it without scanning other tasks' watches.
public struct TaskStartHold: Codable, Sendable, Equatable, Hashable {
    /// The task whose watch will start this one.
    public let watchedTaskID: UUID
    public let watchID: UUID

    public init(watchedTaskID: UUID, watchID: UUID) {
        self.watchedTaskID = watchedTaskID
        self.watchID = watchID
    }
}
