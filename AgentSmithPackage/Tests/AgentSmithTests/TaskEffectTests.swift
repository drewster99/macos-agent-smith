import Testing
import Foundation
@testable import AgentSmithKit

/// Transition effects: recorded in the same write as the status, held until their writer releases
/// them, delivered only once durable, and dropped when the task leaves the active store.
@Suite("Task transition effects")
struct TaskEffectTests {

    private func startedTask(_ store: TaskStore) async -> AgentTask {
        let task = await store.addTask(title: "Build it", description: "d")
        await store.updateStatus(id: task.id, status: .starting, cause: .startClaimed)
        return task
    }

    @Test("A briefed transition records its effect on the task in the same write")
    func effectRecordedWithStatus() async throws {
        let store = TaskStore()
        let task = await startedTask(store)
        #expect(await store.updateStatus(id: task.id, status: .running, cause: .workerStarted))
        let stored = try #require(await store.task(id: task.id))
        let record = try #require(stored.pendingEffects.first)
        #expect(stored.pendingEffects.count == 1)
        #expect(record.transition.statusRevision == stored.statusRevision)
        #expect(record.id == "\(task.id.uuidString)|\(stored.statusRevision)|smithBriefing")
        #expect(record.release == .released)
        guard case .smithBriefing(let note) = record.effect else { Issue.record("expected a briefing"); return }
        #expect(note.contains("has been started"))
        #expect(await store.readyEffects().map(\.record.id) == [record.id])
    }

    @Test("An unbriefed transition records nothing")
    func unbriefedTransitionRecordsNothing() async {
        let store = TaskStore()
        let task = await startedTask(store)
        #expect(await store.task(id: task.id)?.pendingEffects.isEmpty == true, "a start claim is not briefed")
    }

    @Test("A held effect is not ready until its writer releases it")
    func heldUntilReleased() async throws {
        let store = TaskStore()
        let task = await startedTask(store)
        let ticket = try #require(await store.updateStatusHoldingEffects(id: task.id, to: .running, ifCurrentlyIn: [.starting], cause: .workerStarted))
        #expect(await store.readyEffects().isEmpty)
        #expect(await store.task(id: task.id)?.pendingEffects.first?.release == .held)
        await store.releaseEffects(ticket)
        #expect(await store.readyEffects().count == 1)
        await store.releaseEffects(ticket)   // idempotent
        #expect(await store.readyEffects().count == 1)
    }

    @Test("A held effect its writer never releases is released by the watchdog")
    func watchdogReleasesForgottenEffect() async throws {
        let store = TaskStore()
        await store.setHeldEffectReleaseDeadline(.milliseconds(50))
        let task = await startedTask(store)
        _ = try #require(await store.updateStatusHoldingEffects(id: task.id, to: .running, ifCurrentlyIn: [.starting], cause: .workerStarted))
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await store.readyEffects().isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await store.readyEffects().count == 1)
    }

    @Test("A refused holding write returns no ticket and records nothing")
    func refusedHoldingWrite() async {
        let store = TaskStore()
        let task = await store.addTask(title: "t", description: "d")
        #expect(await store.updateStatusHoldingEffects(id: task.id, to: .running, ifCurrentlyIn: [.starting], cause: .workerStarted) == nil)
        #expect(await store.task(id: task.id)?.pendingEffects.isEmpty == true)
    }

    @Test("A delivered effect is removed from its task")
    func completeRemovesEffect() async throws {
        let store = TaskStore()
        let task = await startedTask(store)
        await store.updateStatus(id: task.id, status: .running, cause: .workerStarted)
        let ready = try #require(await store.readyEffects().first)
        await store.completeEffect(taskID: ready.taskID, recordID: ready.record.id)
        #expect(await store.readyEffects().isEmpty)
        #expect(await store.task(id: task.id)?.pendingEffects.isEmpty == true)
    }

    @Test("Effects held when the app died are released at launch")
    func heldEffectsReleasedAtLaunch() async throws {
        let store = TaskStore()
        let task = await startedTask(store)
        _ = try #require(await store.updateStatusHoldingEffects(id: task.id, to: .running, ifCurrentlyIn: [.starting], cause: .workerStarted))
        let persisted = try #require(await store.task(id: task.id))

        let relaunched = TaskStore()
        await relaunched.restore([persisted])
        #expect(await relaunched.readyEffects().isEmpty)
        await relaunched.reconcileAfterLaunch()
        // The running task is also recovered to interrupted; its original briefing is still due.
        #expect(await relaunched.readyEffects().map(\.record.transition.cause).contains(.workerStarted))
    }

    @Test("Archiving a task drops its undelivered effects")
    func archiveDropsEffects() async throws {
        let inactive = InactiveTaskStore()
        let store = TaskStore(inactiveStore: inactive)
        await store.setDurablePersistHooks(inactive: { true })
        let task = await store.addTask(title: "t", description: "d")
        await store.driveStatus(id: task.id, to: .failed)
        await store.updateStatus(id: task.id, status: .pending, cause: .resetForRun)
        await store.updateStatus(id: task.id, status: .starting, cause: .startClaimed)
        await store.updateStatus(id: task.id, status: .failed, cause: .spawnFailed)
        #expect(await store.readyEffects().count == 1)
        #expect(await store.archive(id: task.id))
        #expect(await inactive.task(id: task.id)?.pendingEffects.isEmpty == true)
    }

    @Test("An effect is not delivered while its write is not durable")
    func durabilityGatesDelivery() async throws {
        actor FailingDisk {
            var failing = true
            func setFailing(_ value: Bool) { failing = value }
            func save(_ snapshot: [AgentTask]) throws {
                if failing { throw CocoaError(.fileWriteNoPermission) }
            }
        }
        let disk = FailingDisk()
        let store = TaskStore()
        await store.attachPersistence(save: { try await disk.save($0) }, writeNow: false)
        let task = await startedTask(store)
        await store.updateStatus(id: task.id, status: .running, cause: .workerStarted)
        let ready = try #require(await store.readyEffects().first)
        #expect(await store.awaitDurable(through: ready.durableThrough) == false)
        await disk.setFailing(false)
        #expect(await store.persistDurablyNow())
        #expect(await store.awaitDurable(through: ready.durableThrough))
    }

    @Test("Effect records round-trip through AgentTask's Codable")
    func effectsPersist() async throws {
        let store = TaskStore()
        let task = await startedTask(store)
        _ = await store.updateStatusHoldingEffects(id: task.id, to: .running, ifCurrentlyIn: [.starting], cause: .workerStarted)
        let stored = try #require(await store.task(id: task.id))
        let decoded = try JSONDecoder().decode(AgentTask.self, from: JSONEncoder().encode(stored))
        #expect(decoded.pendingEffects == stored.pendingEffects)
        #expect(decoded.statusRevision == stored.statusRevision)
    }
}

