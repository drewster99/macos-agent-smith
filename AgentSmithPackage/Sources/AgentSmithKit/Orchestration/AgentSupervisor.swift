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
        /// Registration order within the supervisor's lifetime — the tiebreaker for
        /// "oldest worker" decisions (dictionary iteration order is unspecified).
        let sequence: UInt64
        /// The task this worker was spawned for (workers are 1:1 with tasks). Nil for
        /// non-worker roles and for legacy spawn paths that assign via the task store
        /// after the fact — task-scoped lookups must check `assigneeIDs` as well.
        let taskID: UUID?
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
    private var nextSequence: UInt64 = 1

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
        evaluator: SecurityEvaluator? = nil,
        taskID: UUID? = nil
    ) -> AgentHandle? {
        guard let generation = currentGeneration else { return nil }
        // Single-agent-per-role invariant for NON-WORKER roles: `firstHandle(role:)`
        // picks arbitrarily if two same-role agents ever coexist, so a break here means
        // silent wrong-agent selection downstream (start guards on smith == nil).
        // Brown is exempt — workers are a pool, 1:1 with tasks, bounded by the runtime's
        // capacity check in `performSpawnBrown`; worker lookups go through
        // `handles(role:)` / task scoping, never `firstHandle`.
        assert(role == .brown || firstHandle(role: role) == nil,
               "second \(role.rawValue) registered while one is live — single-agent-per-role invariant broken")
        let handle = AgentHandle(
            id: id,
            role: role,
            epoch: generation.epoch,
            sequence: nextSequence,
            taskID: taskID,
            agent: agent,
            evaluator: evaluator
        )
        nextSequence += 1
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

    /// The current agent for a SINGLE-INSTANCE role (smith, summarizer, securityAgent).
    /// Brown is a pool — worker callers must use `handles(role:)` or a task-scoped
    /// lookup; at worker capacity 1 this still returns the lone Brown, which is why
    /// legacy single-worker call sites (message_brown, digests) remain correct until the
    /// M3 capacity-aware pass migrates them.
    func firstHandle(role: AgentRole) -> AgentHandle? {
        handles(role: role).first
    }

    /// All live agents of a role, oldest registration first.
    func handles(role: AgentRole) -> [AgentHandle] {
        handlesByID.values.filter { $0.role == role }.sorted { $0.sequence < $1.sequence }
    }

    /// The worker spawned for (or later assigned to) `taskID`, per the handle's own
    /// task binding. Legacy spawn-then-assign paths don't stamp the handle — callers
    /// needing full coverage must also consult the task's `assigneeIDs`.
    func workerHandle(taskID: UUID) -> AgentHandle? {
        handles(role: .brown).first { $0.taskID == taskID }
    }

    func agent(id: UUID) -> AgentActor? {
        handlesByID[id]?.agent
    }

    func role(of id: UUID) -> AgentRole? {
        handlesByID[id]?.role
    }

    var count: Int { handlesByID.count }
}
