import Foundation

/// Live, per-type count of in-flight agent operations, so the inspector can show how many of each
/// are happening AT ONCE — e.g. "3 Brown · 2 Security · 4 Validator · 1 Summarizer · 2 Search".
///
/// Deliberately a lock-guarded `final class`, not an actor: the counters are bumped from inside other
/// actors (`MemoryStore`, the runtime) and from leaf helpers (`SecurityEvaluator`), and a synchronous
/// `begin`/`end` pair lets a `defer` guarantee the decrement even on `throw`/cancel without awaiting an
/// actor hop mid-operation. Each mutation fires `onChange` with a value snapshot; the app layer hops
/// that to the main thread (like the cost board).
public final class LiveActivityTracker: @unchecked Sendable {
    /// Count of each concurrently-running operation type. Zero-valued default = nothing in flight.
    public struct Snapshot: Sendable, Equatable {
        public var brownWorkers = 0
        public var securityEvaluations = 0
        public var validatorEvaluations = 0
        public var summarizerRuns = 0
        public var memorySearches = 0
        public init() {}

        /// True when nothing at all is in flight — lets the UI dim the whole strip.
        public var isIdle: Bool {
            brownWorkers == 0 && securityEvaluations == 0 && validatorEvaluations == 0
                && summarizerRuns == 0 && memorySearches == 0
        }
    }

    public enum Kind: Sendable {
        case brownWorker
        case securityEvaluation
        case validatorEvaluation
        case summarizerRun
        case memorySearch
    }

    private let lock = NSLock()
    private var snapshot = Snapshot()
    private var onChange: (@Sendable (Snapshot) -> Void)?

    public init() {}

    /// Registers a callback fired (off the lock) after every count change, with a value snapshot.
    public func setOnChange(_ handler: @escaping @Sendable (Snapshot) -> Void) {
        lock.lock()
        onChange = handler
        let snap = snapshot
        lock.unlock()
        // Deliver the current state immediately so a late observer isn't stuck at all-zero.
        handler(snap)
    }

    /// The current snapshot.
    public func current() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    /// Increments the in-flight count for `kind`. Pair with `end` in a `defer`.
    public func begin(_ kind: Kind) { adjust(kind, by: 1) }

    /// Decrements the in-flight count for `kind` (clamped at zero).
    public func end(_ kind: Kind) { adjust(kind, by: -1) }

    /// Sets an ABSOLUTE count — used for the Brown worker pool, which the runtime tracks by
    /// spawn/terminate rather than by bracketing a single operation.
    public func set(_ kind: Kind, to value: Int) {
        let clamped = max(0, value)
        lock.lock()
        switch kind {
        case .brownWorker: snapshot.brownWorkers = clamped
        case .securityEvaluation: snapshot.securityEvaluations = clamped
        case .validatorEvaluation: snapshot.validatorEvaluations = clamped
        case .summarizerRun: snapshot.summarizerRuns = clamped
        case .memorySearch: snapshot.memorySearches = clamped
        }
        let snap = snapshot
        let handler = onChange
        lock.unlock()
        handler?(snap)
    }

    private func adjust(_ kind: Kind, by delta: Int) {
        lock.lock()
        switch kind {
        case .brownWorker: snapshot.brownWorkers = max(0, snapshot.brownWorkers + delta)
        case .securityEvaluation: snapshot.securityEvaluations = max(0, snapshot.securityEvaluations + delta)
        case .validatorEvaluation: snapshot.validatorEvaluations = max(0, snapshot.validatorEvaluations + delta)
        case .summarizerRun: snapshot.summarizerRuns = max(0, snapshot.summarizerRuns + delta)
        case .memorySearch: snapshot.memorySearches = max(0, snapshot.memorySearches + delta)
        }
        let snap = snapshot
        let handler = onChange
        lock.unlock()
        handler?(snap)
    }
}
