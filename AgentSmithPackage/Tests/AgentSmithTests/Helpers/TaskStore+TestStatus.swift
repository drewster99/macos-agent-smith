import Foundation
@testable import AgentSmithKit

extension TaskStore {
    /// Test fixture: moves a task to `target` through LEGAL transitions only (the cause matrix is
    /// not bypassed), choosing the causes a real run would use. Returns whether the task ended in
    /// `target`. `.awaitingReview` requires a stored result, exactly as in production.
    @discardableResult
    func driveStatus(id: UUID, to target: AgentTask.Status) -> Bool {
        guard let current = task(id: id)?.status else { return false }
        if current == target { return true }
        // `update_task` cannot move a review park — its resolvers own it — so leave one the way they do.
        if current == .awaitingReview, let parked = task(id: id) {
            switch target {
            case .completed: return updateStatus(id: id, status: .completed, cause: parked.acceptanceResolutionCause)
            case .failed: return updateStatus(id: id, status: .failed, cause: .userFailed)
            case .pending: return updateStatus(id: id, status: .pending, cause: .userSentBack)
            case .interrupted: return updateStatus(id: id, status: .interrupted, cause: .capacityShed)
            case .paused:
                guard updateStatus(id: id, status: .validating, cause: .userRevalidated) else { return false }
                return updateStatus(id: id, status: .paused, cause: .userPaused)
            default: break
            }
        }
        switch target {
        case .pending, .paused, .interrupted, .completed, .failed:
            return updateStatus(id: id, status: target, cause: .smithSetStatus)
        case .starting:
            if !current.isRunnable, !updateStatus(id: id, status: .pending, cause: .smithSetStatus) { return false }
            return updateStatus(id: id, status: .starting, cause: .startClaimed)
        case .running:
            switch current {
            case .starting, .pending, .paused, .interrupted:
                return updateStatus(id: id, status: .running, cause: .workerStarted)
            case .validating:
                return updateStatus(id: id, status: .running, cause: .rejectionsReturned)
            case .awaitingHelp:
                return updateStatus(id: id, status: .running, cause: .helpProvided)
            default:
                guard updateStatus(id: id, status: .pending, cause: .smithSetStatus) else { return false }
                return updateStatus(id: id, status: .running, cause: .workerStarted)
            }
        case .validating:
            if current == .awaitingReview {
                return updateStatus(id: id, status: .validating, cause: .userRevalidated)
            }
            guard driveStatus(id: id, to: .running) else { return false }
            return updateStatus(id: id, status: .validating, cause: .submittedForValidation)
        case .awaitingReview:
            guard driveStatus(id: id, to: .validating) else { return false }
            return updateStatus(id: id, status: .awaitingReview, cause: .validationEscalated)
        case .awaitingHelp:
            if current.isTerminal, !updateStatus(id: id, status: .pending, cause: .smithSetStatus) { return false }
            return updateStatus(id: id, status: .awaitingHelp, cause: .helpRequested)
        case .scheduled:
            return false
        }
    }
}
