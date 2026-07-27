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

        let token = await store.beginValidationRound(id: task.id)!
        _ = await store.recordCriterionVerdicts(id: task.id, records: [
            CriterionVerdictRecord(criterionID: criterionA.id, verdict: .accepted, validatorName: "d", validatorHash: "h", round: 1),
            CriterionVerdictRecord(criterionID: criterionB.id, verdict: .rejected(reason: "nope"), validatorName: "d", validatorHash: "h", round: 1)
        ], judgedAgainst: [criterionA, criterionB], judgedInRound: token)

        var validation = await store.task(id: task.id)!.validation!
        #expect(validation.settledCriterionIDs(in: [criterionA, criterionB]) == [criterionA.id])

        criterionA.name = "A display rename"
        await store.setAcceptanceCriteria(id: task.id, criteria: [criterionA, criterionB])
        validation = await store.task(id: task.id)!.validation!
        #expect(validation.settledCriterionIDs(in: [criterionA, criterionB]) == [criterionA.id], "display-only rename keeps its settled verdict")

        // Editing criterion A's validation instructions resets its stickiness; B's audit records remain.
        criterionA.validationPrompt = "A (stricter)"
        await store.setAcceptanceCriteria(id: task.id, criteria: [criterionA, criterionB])
        validation = await store.task(id: task.id)!.validation!
        #expect(validation.settledCriterionIDs(in: [criterionA, criterionB]).isEmpty)
        #expect(validation.latestVerdict(for: criterionB.id) != nil, "unchanged criterion keeps its audit trail")
    }

    @Test("update preserves criterion identity — and with it the verdict a replace-all would destroy")
    func criterionUpdatePreservesIdentity() async {
        let store = TaskStore()
        let criterion = AcceptanceCriterion(name: "coverage", validationPrompt: "Reject under 90%.", origin: .smith)
        let task = await store.addTask(title: "t", description: "d")
        await store.setAcceptanceCriteria(id: task.id, criteria: [criterion])
        let token = await store.beginValidationRound(id: task.id)!
        _ = await store.recordCriterionVerdicts(id: task.id, records: [
            CriterionVerdictRecord(criterionID: criterion.id, verdict: .accepted, validatorName: "d", validatorHash: "h", round: 1)
        ], judgedAgainst: [criterion], judgedInRound: token)
        #expect(await store.task(id: task.id)?.validation?.settledCriterionIDs(in: [criterion]) == [criterion.id])

        // A display-only rename through `update`: same id, same question to the judge, so the
        // sticky ACCEPT survives. A wholesale replace would have minted a new UUID and lost it.
        #expect(await store.applyCriterionActions(taskID: task.id, actions: [
            .update(criterionID: criterion.id, name: "code coverage", validationPrompt: "Reject under 90%.", inputEnumeratorPrompt: nil, waivable: false)
        ]) == nil)
        var live = await store.task(id: task.id)!
        #expect(live.acceptanceCriteria[0].id == criterion.id, "update MUST preserve the criterion id")
        #expect(live.acceptanceCriteria[0].name == "code coverage")
        #expect(live.acceptanceCriteria[0].origin == .smith, "origin is not the caller's to rewrite")
        #expect(live.validation?.settledCriterionIDs(in: live.acceptanceCriteria) == [criterion.id], "an unchanged contract keeps its verdict")

        // Moving the bar through the same verb does retire it — identity survives, stickiness doesn't.
        #expect(await store.applyCriterionActions(taskID: task.id, actions: [
            .update(criterionID: criterion.id, name: "code coverage", validationPrompt: "Reject under 60%.", inputEnumeratorPrompt: nil, waivable: false)
        ]) == nil)
        live = await store.task(id: task.id)!
        #expect(live.acceptanceCriteria[0].id == criterion.id)
        #expect(live.validation?.settledCriterionIDs(in: live.acceptanceCriteria).isEmpty == true, "a changed contract is judged fresh")
    }

    @Test("A batch of criterion actions is atomic — a bad action leaves the contract untouched")
    func criterionActionBatchIsAtomic() async {
        let store = TaskStore()
        let first = AcceptanceCriterion(name: "A", validationPrompt: "judge A", origin: .smith)
        let task = await store.addTask(title: "t", description: "d")
        await store.setAcceptanceCriteria(id: task.id, criteria: [first])

        // add succeeds, then delete names an id that isn't there. Neither may land.
        let problem = await store.applyCriterionActions(taskID: task.id, actions: [
            .add(name: "B", validationPrompt: "judge B", inputEnumeratorPrompt: nil, waivable: false, origin: .smith),
            .delete(criterionID: UUID())
        ])
        #expect(problem != nil)
        #expect(await store.task(id: task.id)?.acceptanceCriteria.map(\.name) == ["A"],
                "the successful add must be rolled back with the failed delete — a half-applied contract is unreasonable-about")

        // A duplicate name is refused too: the replace-all path matches by name to preserve identity.
        #expect(await store.applyCriterionActions(taskID: task.id, actions: [
            .add(name: "A", validationPrompt: "judge A differently", inputEnumeratorPrompt: nil, waivable: false, origin: .smith)
        ]) != nil)
        #expect(await store.task(id: task.id)?.acceptanceCriteria.count == 1)

        // The whole batch, all valid, lands at once.
        #expect(await store.applyCriterionActions(taskID: task.id, actions: [
            .add(name: "B", validationPrompt: "judge B", inputEnumeratorPrompt: nil, waivable: false, origin: .smith),
            .add(name: "C", validationPrompt: "judge C", inputEnumeratorPrompt: nil, waivable: true, origin: .smith),
            .delete(criterionID: first.id)
        ]) == nil)
        #expect(await store.task(id: task.id)?.acceptanceCriteria.map(\.name) == ["B", "C"])
    }

    @Test("delete drops the criterion and its verdicts, but never its rejection history")
    func criterionDeleteKeepsRejectionHistory() async {
        let store = TaskStore()
        let criterion = AcceptanceCriterion(name: "A", validationPrompt: "judge A", origin: .smith)
        let task = await store.addTask(title: "t", description: "d")
        await store.setAcceptanceCriteria(id: task.id, criteria: [criterion])
        let token = await store.beginValidationRound(id: task.id)!
        _ = await store.recordCriterionVerdicts(id: task.id, records: [
            CriterionVerdictRecord(criterionID: criterion.id, verdict: .rejected(reason: "not done"), validatorName: "d", validatorHash: "h", round: 1)
        ], judgedAgainst: [criterion], judgedInRound: token)

        #expect(await store.applyCriterionActions(taskID: task.id, actions: [.delete(criterionID: criterion.id)]) == nil)
        let live = await store.task(id: task.id)!
        #expect(live.acceptanceCriteria.isEmpty)
        #expect(live.validation?.verdictRecords.isEmpty == true, "verdicts judged a contract that no longer exists")
        #expect(live.validation?.rejectionHistory.map(\.rejectionText) == ["not done"], "the rejection is task-level and survives")
        #expect(live.validation?.contractVersion == 1, "deleting a criterion versions the contract")
    }

    @Test("A rejection outlives the criterion that earned it, and never counts as one")
    func rejectionHistoryOutlivesItsCriterion() async {
        let store = TaskStore()
        let doomed = AcceptanceCriterion(name: "no TODOs left", validationPrompt: "Reject if any TODO remains.", origin: .smith)
        let kept = AcceptanceCriterion(name: "builds", validationPrompt: "Reject unless it builds.", origin: .smith)
        let task = await store.addTask(title: "t", description: "d")
        await store.setAcceptanceCriteria(id: task.id, criteria: [doomed, kept])

        let token = await store.beginValidationRound(id: task.id)!
        _ = await store.recordCriterionVerdicts(id: task.id, records: [
            CriterionVerdictRecord(criterionID: doomed.id, verdict: .rejected(reason: "3 TODOs in Parser.swift"), validatorName: "d", validatorHash: "h", round: 1),
            CriterionVerdictRecord(criterionID: kept.id, verdict: .accepted, validatorName: "d", validatorHash: "h", round: 1)
        ], judgedAgainst: [doomed, kept], judgedInRound: token)

        let afterRound = await store.task(id: task.id)!.validation!
        #expect(afterRound.rejectionHistory.count == 1, "only the rejection is historied — an accept is not a rejection")
        #expect(afterRound.rejectionHistory(for: doomed.id).first?.rejectionText == "3 TODOs in Parser.swift")
        #expect(afterRound.rejectionHistory(for: doomed.id).first?.name == "no TODOs left", "the name at rejection time")
        #expect(afterRound.rejectionHistory(for: kept.id).isEmpty)

        // Smith responds to the failure the way it always does: drop the criterion that rejected.
        await store.setAcceptanceCriteria(id: task.id, criteria: [kept])
        let afterEdit = await store.task(id: task.id)!.validation!
        #expect(afterEdit.verdictRecords.contains { $0.criterionID == doomed.id } == false, "verdicts for a departed criterion are retired")
        #expect(afterEdit.rejectionHistory.count == 1, "the record of HAVING been rejected survives the criterion")
        #expect(afterEdit.rejectionHistory[0].criterionID == doomed.id)

        // And it stays out of every settled reading — it is not a verdict record and cannot be counted as one.
        #expect(afterEdit.settledCriterionIDs(in: [kept]) == [kept.id])
        #expect(afterEdit.latestVerdict(for: doomed.id) == nil)
    }

    @Test("A weakened criterion is detectable by diffing its rejection against its current text")
    func rejectionHistoryMakesWeakeningDetectable() async {
        let store = TaskStore()
        var criterion = AcceptanceCriterion(name: "coverage", validationPrompt: "Reject unless coverage is at least 90%.", origin: .smith)
        let task = await store.addTask(title: "t", description: "d")
        await store.setAcceptanceCriteria(id: task.id, criteria: [criterion])

        let token = await store.beginValidationRound(id: task.id)!
        _ = await store.recordCriterionVerdicts(id: task.id, records: [
            CriterionVerdictRecord(criterionID: criterion.id, verdict: .rejected(reason: "coverage is 61%"), validatorName: "d", validatorHash: "h", round: 1)
        ], judgedAgainst: [criterion], judgedInRound: token)

        let rejection = await store.task(id: task.id)!.validation!.rejectionHistory[0]
        #expect(rejection.statesSameContract(as: criterion), "unedited, the bar is where it was")

        // The pattern the history exists to expose: lower the bar, keep the ID, retry.
        criterion.validationPrompt = "Reject unless coverage is at least 60%."
        await store.setAcceptanceCriteria(id: task.id, criteria: [criterion])
        let edited = await store.task(id: task.id)!.acceptanceCriteria[0]
        #expect(!rejection.statesSameContract(as: edited), "the criterion no longer asks what it was rejected for")
        #expect(rejection.validationPrompt == "Reject unless coverage is at least 90%.", "the history keeps the bar as it stood")

        // Step three of the same pattern: retry. The retry drops the sticky verdicts on purpose —
        // the history is what remains to show the bar moved between attempts.
        await store.updateStatus(id: task.id, status: .failed)
        #expect(await store.resetFailedTask(id: task.id))
        let afterRetry = await store.task(id: task.id)!.validation!
        #expect(afterRetry.verdictRecords.isEmpty)
        #expect(afterRetry.rejectionHistory == [rejection], "a retry re-runs the work, it does not un-reject the past")
    }

    @Test("A ledger written before the rejection history still decodes, and round-trips once written")
    func rejectionHistoryDecodesForwardCompatibly() throws {
        var task = AgentTask(title: "t", description: "d")
        task.validation = TaskValidationState(round: 2)

        // A ledger from a build that predates the field: the key is simply absent.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as! [String: Any]
        var ledger = json["validation"] as! [String: Any]
        ledger.removeValue(forKey: "criterionRejections")
        json["validation"] = ledger
        let decoded = try JSONDecoder().decode(AgentTask.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.validation?.round == 2)
        #expect(decoded.validation?.rejectionHistory.isEmpty == true, "absent reads as no history, not a decode failure")

        var written = task
        written.validation?.criterionRejections = [
            CriterionRejection(judged: AcceptanceCriterion(name: "n", validationPrompt: "p", origin: .smith),
                               rejectionText: "nope", recordedAt: Date(timeIntervalSince1970: 1))
        ]
        let roundTripped = try JSONDecoder().decode(AgentTask.self, from: JSONEncoder().encode(written))
        #expect(roundTripped.validation?.rejectionHistory == written.validation?.rejectionHistory)
    }

    @Test("A superseded run is told so distinctly — it never reads as 'nothing qualified'")
    func supersededRunIsDistinctFromNothingRecorded() async {
        let store = TaskStore()
        let criterion = AcceptanceCriterion(name: "A", origin: .user)
        let task = await store.addTask(title: "t", description: "d")
        await store.setAcceptanceCriteria(id: task.id, criteria: [criterion])

        let staleToken = await store.beginValidationRound(id: task.id)!   // the run that will go stale
        _ = await store.beginValidationRound(id: task.id)                 // the live run took over

        let stale = await store.recordCriterionVerdicts(id: task.id, records: [
            CriterionVerdictRecord(criterionID: criterion.id, verdict: .error(message: "zombie"), validatorName: "d", validatorHash: "h", round: 1)
        ], judgedAgainst: [criterion], judgedInRound: staleToken)
        #expect(stale == .superseded, "a round the store has moved past must say so, not report an empty write")
        #expect(await store.task(id: task.id)?.validation?.verdictRecords.isEmpty == true)

        // The live run's own write, with every record dropped by the contract-match filter, is the
        // OTHER outcome: it still owns the ledger and must carry on into stall accounting.
        var edited = criterion
        edited.validationPrompt = "A, but stricter"
        await store.setAcceptanceCriteria(id: task.id, criteria: [edited])
        let liveToken = await store.beginValidationRound(id: task.id)!
        let filtered = await store.recordCriterionVerdicts(id: task.id, records: [
            CriterionVerdictRecord(criterionID: criterion.id, verdict: .accepted, validatorName: "d", validatorHash: "h", round: 1)
        ], judgedAgainst: [criterion], judgedInRound: liveToken)
        #expect(filtered == .recorded([]), "an edited-out verdict is a live run recording nothing, not a superseded one")

        // A vanished task (Stop-then-Delete landing while the caller awaited an LLM) is nobody's
        // ledger to write to either.
        let gone = await store.recordCriterionVerdicts(id: UUID(), records: [
            CriterionVerdictRecord(criterionID: criterion.id, verdict: .accepted, validatorName: "d", validatorHash: "h", round: 1)
        ], judgedAgainst: [criterion], judgedInRound: liveToken)
        #expect(gone == .superseded)
    }

    /// The counter-example that `round` alone cannot catch, and the reason `contractVersion` exists:
    /// a criteria edit leaves round numbers that RECUR, so a stale round can match the live one.
    @Test("A criteria edit supersedes an in-flight round even when the round number matches again")
    func contractVersionCatchesAnEditRoundNumbersCannot() async {
        let store = TaskStore()
        let criterion = AcceptanceCriterion(name: "A", validationPrompt: "Reject unless A holds.", origin: .smith)
        let task = await store.addTask(title: "t", description: "d")
        await store.setAcceptanceCriteria(id: task.id, criteria: [criterion])
        await store.updateStatus(id: task.id, status: .validating)

        let inFlight = await store.beginValidationRound(id: task.id)!
        // Authoring the contract before any ledger exists versions nothing — there is no round to
        // supersede. Version 0 is simply "the contract as it stood when it was first judged".
        #expect(inFlight == ValidationRoundToken(round: 1, contractVersion: 0))

        // Smith rewrites the contract while the round is out at the validator. That resets the
        // round counter — and the very next round is numbered 1 again, exactly like the one still
        // in flight. Only the contract version tells them apart.
        var rewritten = criterion
        rewritten.validationPrompt = "Reject unless A holds, but only on Tuesdays."
        await store.setAcceptanceCriteria(id: task.id, criteria: [rewritten])
        let successor = await store.beginValidationRound(id: task.id)!
        #expect(successor.round == inFlight.round, "the round NUMBER is no longer distinguishing")
        #expect(successor.contractVersion > inFlight.contractVersion)

        // Every mutation the in-flight round would make is refused, on the actor that owns the truth.
        let write = await store.recordCriterionVerdicts(id: task.id, records: [
            CriterionVerdictRecord(criterionID: criterion.id, verdict: .rejected(reason: "stale"), validatorName: "d", validatorHash: "h", round: 1)
        ], judgedAgainst: [criterion], judgedInRound: inFlight)
        #expect(write == .superseded)
        #expect(await store.updateValidationStall(id: task.id, progressed: false, judgedInRound: inFlight) == nil,
                "a superseded round must not spend the new contract's convergence budget")
        #expect(await store.updateStatus(id: task.id, to: .failed, ifCurrentlyIn: [.validating], ifValidationRoundIs: inFlight) == false,
                "nor fail the task for not converging on a contract it never judged")
        #expect(await store.task(id: task.id)?.status == .validating)

        // The successor, holding the live token, is refused nothing.
        #expect(await store.updateValidationStall(id: task.id, progressed: false, judgedInRound: successor) == 1)
        #expect(await store.updateStatus(id: task.id, to: .failed, ifCurrentlyIn: [.validating], ifValidationRoundIs: successor))
    }

    @Test("A ledger written before the contract version decodes, and a no-op save doesn't invalidate a live round")
    func contractVersionDecodesForwardCompatibly() async throws {
        var task = AgentTask(title: "t", description: "d")
        task.validation = TaskValidationState(round: 3)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as! [String: Any]
        var ledger = json["validation"] as! [String: Any]
        ledger.removeValue(forKey: "acceptanceContractVersion")
        json["validation"] = ledger
        let decoded = try JSONDecoder().decode(AgentTask.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.validation?.contractVersion == 0, "an unversioned ledger has never seen an edit this build tracked")
        #expect(decoded.validation?.isCurrentRound(ValidationRoundToken(round: 3, contractVersion: 0)) == true,
                "so a round begun on it still matches — old ledgers are not retroactively stale")

        // Saving the criteria unchanged must not move the version: a no-op editor save would
        // otherwise supersede a round that is judging the very contract it just re-saved.
        let store = TaskStore()
        let criterion = AcceptanceCriterion(name: "A", validationPrompt: "p", origin: .smith)
        let live = await store.addTask(title: "t", description: "d")
        await store.setAcceptanceCriteria(id: live.id, criteria: [criterion])
        let token = await store.beginValidationRound(id: live.id)!
        await store.setAcceptanceCriteria(id: live.id, criteria: [criterion])
        #expect(await store.task(id: live.id)?.validation?.isCurrentRound(token) == true)
    }

    /// Pins the round guard AND the deliberate absence of ledger sorting. `resetValidationRound`
    /// zeroes `round` while KEEPING the records (user Re-validate / Send-Back), so round numbers
    /// recur: sorting by `max(round)` would resolve this ledger to the round-2 ERROR and re-escalate
    /// a task on a verdict it already superseded. Array position is the only correct order.
    @Test("r1-REJECT, r2-ERROR, r1-ACCEPT resolves to ACCEPT — recurring round numbers are not an order")
    func recurringRoundNumbersResolveByPosition() async {
        let store = TaskStore()
        let criterion = AcceptanceCriterion(name: "A", origin: .user)
        let task = await store.addTask(title: "t", description: "d")
        await store.setAcceptanceCriteria(id: task.id, criteria: [criterion])

        func record(_ verdict: CriterionVerdictRecord.Verdict, in token: ValidationRoundToken) async -> VerdictRecordingOutcome {
            await store.recordCriterionVerdicts(id: task.id, records: [
                CriterionVerdictRecord(criterionID: criterion.id, verdict: verdict, validatorName: "d", validatorHash: "h", round: token.round)
            ], judgedAgainst: [criterion], judgedInRound: token)
        }

        let first = await store.beginValidationRound(id: task.id)!
        #expect(first.round == 1)
        _ = await record(.rejected(reason: "r1"), in: first)
        let second = await store.beginValidationRound(id: task.id)!
        #expect(second.round == 2)
        _ = await record(.error(message: "r2"), in: second)

        // The user sends it back / re-validates: counters reset, ledger survives, round 1 recurs.
        await store.resetValidationRound(id: task.id)
        let third = await store.beginValidationRound(id: task.id)!
        #expect(third.round == 1, "the round number recurs — which is why it cannot order the ledger")
        _ = await record(.accepted, in: third)

        let ledger = await store.task(id: task.id)?.validation
        #expect(ledger?.verdictRecords.count == 3, "every round is kept — the ledger is the audit trail")
        #expect(ledger?.latestVerdict(for: criterion.id)?.verdict == .accepted)
        #expect(ledger?.settledCriterionIDs(in: [criterion]) == [criterion.id])
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
        #expect(state.settledCriterionIDs(in: [AcceptanceCriterion(id: criterionID, name: "c", origin: .user)]) == [criterionID])
    }
}
