import Foundation
import Synchronization

/// FIFO queue that runs each scheduled async closure to completion before
/// starting the next. Calls to `schedule(_:)` are non-blocking; the work runs
/// in the background, in the order it was scheduled, with no overlap between
/// adjacent operations.
///
/// Used by `OrchestrationRuntime.restartForNewTask` so two near-concurrent
/// restart requests can no longer interleave their `stopAll()` + `start()`
/// chains. Without this, the second restart's `start()` could hit
/// `OrchestrationRuntime.start`'s `guard smith == nil` check while the first
/// restart was still mid-setup, silently dropping the second taskID.
final class SerialChainedTaskQueue: Sendable {
    private let lock = Mutex<Task<Void, Never>?>(nil)

    public init() {}

    /// Schedule an async operation. Runs after every previously-scheduled
    /// operation has completed. Returns immediately.
    public func schedule(_ work: @escaping @Sendable () async -> Void) {
        lock.withLock { inflight in
            let prior = inflight
            inflight = Task {
                await prior?.value
                await work()
            }
        }
    }

    /// Returns once every previously-scheduled operation has completed.
    /// Operations scheduled after this call begins are not awaited.
    public func waitForAll() async {
        let task = lock.withLock { $0 }
        await task?.value
    }
}
