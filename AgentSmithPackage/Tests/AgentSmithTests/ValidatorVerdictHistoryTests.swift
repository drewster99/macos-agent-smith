import Testing
import Foundation
@testable import AgentSmithKit

/// The Validator inspector's projection of task verdict ledgers: it must group and label records
/// without changing, dropping, or re-truncating any of them.
@Suite("ValidatorVerdictHistory")
struct ValidatorVerdictHistoryTests {

    private func record(
        _ criterionID: UUID,
        round: Int,
        at seconds: TimeInterval,
        verdict: CriterionVerdictRecord.Verdict = .accepted,
        input: String? = nil
    ) -> CriterionVerdictRecord {
        CriterionVerdictRecord(
            criterionID: criterionID,
            verdict: verdict,
            validatorName: "default",
            validatorHash: "abc123",
            round: round,
            recordedAt: Date(timeIntervalSince1970: seconds),
            renderedInput: input
        )
    }

    @Test("groups by task, orders by criterion, round, then time, and keeps records verbatim")
    func groupsAndOrders() {
        let first = AcceptanceCriterion(name: "tests pass", origin: .user)
        let second = AcceptanceCriterion(name: "docs updated", origin: .user)
        let capped = "evidence…\n…[truncated 42 chars]"
        let records = [
            record(second.id, round: 1, at: 10, verdict: .rejected(reason: "missing")),
            record(first.id, round: 2, at: 30),
            record(first.id, round: 1, at: 20, verdict: .error(message: "timeout"), input: capped),
            record(second.id, round: 2, at: 40, verdict: .waived(reason: "n/a")),
        ]
        var task = AgentTask(title: "Build", description: "d")
        task.acceptanceCriteria = [first, second]
        task.validation = TaskValidationState(round: 2, verdictRecords: records)

        let groups = ValidatorVerdictHistory.groups(from: [task])
        #expect(groups.count == 1)
        let entries = groups[0].entries
        #expect(entries.map(\.criterionNumber) == [1, 1, 2, 2])
        #expect(entries.map(\.record.round) == [1, 2, 1, 2])
        #expect(entries.map(\.criterionName) == ["tests pass", "tests pass", "docs updated", "docs updated"])
        let byID = { (list: [CriterionVerdictRecord]) in list.sorted { $0.id.uuidString < $1.id.uuidString } }
        #expect(byID(entries.map(\.record)) == byID(records), "projection must not alter or drop any record")
        #expect(entries[0].record.renderedInput == capped, "the coordinator's truncation marker stays visible")
        #expect(groups[0].latestRecordedAt == Date(timeIntervalSince1970: 40))
    }

    @Test("a criterion removed from the contract keeps its verdicts, labelled as removed")
    func removedCriterionKeepsVerdicts() {
        let kept = AcceptanceCriterion(name: "kept", origin: .user)
        let removedID = UUID()
        var task = AgentTask(title: "T", description: "d")
        task.acceptanceCriteria = [kept]
        task.validation = TaskValidationState(round: 1, verdictRecords: [
            record(removedID, round: 1, at: 1),
            record(kept.id, round: 1, at: 2),
        ])
        let entries = ValidatorVerdictHistory.groups(from: [task])[0].entries
        #expect(entries.map(\.criterionID) == [kept.id, removedID])
        #expect(entries[1].criterionNumber == nil)
        #expect(entries[1].criterionName == nil)
    }

    @Test("tasks without verdicts are omitted; groups list the most recently judged first")
    func taskOrdering() {
        let criterion = AcceptanceCriterion(name: "c", origin: .user)
        var older = AgentTask(title: "older", description: "d")
        older.acceptanceCriteria = [criterion]
        older.validation = TaskValidationState(round: 1, verdictRecords: [record(criterion.id, round: 1, at: 5)])
        var newer = AgentTask(title: "newer", description: "d")
        newer.acceptanceCriteria = [criterion]
        newer.validation = TaskValidationState(round: 1, verdictRecords: [record(criterion.id, round: 1, at: 50)])
        var emptyLedger = AgentTask(title: "empty", description: "d")
        emptyLedger.validation = TaskValidationState(round: 1)
        let unjudged = AgentTask(title: "unjudged", description: "d")

        let titles = ValidatorVerdictHistory.groups(from: [older, emptyLedger, unjudged, newer]).map(\.taskTitle)
        #expect(titles == ["newer", "older"])
    }

    @Test("a Re-validate that restarts round numbering does not interleave the two runs")
    func separateRunsDoNotInterleave() {
        let criterion = AcceptanceCriterion(name: "c", origin: .user)
        var task = AgentTask(title: "T", description: "d")
        task.acceptanceCriteria = [criterion]
        // Run A: rounds 1 and 2. Run B (after Re-validate zeroed the round): round 1 again.
        task.validation = TaskValidationState(round: 1, verdictRecords: [
            record(criterion.id, round: 1, at: 10, verdict: .rejected(reason: "a1")),
            record(criterion.id, round: 2, at: 20, verdict: .rejected(reason: "a2")),
            record(criterion.id, round: 1, at: 30),
        ])
        let times = ValidatorVerdictHistory.groups(from: [task])[0].entries.map(\.record.recordedAt.timeIntervalSince1970)
        #expect(times == [10, 20, 30])
    }
}
