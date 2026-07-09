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

    /// Schedules an async operation like `schedule(_:)`, but suspends the caller until
    /// that operation completes and returns its result. This is how the runtime's public
    /// lifecycle entry points (`start`, `stopAll`, `spawnBrown`, `terminateAgent`) get
    /// serialized while keeping their awaited-completion semantics for callers.
    ///
    /// DEADLOCK RULE: never call `run` from inside an operation already executing on the
    /// same queue — the inner call would wait for the queue to drain, which includes the
    /// operation making the call. Queue items must call internal (unqueued)
    /// implementations directly; only outermost entry points enqueue.
    public func run<T: Sendable>(_ work: @escaping @Sendable () async -> T) async -> T {
        let task: Task<T, Never> = lock.withLock { inflight in
            let prior = inflight
            let item = Task {
                await prior?.value
                return await work()
            }
            // The chain tracks completion only; the typed result is returned to the caller.
            inflight = Task { _ = await item.value }
            return item
        }
        return await task.value
    }

    /// Returns once every previously-scheduled operation has completed.
    /// Operations scheduled after this call begins are not awaited.
    public func waitForAll() async {
        let task = lock.withLock { $0 }
        await task?.value
    }
}
