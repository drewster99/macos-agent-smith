import Foundation
import Testing
@testable import AgentSmithKit

/// The derived `AgentTask.outcome` success measure: how the per-criterion verdict ledger and
/// the lifecycle status combine into Success / Pass / Incomplete / Review, and when it correctly
/// yields `nil` (falling back to the lifecycle status chip).
@Suite("Task outcome")
struct TaskOutcomeTests {

    /// Builds a task with `criteria`, a validation ledger giving each criterion its `verdict`
    /// (nil verdict → no record for that criterion), and the given terminal `status`.
    private func makeTask(
        status: AgentTask.Status,
        criteria: [(waivable: Bool, verdict: CriterionVerdictRecord.Verdict?)],
        withLedger: Bool = true
    ) -> AgentTask {
        var task = AgentTask(title: "t", description: "d")
        var acceptance: [AcceptanceCriterion] = []
        var records: [CriterionVerdictRecord] = []
        for entry in criteria {
            let criterion = AcceptanceCriterion(text: "c", waivable: entry.waivable, origin: .user)
            acceptance.append(criterion)
            if let verdict = entry.verdict {
                records.append(CriterionVerdictRecord(
                    criterionID: criterion.id, verdict: verdict,
                    validatorName: "d", validatorHash: "h", round: 1
                ))
            }
        }
        task.acceptanceCriteria = acceptance
        task.validation = withLedger ? TaskValidationState(round: 1, verdictRecords: records) : nil
        task.status = status
        return task
    }

    @Test("All criteria accepted → Success (no fraction)")
    func success() {
        let task = makeTask(status: .completed, criteria: [
            (false, .accepted), (false, .accepted)
        ])
        #expect(task.outcome == .success(total: 2))
        #expect(task.outcome?.fraction == nil)
        #expect(task.outcome?.label == "Success")
    }

    @Test("Completed with a waiver → Pass, fraction counts only strict accepts")
    func passWithWaiver() {
        let task = makeTask(status: .completed, criteria: [
            (false, .accepted), (true, .waived(reason: "n/a"))
        ])
        #expect(task.outcome == .pass(accepted: 1, waived: 1, total: 2))
        #expect(task.outcome?.fraction == "1/2")
        #expect(task.outcome?.label == "Pass")
    }

    @Test("Failed after rejections → Incomplete with accepted-of-total")
    func incomplete() {
        let task = makeTask(status: .failed, criteria: [
            (false, .accepted), (false, .rejected(reason: "no"))
        ])
        #expect(task.outcome == .incomplete(accepted: 1, total: 2))
        #expect(task.outcome?.fraction == "1/2")
    }

    @Test("Escalated with a validator error → Review")
    func needsReview() {
        let task = makeTask(status: .awaitingReview, criteria: [
            (false, .accepted), (false, .error(message: "timeout"))
        ])
        #expect(task.outcome == .needsReview(accepted: 1, total: 2))
        #expect(task.outcome?.label == "Review")
    }

    @Test("No acceptance criteria → nil (falls back to status chip)")
    func nilWhenNoCriteria() {
        let task = makeTask(status: .completed, criteria: [])
        #expect(task.outcome == nil)
    }

    @Test("No validation ledger → nil")
    func nilWhenNoLedger() {
        let task = makeTask(status: .completed, criteria: [(false, nil)], withLedger: false)
        #expect(task.outcome == nil)
    }

    @Test("Completed but ledger inconsistent (a rejection under completed) → nil, no invented grade")
    func nilWhenCompletedButUnsettled() {
        let task = makeTask(status: .completed, criteria: [
            (false, .accepted), (false, .rejected(reason: "stale"))
        ])
        #expect(task.outcome == nil)
    }

    @Test("Failed before any criterion was judged → nil, not a misleading Incomplete 0/N")
    func nilWhenFailedWithNoVerdicts() {
        let task = makeTask(status: .failed, criteria: [(false, nil), (false, nil)])
        #expect(task.outcome == nil)
    }

    @Test("Non-terminal status (running) → nil")
    func nilWhenRunning() {
        let task = makeTask(status: .running, criteria: [(false, .accepted)])
        #expect(task.outcome == nil)
    }
}
