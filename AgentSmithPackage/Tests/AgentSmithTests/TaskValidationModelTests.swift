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

    @Test("Criteria round-trip, and an empty validationPrompt marks the default-validated criterion")
    func criteriaRoundTrip() throws {
        var task = AgentTask(title: "t", description: "d")
        task.acceptanceCriteria = [
            // Custom (prompt-authored).
            AcceptanceCriterion(name: "tests pass", validationPrompt: "Verify the tests pass.", origin: .user),
            // The implicit default-validated shape: empty prompt.
            AcceptanceCriterion(name: "overall acceptance", validationPrompt: "", origin: .system),
            AcceptanceCriterion(name: "a11y ok", waivable: true, origin: .smith)
        ]
        let decoded = try JSONDecoder().decode(AgentTask.self, from: JSONEncoder().encode(task))
        #expect(decoded.acceptanceCriteria == task.acceptanceCriteria)
        #expect(decoded.acceptanceCriteria[0].usesDefaultValidator == false)
        #expect(decoded.acceptanceCriteria[1].usesDefaultValidator == true, "empty prompt → the shipped default judges it")
        #expect(decoded.acceptanceCriteria[2].usesDefaultValidator == false, "prompt defaults to the name, so it's custom")
    }

    @Test("Criteria persist the task-scoped prompt contract and migrate legacy text")
    func criterionPromptContractCoding() throws {
        let criterion = AcceptanceCriterion(
            name: "Three translations",
            validationPrompt: "Verify the supplied translation is complete.",
            inputEnumeratorPrompt: "Return a JSON array of strings containing the translation file paths.",
            origin: .smith
        )
        let encoded = try JSONEncoder().encode(criterion)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["name"] as? String == "Three translations")
        #expect(object["validationPrompt"] as? String == "Verify the supplied translation is complete.")
        #expect(object["inputEnumeratorPrompt"] as? String == "Return a JSON array of strings containing the translation file paths.")
        #expect(object["text"] == nil)

        let legacyJSON = """
        {
          "id": "\(UUID().uuidString)",
          "text": "Legacy criterion",
          "waivable": false,
          "origin": "user"
        }
        """
        let legacy = try JSONDecoder().decode(AcceptanceCriterion.self, from: Data(legacyJSON.utf8))
        #expect(legacy.name == "Legacy criterion")
        #expect(legacy.validationPrompt == "Legacy criterion")
        #expect(legacy.inputEnumeratorPrompt == nil)

        // A legacy criterion carrying the removed `validator`/`prepare` keys still decodes —
        // the keys are ignored, not honored — and re-encodes WITHOUT them.
        let legacyDynamicJSON = """
        {
          "id": "\(UUID().uuidString)",
          "text": "Legacy dynamic criterion",
          "waivable": true,
          "origin": "smith",
          "validator": { "registry": "legacy-validator" },
          "prepare": "legacy-prepare"
        }
        """
        let legacyDynamic = try JSONDecoder().decode(AcceptanceCriterion.self, from: Data(legacyDynamicJSON.utf8))
        #expect(legacyDynamic.name == "Legacy dynamic criterion")
        #expect(legacyDynamic.validationPrompt == "Legacy dynamic criterion")

        let reencoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacyDynamic)) as? [String: Any])
        #expect(reencoded["validator"] == nil, "the removed field is not re-encoded")
        #expect(reencoded["prepare"] == nil, "the removed field is not re-encoded")

        let blankEnumerator = AcceptanceCriterion(
            name: "One check",
            validationPrompt: "Judge the whole result.",
            inputEnumeratorPrompt: "  \n ",
            origin: .smith
        )
        #expect(blankEnumerator.effectiveInputEnumeratorPrompt == nil)
    }

    @Test("Step removal is a tombstone requiring a note; tombstones can't be edited")
    func stepTombstones() async {
        let store = TaskStore()
        let task = await store.addTask(title: "t", description: "d")
        await store.setSteps(id: task.id, steps: [TaskStep(text: "review code", origin: .smith)])
        let stepID = await store.task(id: task.id)!.steps[0].id

        // `set_status` cannot tombstone — `delete` is the single producer of `.removed`.
        let viaStatus = await store.applyStepAction(taskID: task.id, action: .setStatus(stepID: stepID, status: .removed, note: "superseded by issue list"))
        #expect(viaStatus != nil)
        #expect(await store.task(id: task.id)!.steps[0].status == .pending)

        // Removal without a note is refused.
        let refused = await store.applyStepAction(taskID: task.id, action: .delete(stepID: stepID, note: "  "))
        #expect(refused != nil)

        // Removal with a note tombstones — still present, inactive.
        let removed = await store.applyStepAction(taskID: task.id, action: .delete(stepID: stepID, note: "superseded by issue list"))
        #expect(removed == nil)
        let afterRemoval = await store.task(id: task.id)!.steps[0]
        #expect(afterRemoval.status == .removed)
        #expect(afterRemoval.isActive == false)
        #expect(afterRemoval.note == "superseded by issue list")

        // A tombstoned step is immutable.
        let editRefused = await store.applyStepAction(taskID: task.id, action: .update(stepID: stepID, newText: "rewrite history"))
        #expect(editRefused != nil)
        let restatusRefused = await store.applyStepAction(taskID: task.id, action: .setStatus(stepID: stepID, status: .pending, note: nil))
        #expect(restatusRefused != nil)
    }

    @Test("move repositions one step without restating the list; tombstones stay parked at the end")
    func moveRepositionsOneStep() async {
        let store = TaskStore()
        let task = await store.addTask(title: "t", description: "d")
        await store.setSteps(id: task.id, steps: ["a", "b", "c", "d"].map { TaskStep(text: $0, origin: .smith) })
        let ids = await store.task(id: task.id)!.steps.map(\.id)
        func activeTexts() async -> [String] {
            await store.task(id: task.id)!.steps.filter(\.isActive).map(\.text)
        }

        // Tombstone one so the move logic has to skip it.
        #expect(await store.applyStepAction(taskID: task.id, action: .delete(stepID: ids[2], note: "not needed")) == nil)
        #expect(await activeTexts() == ["a", "b", "d"])

        // Moving down: "before"/"after" resolve against the list WITHOUT the moved step, so
        // "a after d" means last, not second-to-last.
        #expect(await store.applyStepAction(taskID: task.id, action: .move(stepID: ids[0], destination: .after(stepID: ids[3]))) == nil)
        #expect(await activeTexts() == ["b", "d", "a"])

        // Moving up.
        #expect(await store.applyStepAction(taskID: task.id, action: .move(stepID: ids[0], destination: .before(stepID: ids[1]))) == nil)
        #expect(await activeTexts() == ["a", "b", "d"])

        // 1-based positions match the numbering the worker is shown.
        #expect(await store.applyStepAction(taskID: task.id, action: .move(stepID: ids[3], destination: .position(1))) == nil)
        #expect(await activeTexts() == ["d", "a", "b"])
        #expect(await store.applyStepAction(taskID: task.id, action: .move(stepID: ids[3], destination: .position(3))) == nil)
        #expect(await activeTexts() == ["a", "b", "d"])

        // The tombstone survives every move and stays off the active list.
        let all = await store.task(id: task.id)!.steps
        #expect(all.count == 4)
        #expect(all.last?.status == .removed)

        // Out-of-range and unknown-anchor moves are refused, not clamped.
        #expect(await store.applyStepAction(taskID: task.id, action: .move(stepID: ids[0], destination: .position(0))) != nil)
        #expect(await store.applyStepAction(taskID: task.id, action: .move(stepID: ids[0], destination: .position(4))) != nil)
        #expect(await store.applyStepAction(taskID: task.id, action: .move(stepID: ids[0], destination: .after(stepID: ids[2]))) != nil, "a tombstone is not a valid anchor")
        #expect(await store.applyStepAction(taskID: task.id, action: .move(stepID: ids[2], destination: .position(1))) != nil, "a tombstone cannot be moved")
        #expect(await activeTexts() == ["a", "b", "d"], "a refused move leaves the list untouched")
    }

    @Test("Retrying a failed task restarts the plan; reopening a completed one keeps it")
    func retryResetsPlanButReopenKeepsIt() async {
        func makeTask(finalStatus: AgentTask.Status) async -> (TaskStore, UUID, [UUID]) {
            let store = TaskStore()
            let task = await store.addTask(title: "t", description: "d")
            await store.setSteps(id: task.id, steps: ["a", "b", "c"].map { TaskStep(text: $0, origin: .smith) })
            let ids = await store.task(id: task.id)!.steps.map(\.id)
            _ = await store.applyStepAction(taskID: task.id, action: .setStatus(stepID: ids[0], status: .completed, note: nil))
            _ = await store.applyStepAction(taskID: task.id, action: .setStatus(stepID: ids[1], status: .skipped, note: "blocked"))
            _ = await store.applyStepAction(taskID: task.id, action: .delete(stepID: ids[2], note: "not needed"))
            await store.setResult(id: task.id, result: "r", commentary: nil, attachments: [])
            await store.updateStatus(id: task.id, status: finalStatus)
            return (store, task.id, ids)
        }

        let (failedStore, failedID, _) = await makeTask(finalStatus: .failed)
        #expect(await failedStore.resetFailedTask(id: failedID))
        let retried = await failedStore.task(id: failedID)!.steps
        #expect(retried[0].status == .pending, "a retry re-runs the whole plan, so nothing starts out done")
        #expect(retried[1].status == .pending)
        #expect(retried[1].note == nil, "the stale skip reason must not survive into the new attempt")
        #expect(retried[2].status == .removed, "a deleted step stays deleted — a retry is not a resurrection")
        #expect(retried[2].note == "not needed")

        let (completedStore, completedID, _) = await makeTask(finalStatus: .completed)
        #expect(await completedStore.reopenCompletedTask(id: completedID))
        let reopened = await completedStore.task(id: completedID)!.steps
        #expect(reopened[0].status == .completed, "reopening means 'finish the remainder', not 'start over'")
        #expect(reopened[1].status == .skipped)
        #expect(reopened[1].note == "blocked")
        #expect(reopened[2].status == .removed)
    }

    @Test("Sticky accepts: settled criteria survive rounds; editing validation instructions resets them")
    func stickyAcceptsAndEditReset() async {
        let store = TaskStore()
        var criterionA = AcceptanceCriterion(name: "A", origin: .user)
        let criterionB = AcceptanceCriterion(name: "B", origin: .user)
        let task = await store.addTask(title: "t", description: "d")
        await store.setAcceptanceCriteria(id: task.id, criteria: [criterionA, criterionB])

        _ = await store.beginValidationRound(id: task.id)
        await store.recordCriterionVerdicts(id: task.id, records: [
            CriterionVerdictRecord(criterionID: criterionA.id, verdict: .accepted, validatorName: "d", validatorHash: "h", round: 1),
            CriterionVerdictRecord(criterionID: criterionB.id, verdict: .rejected(reason: "nope"), validatorName: "d", validatorHash: "h", round: 1)
        ], judgedAgainst: [criterionA, criterionB])

        var validation = await store.task(id: task.id)!.validation!
        #expect(validation.settledCriterionIDs() == [criterionA.id])

        criterionA.name = "A display rename"
        await store.setAcceptanceCriteria(id: task.id, criteria: [criterionA, criterionB])
        validation = await store.task(id: task.id)!.validation!
        #expect(validation.settledCriterionIDs() == [criterionA.id], "display-only rename keeps its settled verdict")

        // Editing criterion A's validation instructions resets its stickiness; B's audit records remain.
        criterionA.validationPrompt = "A (stricter)"
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
