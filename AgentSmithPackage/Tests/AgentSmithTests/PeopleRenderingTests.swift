import Foundation
import Testing
@testable import AgentSmithKit

/// The criteria and step paragraphs the PDF export prints (#27).
@Suite("People-facing task rendering")
struct PeopleRenderingTests {
    @Test("Each criterion reads with its latest verdict — all four kinds — or 'not yet judged'")
    func acceptanceParagraphs() {
        let accepted = AcceptanceCriterion(name: "Builds", origin: .user)
        let rejected = AcceptanceCriterion(name: "Tests pass", origin: .user)
        let waived = AcceptanceCriterion(name: "Docs", origin: .user)
        let errored = AcceptanceCriterion(name: "Lint", origin: .user)
        let unjudged = AcceptanceCriterion(name: "Screenshots", origin: .user)
        func record(_ criterion: AcceptanceCriterion, _ verdict: CriterionVerdictRecord.Verdict) -> CriterionVerdictRecord {
            CriterionVerdictRecord(criterionID: criterion.id, verdict: verdict, validatorName: "v", validatorHash: "h", round: 1)
        }
        var task = AgentTask(title: "t", description: "d", acceptanceCriteria: [accepted, rejected, waived, errored, unjudged])
        task.validation = TaskValidationState(round: 1, verdictRecords: [
            record(accepted, .accepted),
            record(rejected, .rejected(reason: "two failures")),
            record(waived, .waived(reason: "no public API")),
            record(errored, .error(message: "timed out"))
        ])
        #expect(task.acceptanceParagraphsForPeople() == [
            "**Builds** — Accepted",
            "**Tests pass** — Rejected: two failures",
            "**Docs** — Waived: no public API",
            "**Lint** — Error: timed out",
            "**Screenshots** — not yet judged"
        ])
    }

    @Test("Steps read in order with their status; removed steps are left out and don't consume a number")
    func stepParagraphs() {
        let task = AgentTask(title: "t", description: "d", steps: [
            TaskStep(text: "Clone", status: .completed, note: nil, origin: .worker),
            TaskStep(text: "Old idea", status: .removed, note: "not needed", origin: .worker),
            TaskStep(text: "Build", status: .inProgress, note: "warnings left", origin: .worker),
            TaskStep(text: "Ship", status: .pending, note: nil, origin: .smith)
        ])
        #expect(task.activeStepParagraphsForPeople() == [
            "1. Clone *(Done)*",
            "2. Build *(In progress)* — warnings left",
            "3. Ship *(Pending)*"
        ])
        #expect(AgentTask(title: "t", description: "d").activeStepParagraphsForPeople().isEmpty)
    }
}
