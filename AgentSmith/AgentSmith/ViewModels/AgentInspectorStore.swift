import SwiftUI
import AgentSmithKit
import SwiftLLMKit

/// Holds inspector state for all agents, updated incrementally via push callbacks.
///
/// Completely decoupled from `AppViewModel` so that inspector data changes
/// never invalidate MainView.body, ChannelLogView, or UserInputView.
@Observable
@MainActor
final class AgentInspectorStore {
    /// Per-turn LLM call records, pushed incrementally as each turn completes.
    /// Old turns beyond `recentSnapshotWindow` have their contextSnapshot stripped
    /// to prevent O(n^2) memory growth on long sessions.
    var turnsByRole: [AgentRole: [LLMTurnRecord]] = [:]

    /// Per-INSTANCE turn records (the M2 re-key): keyed by `AgentInstanceRef` so concurrent
    /// workers of the same role stay distinct. Populated alongside `turnsByRole`, which
    /// remains the role-collapsed view the current inspector cards read.
    var turnsByInstance: [AgentInstanceRef: [LLMTurnRecord]] = [:]

    /// Maximum number of turn records kept per role. Oldest are dropped when exceeded.
    private static let maxTurnRecords = 100

    /// Only the most recent N turns per role retain their full contextSnapshot.
    private static let recentSnapshotWindow = 10

    /// Live conversation history for each agent, pushed on every material change.
    var liveContexts: [AgentRole: [LLMMessage]] = [:]

    /// Per-INSTANCE live context, keyed by `AgentInstanceRef`; populated alongside
    /// `liveContexts` (the role-collapsed view the current cards read).
    var liveContextsByInstance: [AgentInstanceRef: [LLMMessage]] = [:]

    /// Bounds the per-instance maps: a long run cycles through many worker instances, and
    /// without this both instance maps would grow without limit (the role-keyed maps are
    /// bounded per-role). LRU by last touch; the least-recently-updated instance is evicted.
    private var instanceTouchOrder: [AgentInstanceRef] = []
    private static let maxTrackedInstances = 32

    /// Security evaluation records from Security Agent/SecurityEvaluator.
    var evaluationRecords: [EvaluationRecord] = []

    // MARK: - Push API (called from runtime callbacks)

    /// Appends a newly completed LLM turn for the given agent role.
    ///
    /// Reassigns through the dictionary key rather than mutating in place via
    /// `[key, default: []].append(...)`. The Observation framework's per-property
    /// change tracking on @Observable types reliably fires on subscript-assignment
    /// (`dict[key] = newValue`) but not always on chained mutating-method calls
    /// through a default subscript, so SwiftUI views observing `turnsByRole`
    /// would otherwise miss appends and never re-render the LLM Turns section.
    func appendTurn(_ turn: LLMTurnRecord, for ref: AgentInstanceRef) {
        var turns = turnsByRole[ref.role] ?? []
        turns.append(turn)
        turnsByRole[ref.role] = turns
        pruneOldTurnSnapshots(for: ref.role)

        // Per-instance mirror (the re-key), bounded so a long run with many workers can't
        // grow it without limit: capped per instance, LRU-evicted by instance count (see
        // touchInstance), and each stored copy has its heavy contextSnapshot stripped — the
        // live context is available via liveContextsByInstance.
        var lightweight = turn
        lightweight.stripContextSnapshot()
        var instanceTurns = turnsByInstance[ref] ?? []
        instanceTurns.append(lightweight)
        if instanceTurns.count > Self.maxTurnRecords {
            instanceTurns.removeFirst(instanceTurns.count - Self.maxTurnRecords)
        }
        turnsByInstance[ref] = instanceTurns
        touchInstance(ref)
    }

    /// Records the most-recent touch for `ref` and evicts the least-recently-updated
    /// instance's heavy data once the tracked-instance cap is exceeded.
    private func touchInstance(_ ref: AgentInstanceRef) {
        if let existing = instanceTouchOrder.firstIndex(of: ref) {
            instanceTouchOrder.remove(at: existing)
        }
        instanceTouchOrder.append(ref)
        while instanceTouchOrder.count > Self.maxTrackedInstances {
            let evicted = instanceTouchOrder.removeFirst()
            turnsByInstance[evicted] = nil
            liveContextsByInstance[evicted] = nil
        }
    }

    /// Caps turn record count and strips contextSnapshot from older turns for a given role.
    private func pruneOldTurnSnapshots(for role: AgentRole) {
        guard var turns = turnsByRole[role] else { return }
        var modified = false

        // Drop oldest records when exceeding the hard cap.
        if turns.count > Self.maxTurnRecords {
            turns.removeFirst(turns.count - Self.maxTurnRecords)
            modified = true
        }

        // Strip heavy snapshots from turns outside the recent window.
        let stripCount = turns.count - Self.recentSnapshotWindow
        if stripCount > 0 {
            for i in 0..<stripCount where !turns[i].contextSnapshot.isEmpty {
                turns[i].stripContextSnapshot()
                modified = true
            }
        }

        if modified {
            turnsByRole[role] = turns
        }
    }

    /// Updates the live conversation history for the given agent role.
    func updateLiveContext(_ messages: [LLMMessage], for ref: AgentInstanceRef) {
        liveContexts[ref.role] = messages
        liveContextsByInstance[ref] = messages
        touchInstance(ref)
    }

    /// Appends a newly completed security evaluation record.
    func appendEvaluation(_ record: EvaluationRecord) {
        evaluationRecords.append(record)
    }

    /// Number of evaluations that ended in a non-cancelled denial — UNSAFE/ABORT
    /// outright, plus WARN denials that were not subsequently auto-approved on
    /// retry. These are the rows a user would care to look at; auto-approvals
    /// after a WARN retry collapse to a single non-flagged record so the chip
    /// doesn't misleadingly inflate.
    var flaggedEvaluationCount: Int {
        evaluationRecords.reduce(0) { count, record in
            let d = record.disposition
            if d.isCancelled { return count }
            if d.isAutoApproval { return count }
            return d.approved ? count : count + 1
        }
    }

    /// Clears all data for a specific agent role (e.g. when agent is replaced).
    func clear(for role: AgentRole) {
        turnsByRole[role] = nil
        liveContexts[role] = nil
    }

    /// Clears all inspector data (e.g. on full stop/reset).
    func clearAll() {
        turnsByRole.removeAll()
        turnsByInstance.removeAll()
        liveContexts.removeAll()
        liveContextsByInstance.removeAll()
        instanceTouchOrder.removeAll()
        evaluationRecords.removeAll()
    }

    // MARK: - Derived accessors

    /// Returns the live conversation history for a role, falling back to the latest turn snapshot.
    func contextMessages(for role: AgentRole) -> [LLMMessage] {
        liveContexts[role] ?? turnsByRole[role]?.last?.contextSnapshot ?? []
    }

    /// Extracts the current system prompt for a role from its context.
    func systemPrompt(for role: AgentRole) -> String {
        contextMessages(for: role)
            .first { $0.role == .system }
            .flatMap { $0.content.textValue } ?? ""
    }
}