/// The notes Smith receives: same set of transitions, same text as before the briefing moved.
@Suite("Smith task briefing")
struct SmithTaskBriefingTests {
    private let task = AgentTask(title: "Ship it", description: "d")

    private func transition(_ cause: TaskTransitionCause, to: AgentTask.Status = .running) -> TaskStatusTransition {
        TaskStatusTransition(taskID: task.id, statusRevision: 1, from: .starting, to: to, at: Date(), cause: cause)
    }

    @Test("Briefed causes produce their note")
    func briefedCauses() throws {
        let started = try #require(SmithTaskBriefing.note(for: transition(.workerStarted), task: task))
        #expect(started.hasPrefix("[System: Task \"Ship it\" (ID: \(task.id.uuidString)) has been started."))
        let failed = try #require(SmithTaskBriefing.note(for: transition(.spawnFailed, to: .failed), task: task))
        #expect(failed.contains("could not be started"))
        let passed = try #require(SmithTaskBriefing.note(for: transition(.validationPassed(validationWasRun: true), to: .completed), task: task))
        #expect(passed.contains("passed acceptance validation and is COMPLETE"))
        let unjudged = try #require(SmithTaskBriefing.note(for: transition(.validationPassed(validationWasRun: false), to: .completed), task: task))
        #expect(unjudged.contains("criteria were NOT judged"))
        let noProgress = try #require(SmithTaskBriefing.note(
            for: transition(.validationFailedNoProgress(roundsWithoutNewApprovals: 8, stillRejected: 2), to: .failed), task: task))
        #expect(noProgress.contains("No acceptance criterion was newly approved for 8 validation rounds in a row — 2 criterion(s) still rejected."))
    }

    @Test("A user's Accept is not reported as passing validation")
    func userAcceptIsHonest() throws {
        let accepted = try #require(SmithTaskBriefing.note(for: transition(.userAccepted, to: .completed), task: task))
        #expect(!accepted.contains("passed acceptance validation"))
        #expect(accepted.contains("the user accepted it"))
    }

    @Test("Starts and failures while the runtime itself starts are left to Smith's initial instruction")
    func runtimeStartCausesAreSilent() {
        #expect(SmithTaskBriefing.note(for: transition(.workerStartedAtRuntimeStart), task: task) == nil)
        #expect(SmithTaskBriefing.note(for: transition(.spawnFailedAtRuntimeStart, to: .failed), task: task) == nil)
    }

    @Test("Transitions Smith was never told about stay unbriefed")
    func unbriefedCauses() {
        let silent: [TaskTransitionCause] = [
            .startClaimed, .startAbandoned, .workerAcknowledged, .submittedForValidation, .validationEscalated,
            .validationBlocked, .validationReleased, .rejectionsReturned, .helpRequested, .helpProvided,
            .userPaused, .userStopped, .userFailed, .userRevalidated, .userSentBack, .capacityShed,
            .scheduledAction(.pause), .scheduledTimeReached, .workerSelfTerminated, .smithTerminatedWorker,
            .smithSetStatus, .orphanRecovered, .resetForRun, .reopenedForRun, .templateLauncherNormalized,
            .coldBootRecovery(.interrupt), .coldBootSpawnAbandoned, .coldBootRevalidate, .sessionShutdown, .sessionDeletion
        ]
        for cause in silent {
            #expect(SmithTaskBriefing.note(for: transition(cause), task: task) == nil, "\(cause)")
        }
    }
}
