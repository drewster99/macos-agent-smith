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
    /// One tool call currently in front of the Security Agent's LLM.
    public struct SecurityEvaluationInFlight: Sendable, Equatable {
        /// The agent whose call this is — the one blocked until the verdict lands.
        public let agentInstanceID: UUID
        public init(agentInstanceID: UUID) {
            self.agentInstanceID = agentInstanceID
        }
    }

    /// Count of each concurrently-running operation type. Zero-valued default = nothing in flight.
    public struct Snapshot: Sendable, Equatable {
        public var brownWorkers = 0
        public var validatorEvaluations = 0
        public var summarizerRuns = 0
        public var memorySearches = 0

        /// THE source of truth for "the Security Agent is evaluating a tool call right now",
        /// keyed by tool call id. Registered by `SecurityEvaluator` at the one bracket that knows
        /// the answer — after the auto-approve fast paths, around the actual LLM round-trip.
        ///
        /// Everything about security-in-flight is DERIVED from this, because the same fact used to
        /// have three representations that disagreed: a count that excluded auto-approvals, a
        /// per-agent bool that included them, and a view that inferred "evaluating" from a verdict
        /// message not having arrived yet. That produced a worker reading "waiting on security"
        /// directly above a tally reading "0 Security".
        public var securityEvaluationsByCall: [String: SecurityEvaluationInFlight] = [:]

        /// How many real LLM-backed evaluations are in flight. Derived — never set.
        public var securityEvaluations: Int { securityEvaluationsByCall.count }

        /// Whether this agent is blocked waiting on a verdict for one of its calls. Derived.
        public func isAwaitingSecurity(agentInstanceID: UUID) -> Bool {
            securityEvaluationsByCall.values.contains { $0.agentInstanceID == agentInstanceID }
        }

        /// Whether this specific tool call is the one under review. Derived.
        public func isEvaluating(callID: String) -> Bool {
            securityEvaluationsByCall[callID] != nil
        }

        public init() {}

        /// True when nothing at all is in flight — lets the UI dim the whole strip.
        public var isIdle: Bool {
            brownWorkers == 0 && securityEvaluations == 0 && validatorEvaluations == 0
                && summarizerRuns == 0 && memorySearches == 0
        }
    }

    /// The per-operation activity kinds — those a caller brackets with `begin`/`end`. Brown workers
    /// are deliberately NOT here: a Brown is an absolute pool size reported per-runtime via
    /// `setBrownWorkers`, not a single bracketed operation. Security evaluations are not here
    /// either: they are registered per CALL (`beginSecurityEvaluation`) because three different
    /// readers need three different answers out of them, and a bare count can only answer one.
    public enum Kind: Sendable {
        case validatorEvaluation
        case summarizerRun
        case memorySearch
    }

    private let lock = NSLock()
    private var snapshot = Snapshot()
    /// Live Brown-worker count per reporting runtime. The snapshot's `brownWorkers` is the SUM, so
    /// concurrent sessions add up instead of one runtime's absolute report clobbering another's.
    private var brownWorkersBySource: [ObjectIdentifier: Int] = [:]
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

    /// Reports the ABSOLUTE Brown-worker count for one runtime (`source`). The snapshot exposes the
    /// SUM across all reporting runtimes, so a multi-session app shows total live Browns rather than
    /// whichever session reported last. A count of zero drops the source entirely (a stopped runtime
    /// leaves no residue). Callers recompute from their supervisor at each brown lifecycle change, so
    /// this self-heals even if a single transition is missed.
    public func setBrownWorkers(source: ObjectIdentifier, to value: Int) {
        let clamped = max(0, value)
        lock.lock()
        if clamped == 0 {
            brownWorkersBySource[source] = nil
        } else {
            brownWorkersBySource[source] = clamped
        }
        snapshot.brownWorkers = brownWorkersBySource.values.reduce(0, +)
        let snap = snapshot
        let handler = onChange
        lock.unlock()
        handler?(snap)
    }

    /// Registers a tool call as being evaluated by the Security Agent's LLM. Pair with
    /// `endSecurityEvaluation` in a `defer` — a stranded entry reads as an agent blocked forever.
    public func beginSecurityEvaluation(callID: String, agentInstanceID: UUID) {
        lock.lock()
        snapshot.securityEvaluationsByCall[callID] = SecurityEvaluationInFlight(agentInstanceID: agentInstanceID)
        let snap = snapshot
        let handler = onChange
        lock.unlock()
        handler?(snap)
    }

    /// Drops every evaluation registered against one agent, whether or not its `defer` ever runs.
    ///
    /// For agent teardown. A turn cancelled mid-flight leaves its registration standing until the
    /// in-flight LLM call finally returns — which, for a slow or cancellation-ignoring provider,
    /// can be minutes after `stop()` gave up and orphaned it. Without this the stopped worker reads
    /// "waiting on security" forever and its entry keeps inflating the Agents tally. Idempotent
    /// with the eventual `defer`, which finds nothing left to remove.
    public func endSecurityEvaluations(forAgentInstanceID agentInstanceID: UUID) {
        lock.lock()
        snapshot.securityEvaluationsByCall = snapshot.securityEvaluationsByCall.filter {
            $0.value.agentInstanceID != agentInstanceID
        }
        let snap = snapshot
        let handler = onChange
        lock.unlock()
        handler?(snap)
    }

    /// Clears a call's evaluation. Idempotent — clearing one that isn't registered is a no-op, so
    /// a duplicated `defer` can't corrupt the state the way an unbalanced counter could.
    public func endSecurityEvaluation(callID: String) {
        lock.lock()
        snapshot.securityEvaluationsByCall[callID] = nil
        let snap = snapshot
        let handler = onChange
        lock.unlock()
        handler?(snap)
    }

    private func adjust(_ kind: Kind, by delta: Int) {
        lock.lock()
        switch kind {
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
