import Foundation

/// The single owner of agent-lifecycle state for an `OrchestrationRuntime`.
///
/// ## Why a struct confined to the runtime actor, not a second actor
///
/// The 2026-07-08 zombie-agent incident was caused by lifecycle state scattered across
/// seven parallel registries (`agents`, `agentRoles`, `agentSubscriptions`,
/// `securityEvaluators`, `smith`, `smithID`, `currentBrownID`) that had to be mutated in
/// lockstep across suspension points. Interleaved teardowns could observe — and create —
/// half-registered agents: tracked in some registries, missing from others, and in the
/// worst case erased from tracking while still running.
///
/// The fix is a single value type that the runtime owns and mutates **synchronously**.
/// Putting this in a separate actor would reintroduce the disease it cures: every
/// registry read/write would become an `await`, i.e. a fresh interleaving point. Inside
/// the runtime's isolation domain, every mutation here is atomic with respect to the
/// runtime's other state, and a half-registered agent is unrepresentable: an agent is
/// registered exactly when its `AgentHandle` — which carries the actor, role, epoch,
/// evaluator, and channel subscriptions as one value — is present in `handlesByID`.
///
/// ## Generations and epochs
///
/// A **generation** is one contiguous run of the agent cast, begun by
/// `beginGeneration()` (in `start()`) and ended by `endGeneration()` (in `stopAll()`).
/// Each generation carries a monotonically increasing `epoch` and the run's `sessionID`
/// (stamped on every `UsageRecord` and `ChannelMessage`). Every handle records the epoch
/// it was registered under. Because agent IDs are fresh UUIDs, handle presence already
/// implies epoch currency — the stored epoch exists for observability and for
/// whole-generation assertions, not as a separate fence.
struct AgentSupervisor {

    /// Everything the runtime knows about one live agent, as a single value.
    /// Registration and removal move the whole handle at once — there is no path that
    /// updates "the role map" without "the agent map" because there is only the handle.
    struct AgentHandle {
        let id: UUID
        let role: AgentRole
        /// The generation epoch this agent was registered under.
        let epoch: UInt64
        let agent: AgentActor
        /// The per-Brown security evaluator, owned by the handle so teardown can archive
        /// its history without consulting a side table.
        var evaluator: SecurityEvaluator?
        /// Channel subscription IDs to unsubscribe on teardown. Owned by the handle so a
        /// teardown can never stop an agent yet leave it subscribed (the zombie shape).
        var subscriptionIDs: [UUID] = []
    }

    /// One contiguous run of the agent cast.
    struct AgentGeneration {
        let epoch: UInt64
        let sessionID: UUID
        let startedAt: Date
    }

    private(set) var currentGeneration: AgentGeneration?
    private(set) var handlesByID: [UUID: AgentHandle] = [:]
    private var nextEpoch: UInt64 = 1

    /// Starts a new generation and returns it. Any handles still registered belong to the
    /// previous generation and should have been removed by `endGeneration()` first — the
    /// runtime's lifecycle queue guarantees that ordering.
    mutating func beginGeneration(sessionID: UUID = UUID()) -> AgentGeneration {
        let generation = AgentGeneration(epoch: nextEpoch, sessionID: sessionID, startedAt: Date())
        nextEpoch += 1
        currentGeneration = generation
        return generation
    }

    /// Ends the current generation, removing and returning EVERY registered handle in one
    /// synchronous step (the clear-first teardown discipline: nothing can be
    /// tracked-then-lost across a suspension point, because the caller holds the only
    /// remaining references).
    mutating func endGeneration() -> [AgentHandle] {
        let handles = Array(handlesByID.values)
        handlesByID.removeAll()
        currentGeneration = nil
        return handles
    }

    /// Registers an agent under the current generation and returns its handle. Returns
    /// nil when no generation is active — a spawn attempt on a stopped runtime must fail
    /// cleanly rather than create an untracked (and therefore unkillable) agent.
    @discardableResult
    mutating func register(
        id: UUID,
        role: AgentRole,
        agent: AgentActor,
        evaluator: SecurityEvaluator? = nil
    ) -> AgentHandle? {
        guard let generation = currentGeneration else { return nil }
        let handle = AgentHandle(id: id, role: role, epoch: generation.epoch, agent: agent, evaluator: evaluator)
        handlesByID[id] = handle
        return handle
    }

    /// Removes and returns the handle for `id`, or nil if it isn't registered. Synchronous
    /// single-step removal: after this returns, no other flow can observe the agent as
    /// live, and the caller owns everything needed for teardown (agent, evaluator,
    /// subscriptions).
    mutating func remove(id: UUID) -> AgentHandle? {
        handlesByID.removeValue(forKey: id)
    }

    /// Records a channel subscription on an already-registered agent's handle.
    mutating func addSubscription(_ subscriptionID: UUID, to id: UUID) {
        handlesByID[id]?.subscriptionIDs.append(subscriptionID)
    }

    /// Attaches (or replaces) the security evaluator on an already-registered handle.
    mutating func setEvaluator(_ evaluator: SecurityEvaluator?, for id: UUID) {
        handlesByID[id]?.evaluator = evaluator
    }

    // MARK: - Queries

    /// The liveness lease: true while this exact agent is tracked as current. Agent IDs
    /// are per-spawn UUIDs, so presence is equivalent to an (id, epoch) fence.
    func isCurrent(_ id: UUID) -> Bool {
        handlesByID[id] != nil
    }

    func handle(id: UUID) -> AgentHandle? {
        handlesByID[id]
    }

    /// The current agent for a role. The runtime maintains a single-agent-per-role
    /// invariant today; if that ever relaxes (worker pools), callers of this must migrate
    /// to `handles(role:)`.
    func firstHandle(role: AgentRole) -> AgentHandle? {
        handlesByID.values.first { $0.role == role }
    }

    func agent(id: UUID) -> AgentActor? {
        handlesByID[id]?.agent
    }

    func role(of id: UUID) -> AgentRole? {
        handlesByID[id]?.role
    }

    var count: Int { handlesByID.count }
}
