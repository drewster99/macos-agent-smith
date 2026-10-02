import Foundation
import Testing
@testable import AgentSmithKit

/// The `.awaitingReview` park as the status writer owns it: its reason is derived from the cause in
/// the same write and cleared on every exit; a task gated on the user's acceptance completes only on
/// that acceptance; and who may resolve a park is re-checked inside the store's CAS.
@Suite("User-acceptance parks")
struct UserAcceptanceParkTests {

    /// A task in `.validating` with one criterion and a result — gated on the user's acceptance unless
    /// told otherwise, and with an ACCEPT already on the ledger unless told otherwise.
    private func validatingTask(_ store: TaskStore, gated: Bool = true, settled: Bool = true) async throws -> (AgentTask, AcceptanceCriterion) {
        let task = await store.addTask(title: "Gated", description: "d")
        let criterion = AcceptanceCriterion(name: "works", validationPrompt: "it works", origin: .user)
        await store.setAcceptanceCriteria(id: task.id, criteria: [criterion])
        if gated {
            #expect(await store.setRequiresUserAcceptance(id: task.id, value: true, by: .smith) == nil)
        }
        await store.setResult(id: task.id, result: "done", commentary: nil, attachments: [])
        #expect(await store.driveStatus(id: task.id, to: .validating))
        if settled {
            let token = try #require(await store.beginValidationRound(id: task.id))
            _ = await store.recordCriterionVerdicts(id: task.id, records: [
                CriterionVerdictRecord(criterionID: criterion.id, verdict: .accepted, validatorName: "default", validatorHash: "h", round: token.round)
            ], judgedAgainst: [criterion], judgedInRound: token)
        }
        return (try #require(await store.task(id: task.id)), criterion)
    }

    private func park(_ store: TaskStore, _ id: UUID, _ reason: AgentTask.AwaitingReviewReason) async -> Bool {
        await store.updateStatus(id: id, to: .awaitingReview, ifCurrentlyIn: [.validating], cause: reason.parkingCause)
    }

    // MARK: - The reason mapping

    @Test("Every reason parks through a cause that maps back to it")
    func parkingCauseRoundTrips() {
        for reason in AgentTask.AwaitingReviewReason.allCases {
            #expect(reason.parkingCause.awaitingReviewPark == .review(reason))
            #expect(reason.parkingCause.permits(from: .validating, to: .awaitingReview))
            #expect(!reason.parkingCause.permits(from: .running, to: .awaitingReview))
        }
        #expect(TaskTransitionCause.validationBlocked.awaitingReviewPark == .validationBlocked)
        #expect(TaskTransitionCause.userAccepted.awaitingReviewPark == nil)
    }

    @Test("A grant and an override both complete only from a park; validation passing only from validating")
    func acceptanceMatrix() {
        for cause in [TaskTransitionCause.userAccepted, .userAcceptanceGranted(validationWasRun: true), .userAcceptanceGranted(validationWasRun: false)] {
            #expect(cause.permits(from: .awaitingReview, to: .completed))
            #expect(!cause.permits(from: .validating, to: .completed))
            #expect(cause.isUsersAcceptanceOfResult)
        }
        #expect(TaskTransitionCause.validationPassed(validationWasRun: true).permits(from: .validating, to: .completed))
        #expect(!TaskTransitionCause.validationPassed(validationWasRun: true).permits(from: .awaitingReview, to: .completed))
        #expect(!TaskTransitionCause.validationPassed(validationWasRun: true).isUsersAcceptanceOfResult)
    }

    @Test("An unknown reason written by a newer build reads as a validator error, and the task still decodes")
    func unknownReasonDecodesFailClosed() throws {
        let decoded = try JSONDecoder().decode(AgentTask.AwaitingReviewReason.self, from: Data(#""someFutureReason""#.utf8))
        #expect(decoded == .validatorError)
        var task = AgentTask(title: "t", description: "d")
        task.awaitingReviewReason = .userAcceptanceRequested
        let json = String(decoding: try JSONEncoder().encode(task), as: UTF8.self)
            .replacingOccurrences(of: #""userAcceptanceRequested""#, with: #""someFutureReason""#)
        let restored = try JSONDecoder().decode(AgentTask.self, from: Data(json.utf8))
        #expect(restored.awaitingReviewReason == .validatorError)
    }

    // MARK: - One writer for the reason

    @Test("A sign-off park writes its reason and Smith's note in the same write as the status")
    func signOffParkWrittenAtomically() async throws {
        let store = TaskStore()
        let (task, _) = try await validatingTask(store)
        #expect(await park(store, task.id, .userAcceptanceRequested))
        let parked = try #require(await store.task(id: task.id))
        #expect(parked.awaitingReviewReason == .userAcceptanceRequested)
        #expect(parked.isParkedForUserAcceptance)
        #expect(parked.isAwaitingOnlyUserSignOff)
        let briefing = parked.pendingEffects.first { $0.transition.statusRevision == parked.statusRevision }
        guard case .smithBriefing(let note)? = briefing?.effect else {
            Issue.record("a sign-off park must brief Smith")
            return
        }
        #expect(note.contains("SIGN-OFF"))
        #expect(briefing?.transition.cause == .userAcceptanceRequested(validationWasRun: true))
    }

    @Test("A validator-error park is not briefed, and is not a sign-off park")
    func validatorErrorParkIsUnbriefed() async throws {
        let store = TaskStore()
        let (task, _) = try await validatingTask(store, gated: false, settled: false)
        #expect(await park(store, task.id, .validatorError))
        let parked = try #require(await store.task(id: task.id))
        #expect(parked.awaitingReviewReason == .validatorError)
        #expect(!parked.isParkedForUserAcceptance)
        #expect(!parked.pendingEffects.contains { $0.transition.statusRevision == parked.statusRevision },
                "Smith is not briefed on a park only the user resolves")
    }

    @Test("Leaving a park clears its reason")
    func exitClearsReason() async throws {
        let store = TaskStore()
        let (task, _) = try await validatingTask(store)
        #expect(await park(store, task.id, .userAcceptanceRequested))
        #expect(await store.updateStatus(id: task.id, status: .validating, cause: .userRevalidated))
        #expect(await store.task(id: task.id)?.awaitingReviewReason == nil)
    }

    @Test("A config park carries no reason, needs its marker, and loses the marker on any exit")
    func configParkMarkerLifecycle() async throws {
        let store = TaskStore()
        let (task, _) = try await validatingTask(store, gated: false, settled: false)
        #expect(await store.updateStatus(id: task.id, status: .awaitingReview, cause: .validationBlocked) == false,
                "a config park without its marker is refused")
        #expect(await store.blockValidation(id: task.id, reason: "no validator model"))
        let blocked = try #require(await store.task(id: task.id))
        #expect(blocked.awaitingReviewReason == nil)
        #expect(blocked.validationBlockedReason != nil)
        #expect(!blocked.admitsEscalationResolution(by: .user))
        #expect(await store.updateStatus(id: task.id, status: .interrupted, cause: .capacityShed))
        #expect(await store.task(id: task.id)?.validationBlockedReason == nil, "a stale marker would make a later park look config-blocked")
    }

    @Test("Restore scrubs park markers from a task that is no longer parked")
    func restoreScrubsStaleMarkers() async {
        var stale = AgentTask(title: "t", description: "d")
        stale.status = .pending
        stale.awaitingReviewReason = .userAcceptanceRequested
        stale.validationBlockedReason = "old"
        let store = TaskStore()
        await store.restore([stale])
        let restored = await store.task(id: stale.id)
        #expect(restored?.awaitingReviewReason == nil)
        #expect(restored?.validationBlockedReason == nil)
    }

    // MARK: - The gate

    @Test("A gated task completes only on the user's acceptance")
    func gatedCompletionRefused() async throws {
        let store = TaskStore()
        let (gated, _) = try await validatingTask(store)
        #expect(await store.updateStatus(id: gated.id, status: .completed, cause: .validationPassed(validationWasRun: true)) == false)
        #expect(await store.updateStatus(id: gated.id, status: .completed, cause: .smithSetStatus) == false)
        #expect(await store.task(id: gated.id)?.status == .validating)
        let (ungated, _) = try await validatingTask(store, gated: false)
        #expect(await store.updateStatus(id: ungated.id, status: .completed, cause: .validationPassed(validationWasRun: true)))
    }

    @Test("An Accept must record the cause its park implies")
    func acceptCauseMustMatchPark() async throws {
        let store = TaskStore()
        let (signOff, _) = try await validatingTask(store)
        #expect(await park(store, signOff.id, .userAcceptanceRequested))
        #expect(await store.task(id: signOff.id)?.acceptanceResolutionCause == .userAcceptanceGranted(validationWasRun: true))
        #expect(await store.updateStatus(id: signOff.id, status: .completed, cause: .userAccepted) == false, "a grant is not an override")
        #expect(await store.updateStatus(id: signOff.id, status: .completed, cause: .userAcceptanceGranted(validationWasRun: true)))

        let (escalated, _) = try await validatingTask(store, gated: false, settled: false)
        #expect(await park(store, escalated.id, .validatorError))
        #expect(await store.updateStatus(id: escalated.id, status: .completed, cause: .userAcceptanceGranted(validationWasRun: true)) == false)
        #expect(await store.updateStatus(id: escalated.id, status: .completed, cause: .userAccepted))
    }

    // MARK: - Who may resolve, inside the CAS

    @Test("Smith's relay can never resolve a validator-error park — checked inside the store's CAS")
    func relayRefusedOnValidatorErrorParkInsideCAS() async throws {
        let store = TaskStore()
        let (task, _) = try await validatingTask(store, gated: false, settled: false)
        #expect(await park(store, task.id, .validatorError))
        #expect(await store.updateStatus(id: task.id, to: .completed, ifCurrentlyIn: [.awaitingReview],
                                         ifResolvableBy: .smithRelayingUser, cause: .userAccepted) == false)
        #expect(await store.acceptAwaitingReviewHoldingEffects(id: task.id, resolvedBy: .smithRelayingUser) == nil)
        #expect(await store.task(id: task.id)?.status == .awaitingReview)
        let accepted = await store.acceptAwaitingReviewHoldingEffects(id: task.id, resolvedBy: .user)
        #expect(accepted?.cause == .userAccepted)
        #expect(await store.task(id: task.id)?.status == .completed)
    }

