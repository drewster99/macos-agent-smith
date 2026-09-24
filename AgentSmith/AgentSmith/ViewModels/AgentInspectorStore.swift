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
    /// Per-role provider-call logs: completed turns and failed attempts, with stable lifetime
    /// ordinals and explicit eviction/snapshot-release facts (see `InspectorCallLog`).
    var callLogsByRole: [AgentRole: InspectorCallLog] = [:]

    /// Per-INSTANCE call logs (the M2 re-key): keyed by `AgentInstanceRef` so concurrent
    /// workers of the same role stay distinct. Populated alongside `callLogsByRole`, which
    /// remains the role-collapsed view the current inspector cards read. Keeps no full context
    /// snapshots — the live context is available via `liveContextsByInstance`.
    var callLogsByInstance: [AgentInstanceRef: InspectorCallLog] = [:]

    /// Maximum number of calls retained per role/instance. Oldest are evicted when exceeded —
    /// visibly, via `InspectorCallLog.evictedCount`.
    static let maxRetainedCalls = 100

    /// Only the most recent N completed turns per role retain their full contextSnapshot, to
    /// prevent O(n^2) memory growth on long sessions.
    static let recentSnapshotWindow = 10

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

    /// Appends one provider call — a completed turn or a failed attempt — for the given agent.
    ///
    /// Reassigns through the dictionary key rather than mutating in place via
    /// `[key, default: ...].append(...)`. The Observation framework's per-property
    /// change tracking on @Observable types reliably fires on subscript-assignment
    /// (`dict[key] = newValue`) but not always on chained mutating-method calls
    /// through a default subscript, so SwiftUI views observing `callLogsByRole`
    /// would otherwise miss appends and never re-render the LLM Turns section.
    func appendCall(_ event: LLMCallEvent, for ref: AgentInstanceRef) {
        var roleLog = callLogsByRole[ref.role] ?? Self.makeRoleLog()
        roleLog.append(event)
        callLogsByRole[ref.role] = roleLog

        var instanceLog = callLogsByInstance[ref]
            ?? InspectorCallLog(capacity: Self.maxRetainedCalls, snapshotWindow: 0)
        instanceLog.append(event)
        callLogsByInstance[ref] = instanceLog
        touchInstance(ref)
    }

    private static func makeRoleLog() -> InspectorCallLog {
        InspectorCallLog(capacity: maxRetainedCalls, snapshotWindow: recentSnapshotWindow)
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
            callLogsByInstance[evicted] = nil
            liveContextsByInstance[evicted] = nil
        }
    }

    /// Updates the live conversation history for the given agent role.
    func updateLiveContext(_ messages: [LLMMessage], for ref: AgentInstanceRef) {
        liveContexts[ref.role] = messages
        liveContextsByInstance[ref] = messages
        touchInstance(ref)
    }

    /// Bounds `evaluationRecords`: one record lands per security-reviewed tool call, each
    /// carrying the full evaluation prompt + LLM response, so an uncapped array costs tens of
    /// MB across a long autonomous run — on the main actor, with `flaggedEvaluationCount`
    /// re-reducing over the whole thing on observation. Double the evaluator's own per-instance
    /// history cap (`SecurityEvaluator.maxHistory`, 100) so the inspector can still show more
    /// than one worker's recent reviews.
    private static let maxEvaluationRecords = 200

    /// Appends a newly completed security evaluation record, evicting oldest-first past the cap.
    func appendEvaluation(_ record: EvaluationRecord) {
        evaluationRecords.append(record)
        if evaluationRecords.count > Self.maxEvaluationRecords {
            evaluationRecords.removeFirst(evaluationRecords.count - Self.maxEvaluationRecords)
        }
    }

    /// Number of evaluations that ended in a non-cancelled denial — UNSAFE/ABORT
    /// outright, plus WARN denials that were not subsequently auto-approved on
    /// retry. These are the rows a user would care to look at; auto-approvals
    /// after a WARN retry collapse to a single non-flagged record so the chip
    /// doesn't misleadingly inflate.
    var flaggedEvaluationCount: Int {
        evaluationRecords.reduce(0) { count, record in
            // Only a real, rendered refusal is a security flag. A cheap auto-approval isn't one,
            // and neither is a block that happened because nobody could judge — counting an outage
            // as a security finding is the same lie one level up from the UNSAFE label.
            switch record.disposition.outcome {
            case .warned, .refused:
                return count + 1
            case .approved, .autoApproved, .approvedWithoutReview, .reviewerUnavailable, .reviewCancelled:
                return count
            }
        }
    }

    /// Calls blocked because no verdict could be reached — an operational fault, tracked apart
    /// from `flaggedEvaluationCount` so a backend outage is visible AS an outage rather than
    /// inflating the security-findings chip.
    var unavailableEvaluationCount: Int {
        evaluationRecords.reduce(0) { count, record in
            if case .reviewerUnavailable = record.disposition.outcome { return count + 1 }
            return count
        }
    }

    /// Clears all data for a specific agent role (e.g. when agent is replaced).
    func clear(for role: AgentRole) {
        callLogsByRole[role] = nil
        liveContexts[role] = nil
    }

    /// Clears all inspector data (e.g. on full stop/reset).
    func clearAll() {
        callLogsByRole.removeAll()
        callLogsByInstance.removeAll()
        liveContexts.removeAll()
        liveContextsByInstance.removeAll()
        instanceTouchOrder.removeAll()
        evaluationRecords.removeAll()
    }

    // MARK: - Derived accessors

    /// Retained completed turns for a role, oldest first.
    func retainedTurns(for role: AgentRole) -> [LLMTurnRecord] {
        callLogsByRole[role]?.retainedTurns ?? []
    }

    /// Returns the live conversation history for a role, falling back to the latest turn snapshot.
    func contextMessages(for role: AgentRole) -> [LLMMessage] {
        liveContexts[role] ?? callLogsByRole[role]?.retainedTurns.last?.contextSnapshot ?? []
    }

    /// Extracts the current system prompt for a role from its context.
    func systemPrompt(for role: AgentRole) -> String {
        contextMessages(for: role)
            .first { $0.role == .system }
            .flatMap { $0.content.textValue } ?? ""
    }
}
