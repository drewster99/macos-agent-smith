import Foundation
import Testing
@testable import AgentSmithKit

/// The validation data model: criteria, steps with tombstones, and the verdict ledger.

@Suite("Task validation model")
struct TaskValidationModelTests {

    @Test("updateStatus(ifCurrentlyIn:) is an atomic compare-and-set that won't clobber a paused task")
    func conditionalStatusCAS() async {
        let store = TaskStore()
        let t = await store.addTask(title: "t", description: "d")
        await store.updateStatus(id: t.id, status: .validating)

        // Applies while the status is still what validation expects.
        let applied = await store.updateStatus(id: t.id, to: .completed, ifCurrentlyIn: [.validating])
        #expect(applied)
        #expect(await store.task(id: t.id)?.status == .completed)

        // Refuses once the task has moved on — the guarantee that a pause/stop landing
        // mid-validation is never overwritten by a late validation transition.
        await store.updateStatus(id: t.id, status: .paused)
        let refused = await store.updateStatus(id: t.id, to: .awaitingReview, ifCurrentlyIn: [.validating])
        #expect(!refused)
        #expect(await store.task(id: t.id)?.status == .paused, "a non-validating task is not clobbered")
    }

    @Test("A legacy task JSON (no criteria/steps/validation) still decodes")
    func legacyTaskDecodes() throws {
        let task = AgentTask(title: "t", description: "d")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as! [String: Any]
        json.removeValue(forKey: "acceptanceCriteria")
        json.removeValue(forKey: "steps")
        json.removeValue(forKey: "validation")
        let decoded = try JSONDecoder().decode(AgentTask.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.acceptanceCriteria.isEmpty)
        #expect(decoded.steps.isEmpty)
        #expect(decoded.validation == nil)
    }

    @Test("Criteria with inline and registry validators round-trip")
    func criteriaRoundTrip() throws {
        let inline = EvaluatorDefinition(
            name: "inline-check", description: "d", kind: .validator,
            systemPrompt: "judge",
            outputGrammar: .verdictLine(allowed: [.init(token: "ACCEPT", requiresReason: false)]),
            modelSlot: .summarizer
        )
        var task = AgentTask(title: "t", description: "d")
        task.acceptanceCriteria = [
            AcceptanceCriterion(text: "tests pass", origin: .user, validator: .registry("default")),
            AcceptanceCriterion(text: "a11y ok", waivable: true, origin: .smith, validator: .inline(inline))
        ]
        let decoded = try JSONDecoder().decode(AgentTask.self, from: JSONEncoder().encode(task))
        #expect(decoded.acceptanceCriteria == task.acceptanceCriteria)
    }

    @Test("Step removal is a tombstone requiring a note; tombstones can't be edited")
    func stepTombstones() async {
        let store = TaskStore()
        let task = await store.addTask(title: "t", description: "d")
        await store.setSteps(id: task.id, steps: [TaskStep(text: "review code", origin: .smith)])
        let stepID = await store.task(id: task.id)!.steps[0].id

        // Removal without a note is refused.
        let refused = await store.applyStepAction(taskID: task.id, action: .setStatus(stepID: stepID, status: .removed, note: "  "))
        #expect(refused != nil)

        // Removal with a note tombstones — still present, inactive.
        let removed = await store.applyStepAction(taskID: task.id, action: .setStatus(stepID: stepID, status: .removed, note: "superseded by issue list"))
        #expect(removed == nil)
        let afterRemoval = await store.task(id: task.id)!.steps[0]
        #expect(afterRemoval.status == .removed)
        #expect(afterRemoval.isActive == false)

        // A tombstoned step is immutable.
        let editRefused = await store.applyStepAction(taskID: task.id, action: .update(stepID: stepID, newText: "rewrite history"))
        #expect(editRefused != nil)
    }

    @Test("Sticky accepts: settled criteria survive rounds; editing a criterion resets it")
    func stickyAcceptsAndEditReset() async {
        let store = TaskStore()
        var criterionA = AcceptanceCriterion(text: "A", origin: .user)
        let criterionB = AcceptanceCriterion(text: "B", origin: .user)
        let task = await store.addTask(title: "t", description: "d")
        await store.setAcceptanceCriteria(id: task.id, criteria: [criterionA, criterionB])

        _ = await store.beginValidationRound(id: task.id)
        await store.recordCriterionVerdicts(id: task.id, records: [
            CriterionVerdictRecord(criterionID: criterionA.id, verdict: .accepted, validatorName: "d", validatorHash: "h", round: 1),
            CriterionVerdictRecord(criterionID: criterionB.id, verdict: .rejected(reason: "nope"), validatorName: "d", validatorHash: "h", round: 1)
        ], judgedAgainst: [criterionA, criterionB])

        var validation = await store.task(id: task.id)!.validation!
        #expect(validation.settledCriterionIDs() == [criterionA.id])

        // Editing criterion A's text resets its stickiness; B's audit records remain.
        criterionA.text = "A (stricter)"
        await store.setAcceptanceCriteria(id: task.id, criteria: [criterionA, criterionB])
        validation = await store.task(id: task.id)!.validation!
        #expect(validation.settledCriterionIDs().isEmpty)
        #expect(validation.latestVerdict(for: criterionB.id) != nil, "unchanged criterion keeps its audit trail")
    }

    @Test("Latest verdict wins in the ledger")
    func latestVerdictWins() {
        let criterionID = UUID()
        var state = TaskValidationState()
        state.verdictRecords = [
            CriterionVerdictRecord(criterionID: criterionID, verdict: .rejected(reason: "r1"), validatorName: "d", validatorHash: "h", round: 1),
            CriterionVerdictRecord(criterionID: criterionID, verdict: .accepted, validatorName: "d", validatorHash: "h", round: 2)
        ]
        #expect(state.latestVerdict(for: criterionID)?.verdict == .accepted)
        #expect(state.settledCriterionIDs() == [criterionID])
    }
}