    @Test("A criterion added after the park makes Accept an override and refuses Smith's relay")
    func contractChangeAfterParkEndsSignOffOnly() async throws {
        let store = TaskStore()
        let (task, _) = try await validatingTask(store)
        #expect(await park(store, task.id, .userAcceptanceRequested))
        #expect(await store.applyCriterionActions(taskID: task.id, actions: [
            .add(name: "also this", validationPrompt: "check it", inputEnumeratorPrompt: nil, waivable: false, origin: .smith)
        ]) == nil)
        let changed = try #require(await store.task(id: task.id))
        #expect(changed.isParkedForUserAcceptance)
        #expect(!changed.isAwaitingOnlyUserSignOff)
        #expect(changed.acceptanceResolutionCause == .userAccepted)
        #expect(!changed.admitsEscalationResolution(by: .smithRelayingUser))
        #expect(changed.admitsEscalationResolution(by: .user))
    }

    @Test("Only a validator-error (or pre-reason) review park re-validates at launch")
    func revalidatesAtLaunchTruthTable() async throws {
        let store = TaskStore()
        let (signOff, _) = try await validatingTask(store)
        #expect(await park(store, signOff.id, .userAcceptanceRequested))
        #expect(await store.task(id: signOff.id)?.revalidatesAtLaunch == false)

        let (escalated, _) = try await validatingTask(store, gated: false, settled: false)
        #expect(await park(store, escalated.id, .validatorError))
        #expect(await store.task(id: escalated.id)?.revalidatesAtLaunch == true)

        let (blocked, _) = try await validatingTask(store, gated: false, settled: false)
        #expect(await store.blockValidation(id: blocked.id, reason: "no model"))
        #expect(await store.task(id: blocked.id)?.revalidatesAtLaunch == false)

        var legacy = AgentTask(title: "legacy", description: "d")
        legacy.status = .awaitingReview
        legacy.result = "r"
        #expect(legacy.revalidatesAtLaunch, "a park persisted before reasons existed was always a validator error")
        legacy.status = .pending
        #expect(!legacy.revalidatesAtLaunch)
    }

    // MARK: - Launch, watches, outcome

    @Test("The cold-launch note lists sign-off parks and says which were never judged")
    func launchInstructionListsSignOffParks() async throws {
        let store = TaskStore()
        let (passed, _) = try await validatingTask(store)
        #expect(await park(store, passed.id, .userAcceptanceRequested))
        let (skipped, _) = try await validatingTask(store, settled: false)
        #expect(await park(store, skipped.id, .userAcceptanceRequestedValidationSkipped))
        let tasks = await [store.task(id: passed.id), store.task(id: skipped.id)].compactMap { $0 }
        let note = OrchestrationRuntime.userAcceptanceParkInstruction(for: tasks)
        #expect(note.contains(passed.id.uuidString) && note.contains(skipped.id.uuidString))
        #expect(note.contains("passed validation"))
        #expect(note.contains("NOT judged"))
        #expect(note.contains("respond_to_user_acceptance"))
    }

    @Test("A sign-off park fires 'needs review', and its notification says what it is waiting for")
    func watchesTellParksApart() {
        let signOff = TaskStatusTransition(taskID: UUID(), statusRevision: 2, from: .validating, to: .awaitingReview,
                                           at: Date(), cause: .userAcceptanceRequested(validationWasRun: true))
        let escalation = TaskStatusTransition(taskID: UUID(), statusRevision: 2, from: .validating, to: .awaitingReview,
                                              at: Date(), cause: .validationEscalated)
        let blocked = TaskStatusTransition(taskID: UUID(), statusRevision: 2, from: .validating, to: .awaitingReview,
                                           at: Date(), cause: .validationBlocked)
        #expect(TaskWatchTrigger(transition: signOff) == .needsReview)
        #expect(TaskWatchTrigger(transition: escalation) == .needsReview)
        #expect(TaskWatchTrigger(transition: blocked) == nil)
        let task = AgentTask(title: "t", description: "d")
        let signOffText = TaskWatchDelivery.bannerBody(task: task, firing: TaskWatchFiring(occurrence: 1, trigger: .needsReview, transition: signOff))
        let escalationText = TaskWatchDelivery.bannerBody(task: task, firing: TaskWatchFiring(occurrence: 1, trigger: .needsReview, transition: escalation))
        #expect(signOffText.contains("sign-off"))
        #expect(escalationText.contains("could not reach a verdict"))
    }
}
