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

    /// Maximum number of turn records kept per role. Oldest are dropped when exceeded.
    private static let maxTurnRecords = 100

    /// Only the most recent N turns per role retain their full contextSnapshot.
    private static let recentSnapshotWindow = 10

    /// Live conversation history for each agent, pushed on every material change.
    var liveContexts: [AgentRole: [LLMMessage]] = [:]

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
    func appendTurn(_ turn: LLMTurnRecord, for role: AgentRole) {
        var turns = turnsByRole[role] ?? []
        turns.append(turn)
        turnsByRole[role] = turns
        pruneOldTurnSnapshots(for: role)
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
    func updateLiveContext(_ messages: [LLMMessage], for role: AgentRole) {
        liveContexts[role] = messages
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
        liveContexts.removeAll()
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
