import Foundation

/// Where a coordinator's child task stands, as far as the coordinator waiting on it is concerned.
/// `wait_for_child_tasks` parks only while some child can still finish without the coordinator
/// doing anything; a worker must never park on a child that won't move.
public enum ChildTaskProgress: Sendable, Equatable {
    /// Its outcome happened (completed or failed), wherever it now lives.
    case finished
    /// Working, queued for a worker, or resuming on its own.
    case progressing
    /// Waiting on someone who has already been told: the user (a review or sign-off), Smith (a help
    /// request), or the task a watch holds it for.
    case waitingOnOthers(Blocker)
    /// Will not continue unless the user or Smith acts on it, and nobody has been asked to.
    case stalled(Stall)

    public enum Blocker: Sendable, Equatable {
        case user
        case smith
        case startHold
    }

    public enum Stall: Sendable, Equatable {
        case paused
        case interrupted
        case leftActive(AgentTask.TaskDisposition)
    }

    /// Whether a coordinator may park waiting on this child.
    public var isWaitable: Bool {
        switch self {
        case .progressing, .waitingOnOthers: return true
        case .finished, .stalled: return false
        }
    }

    /// How the child is described to the coordinator, after its status.
    var explanation: String? {
        switch self {
        case .finished, .progressing: return nil
        case .waitingOnOthers(.user): return "waiting for the user"
        case .waitingOnOthers(.smith): return "waiting for Smith's help"
        case .waitingOnOthers(.startHold): return "held until the task it waits for finishes"
        case .stalled(.paused): return "paused — does not continue unless the user or Smith resumes it"
        case .stalled(.interrupted): return "stopped — does not continue unless the user or Smith restarts it"
        case .stalled(.leftActive(let disposition)):
            switch disposition {
            case .archived: return "archived before it finished — it will not continue"
            case .recentlyDeleted: return "deleted before it finished — it will not continue"
            case .active: return nil
            }
        }
    }
}

extension AgentTask {
    /// Whether this task's worker owns the children it created: an open task in the active list
    /// (not a template). While true, a child's outcome is reported to its worker, not to Smith. THE
    /// predicate for "is this coordinator still coordinating" — effect recording, delivery,
    /// departure notices and `get_task_details`' routing line all ask it.
    public var isCoordinatingChildren: Bool {
        disposition == .active && !status.isTerminal && !isTemplate
    }

    /// Where this child stands for its coordinator. `resumesAutomatically` says whether the runtime
    /// will resume it on its own when it is interrupted (`OrchestrationRuntime.automaticallyResumingChildTaskIDs`).
    public func progressAsChildTask(resumesAutomatically: Bool) -> ChildTaskProgress {
        // Terminal first: an archived COMPLETED child is finished, not stalled.
        if status.isTerminal { return .finished }
        guard disposition == .active else { return .stalled(.leftActive(disposition)) }
        switch status {
        case .completed, .failed:
            return .finished
        case .starting, .running, .validating, .scheduled:
            return .progressing
        case .pending:
            return startHolds.isEmpty ? .progressing : .waitingOnOthers(.startHold)
        case .awaitingHelp:
            return .waitingOnOthers(.smith)
        case .awaitingReview:
            return .waitingOnOthers(.user)
        case .paused:
            return .stalled(.paused)
        case .interrupted:
            return resumesAutomatically ? .progressing : .stalled(.interrupted)
        }
    }
}

public enum CoordinatorChildren {
    /// One list of a coordinator's children from several sources (the active list, the inactive
    /// store): deduplicated by id, the newer copy winning — a child moving between stores can be
    /// read in both — and in `AgentTask.coordinationOrder`.
    public static func collect(_ sources: [AgentTask]...) -> [AgentTask] {
        var byID: [UUID: AgentTask] = [:]
        for task in sources.joined() {
            if let existing = byID[task.id], existing.updatedAt >= task.updatedAt { continue }
            byID[task.id] = task
        }
        return byID.values.sorted(by: AgentTask.coordinationOrder)
    }
}
