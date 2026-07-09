import Foundation
import Synchronization

/// FIFO queue that runs each scheduled async closure to completion before
/// starting the next. Calls to `schedule(_:)` are non-blocking; the work runs
/// in the background, in the order it was scheduled, with no overlap between
/// adjacent operations.
///
/// Used as `OrchestrationRuntime.lifecycleQueue`: every lifecycle transition
/// (start, stopAll, restart, tool-driven spawn/terminate) is one item, so two
/// transitions can never interleave their suspension points — the root enabler
/// of the 2026-07-08 zombie-agent incident.
final class SerialChainedTaskQueue: Sendable {
    private struct State {
        /// Tail of the FIFO chain — awaiting it means "everything scheduled so far is done".
        var inflight: Task<Void, Never>?
        /// Cancel handle for the work that is ACTUALLY executing right now (nil between
        /// items). Tracked separately from the chain so `cancelCurrent()` cancels just the
        /// running operation — cancelling a chain link would also poison the items still
        /// waiting on it. The `id` guards against a completed item clearing a successor's
        /// registration.
        var current: (id: UUID, cancel: @Sendable () -> Void)?
    }

    private let lock = Mutex<State>(State())

    public init() {}

    /// Cooperatively cancels the operation executing right now, if any. Queued
    /// (not-yet-started) operations are unaffected. The cancelled operation still runs its
    /// own completion path — cancellation lands wherever it checks `Task.isCancelled` or
    /// awaits something cancellation-aware (an LLM call, `Task.sleep`). Used by
    /// `stopAll`/`abort` so a stop request isn't head-of-line blocked behind a transition
    /// stuck in a slow provider call. Teardown operations ignore cancellation by
    /// construction (none of their awaits early-return on it), so a mistimed cancel can
    /// never truncate a stop.
    public func cancelCurrent() {
        lock.withLock { $0.current?.cancel() }
    }

    /// Schedule an async operation. Runs after every previously-scheduled
    /// operation has completed. Returns immediately.
    public func schedule(_ work: @escaping @Sendable () async -> Void) {
        lock.withLock { state in
            let prior = state.inflight
            state.inflight = Task { [self] in
                await prior?.value
                let workID = UUID()
                let workTask = Task { await work() }
                self.lock.withLock { $0.current = (workID, { workTask.cancel() }) }
                await workTask.value
                self.lock.withLock { if $0.current?.id == workID { $0.current = nil } }
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
        let task: Task<T, Never> = lock.withLock { state in
            let prior = state.inflight
            let item = Task { [self] in
                await prior?.value
                let workID = UUID()
                let workTask = Task { await work() }
                self.lock.withLock { $0.current = (workID, { workTask.cancel() }) }
                let value = await workTask.value
                self.lock.withLock { if $0.current?.id == workID { $0.current = nil } }
                return value
            }
            // The chain tracks completion only; the typed result is returned to the caller.
            state.inflight = Task { _ = await item.value }
            return item
        }
        return await task.value
    }

    /// Returns once every previously-scheduled operation has completed.
    /// Operations scheduled after this call begins are not awaited.
    public func waitForAll() async {
        let task = lock.withLock { $0.inflight }
        await task?.value
    }
}
