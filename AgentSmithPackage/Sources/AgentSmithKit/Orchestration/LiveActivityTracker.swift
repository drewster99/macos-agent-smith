import Foundation
import os

/// Live, per-type count of in-flight agent operations, so the inspector can show how many of each
/// are happening AT ONCE — e.g. "3 Brown · 2 Security · 4 Validator · 1 Summarizer · 2 Search".
///
/// Deliberately a lock-guarded `final class`, not an actor: the counters are bumped from inside other
/// actors (`MemoryStore`, the runtime) and from leaf helpers (`SecurityEvaluator`), and a synchronous
/// `begin`/`end` pair lets a `defer` guarantee the decrement even on `throw`/cancel without awaiting an
/// actor hop mid-operation. Each mutation fires `onChange` with a value snapshot; the app layer hops
/// that to the main thread (like the cost board).
public final class LiveActivityTracker: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.nuclearcyborg.AgentSmith", category: "LiveActivity")

    /// Identifies one in-flight evaluation.
    ///
    /// The agent instance is part of the KEY, not just the value. A tool call id is whatever the
    /// provider sent — some OpenAI-compatible servers emit per-response index ids (`call_0`), and
    /// the id field is only guarded against being absent, not against being empty. This tracker is
    /// app-wide and shared by every session's runtime, so keying on the call id alone let two
    /// agents collide: the second registration overwrote the first (under-counting the meter AND
    /// making the first agent's "waiting on security" read false while it was genuinely blocked),
    /// and whichever finished first deleted the other's entry.
    public struct SecurityEvaluationKey: Sendable, Hashable {
        public let agentInstanceID: UUID
        public let callID: String
        public init(agentInstanceID: UUID, callID: String) {
            self.agentInstanceID = agentInstanceID
            self.callID = callID
        }
    }

    /// Count of each concurrently-running operation type. Zero-valued default = nothing in flight.
    public struct Snapshot: Sendable, Equatable {
        /// Equality deliberately IGNORES `version`, which changes on every publish. Synthesised
        /// equality made two content-identical snapshots compare unequal, so every observer keyed
        /// on the snapshot — `.onChange(of:)`, `.animation(_:value:)` — fired on publishes that
        /// changed nothing, undoing the "no-op ends don't publish" saving one line of code away.
        /// Ordering is a property of the DELIVERY, not of the state; `supersedes` is where it lives.
        public static func == (lhs: Snapshot, rhs: Snapshot) -> Bool {
            lhs.brownWorkers == rhs.brownWorkers
                && lhs.validatorEvaluations == rhs.validatorEvaluations
                && lhs.summarizerRuns == rhs.summarizerRuns
                && lhs.memorySearches == rhs.memorySearches
                && lhs.securityEvaluationsByCall == rhs.securityEvaluationsByCall
        }

        /// Whether this snapshot describes a state at least as recent as `other` — the test an
        /// observer applies before adopting a delivery. Lives here, in the Kit, so it is testable:
        /// the app-side mirror that used to inline this comparison sits in a target with no tests.
        public func supersedes(_ other: Snapshot) -> Bool {
            version >= other.version
        }

        /// Monotonic, assigned under the lock at every mutation.
        ///
        /// Every mutator captures the snapshot under the lock and delivers it AFTER unlocking, so
        /// delivery order is not mutation order: a thread can be preempted between unlocking and
        /// delivering, and a newer snapshot can be observed first. The older one then lands last
        /// and sticks. With a 20-wide evaluation task group that is not theoretical, and the
        /// consequence is a meter frozen above zero and a worker reading "waiting on security"
        /// until some unrelated mutation happens to correct it. Observers compare this and drop
        /// anything older than what they already hold.
        public internal(set) var version: UInt64 = 0

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
        public var securityEvaluationsByCall: Set<SecurityEvaluationKey> = []

        /// How many real LLM-backed evaluations are in flight. Derived — never set.
        public var securityEvaluations: Int { securityEvaluationsByCall.count }

        /// Whether this agent is blocked waiting on a verdict for one of its calls. Derived.
        public func isAwaitingSecurity(agentInstanceID: UUID) -> Bool {
            securityEvaluationsByCall.contains { $0.agentInstanceID == agentInstanceID }
        }

        /// Whether this agent's call is the one under review. Derived. The agent is required
        /// because a bare call id is not unique across sessions — see `SecurityEvaluationKey`.
        public func isEvaluating(callID: String, agentInstanceID: UUID) -> Bool {
            securityEvaluationsByCall.contains(SecurityEvaluationKey(agentInstanceID: agentInstanceID, callID: callID))
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
        snapshot.version &+= 1
        let snap = snapshot
        let handler = onChange
        lock.unlock()
        handler?(snap)
    }

    /// Registers a tool call as being evaluated by the Security Agent's LLM. Pair with
    /// `endSecurityEvaluation` in a `defer` — a stranded entry reads as an agent blocked forever.
    public func beginSecurityEvaluation(callID: String, agentInstanceID: UUID) {
        // An empty id is not a usable key: the provider guard only rejects a MISSING id, so an
        // empty string reaches here, and every empty-id call across the app would share one entry.
        // Logged rather than dropped quietly — when this fires the agent IS blocked on a real
        // evaluation and the meter will under-count, and nobody would otherwise ever learn that a
        // provider is emitting empty tool-call ids.
        guard !callID.isEmpty else {
            Self.logger.error("Security evaluation not registered: provider emitted an empty tool call id (agent \(agentInstanceID.uuidString, privacy: .public)). The Security meter will under-count this call.")
            return
        }
        lock.lock()
        snapshot.securityEvaluationsByCall.insert(SecurityEvaluationKey(agentInstanceID: agentInstanceID, callID: callID))
        snapshot.version &+= 1
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
        let remaining = snapshot.securityEvaluationsByCall.filter { $0.agentInstanceID != agentInstanceID }
        guard remaining.count != snapshot.securityEvaluationsByCall.count else {
            lock.unlock()
            return
        }
        snapshot.securityEvaluationsByCall = remaining
        snapshot.version &+= 1
        let snap = snapshot
        let handler = onChange
        lock.unlock()
        handler?(snap)
    }

    /// Clears a call's evaluation. Idempotent — clearing one that isn't registered is a no-op, so
    /// a duplicated `defer` can't corrupt the state the way an unbalanced counter could.
    public func endSecurityEvaluation(callID: String, agentInstanceID: UUID) {
        let key = SecurityEvaluationKey(agentInstanceID: agentInstanceID, callID: callID)
        lock.lock()
        // Nothing to remove means nothing to publish. Firing `onChange` regardless made every
        // idempotent double-end cost a main-actor hop and a full inspector recompute.
        guard snapshot.securityEvaluationsByCall.remove(key) != nil else {
            lock.unlock()
            return
        }
        snapshot.version &+= 1
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
        snapshot.version &+= 1
        let snap = snapshot
        let handler = onChange
        lock.unlock()
        handler?(snap)
    }
}
