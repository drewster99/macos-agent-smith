import Testing
import Foundation
import SemanticSearch
import SwiftLLMKit
@testable import AgentSmithKit

/// Failure injection for task state events: each crash point between a status write and its
/// effect's outcome, and persistence failures, recover or surface — never lose silently.
@Suite("Task events — crash recovery and persistence failure", .serialized)
struct TaskEventsCrashRecoveryTests {

    private func waitUntil(timeout: Duration = .seconds(15), _ predicate: @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return await predicate()
    }

    private func makeRuntime() async -> OrchestrationRuntime {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-smith-task-events-recovery", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let configuration = ModelConfiguration(name: "test", providerID: "test", modelID: "test-model")
        let runtime = OrchestrationRuntime(
            providers: [
                .smith: MockLLMProvider(responses: [LLMResponse(text: "Standing by.")]),
                .securityAgent: MockLLMProvider(responses: [LLMResponse(text: "SAFE")]),
                .brown: MockLLMProvider(responses: [LLMResponse(text: "Working.")])
            ],
            configurations: [.smith: configuration, .securityAgent: configuration, .brown: configuration],
            providerAPITypes: [:],
            agentTuning: [
                .brown: AgentTuningConfig(pollInterval: 3600),
                .smith: AgentTuningConfig(pollInterval: 3600),
                .securityAgent: AgentTuningConfig(pollInterval: 3600)
            ],
            semanticSearchEngine: SemanticSearchEngine(),
            usageStore: UsageStore(persistence: PersistenceManager(testingRoot: tmpRoot)),
            autoAdvanceEnabled: false,
            autoRunInterruptedTasks: false,
            memoryStore: nil
        )
        await runtime.setOrchestrationSettings(OrchestrationSettings.builtIn.applying(OrchestrationSettingsOverride(
            autoRunNextTask: false, autoRunInterruptedTasks: false, scopeToolSetOnTaskStart: false
        )))
        return runtime
    }

    private func smithSaw(_ runtime: OrchestrationRuntime, _ text: String) async -> Bool {
        await runtime.contextSnapshot(for: .smith)?.contains { $0.content.textValue?.contains(text) == true } == true
    }

    @Test("Crash after the status write, before delivery: the briefing on disk is delivered at the next launch")
    func undeliveredBriefingSurvivesCrash() async throws {
        var task = AgentTask(title: "Recovered", description: "d")
        task.status = .completed
        task.statusRevision = 3
        let transition = TaskStatusTransition(
            taskID: task.id, statusRevision: 3, from: .validating, to: .completed, at: Date(),
            cause: .validationPassed(validationWasRun: true)
        )
        // Held: the writer died before releasing it.
        task.pendingEffects = [TaskEffectRecord(transition: transition, effect: .smithBriefing(note: "[System: RECOVERED NOTE]"), release: .held)]

        let runtime = await makeRuntime()
        let store = await runtime.taskStore
        await store.restore([task])
        await runtime.start()
        let delivered = await waitUntil { await smithSaw(runtime, "RECOVERED NOTE") }
        #expect(delivered)
        let taskID = task.id
        let cleared = await waitUntil { await store.task(id: taskID)?.pendingEffects.isEmpty == true }
        #expect(cleared, "a delivered effect is removed from the task")
        await runtime.stopAll()
    }

    @Test("Crash after the broker settled a firing, before the task recorded it: launch adopts the ledger's outcome")
    func inFlightFiringAdoptsLedger() async throws {
        var watch = TaskWatch(triggers: [.completed], action: .macOSNotification, createdBy: .user)
        var task = AgentTask(title: "Notified", description: "d")
        task.status = .completed
        let transition = TaskStatusTransition(taskID: task.id, statusRevision: 1, from: .running, to: .completed, at: Date(), cause: .smithSetStatus)
        let occurrence = watch.recordFiring(trigger: .completed, transition: transition)
        watch.setFiringState(occurrence: occurrence, .inFlight)
        task.watches = [watch]
        let deliveredAt = Date(timeIntervalSince1970: 1_000)
        let watchID = watch.id
        let taskID = task.id

        let runtime = await makeRuntime()
        await runtime.setDeliveryLedgerPersistence(
            load: { [TaskWatchDelivery.notificationID(watchID: watchID, occurrence: occurrence): .delivered(deliveredAt)] },
            persist: { _ in }
        )
        let store = await runtime.taskStore
        await store.restore([task])
        await runtime.start()
        let adopted = await waitUntil {
            await store.task(id: taskID)?.watch(id: watchID)?.firing(occurrence: occurrence)?.state == .delivered(at: deliveredAt)
        }
        #expect(adopted)
        await runtime.stopAll()
    }

    @Test("A notification queue that can't be saved is reported to the user")
    func outboxSaveFailureSurfaced() async throws {
        let runtime = await makeRuntime()
        await runtime.setPendingDeliveryPersistence(
            load: { [] },
            persist: { _ in throw CocoaError(.fileWriteNoPermission) }
        )
        await runtime.start()
        let store = await runtime.taskStore
        let task = await store.addTask(title: "T", description: "d")
        #expect(await store.addWatch(TaskWatch(triggers: [.interrupted], action: .instructSmith("x"), createdBy: .user), to: task.id) == nil)
        await store.updateStatus(id: task.id, status: .interrupted, cause: .smithSetStatus)
        let reported = await waitUntil {
            await runtime.channel.allMessages().contains {
                $0.severity == .error && $0.content.contains("Couldn't save the queue of notifications waiting for Smith")
            }
        }
        #expect(reported)
        await runtime.stopAll()
    }

    @Test("A notification queue that can't be read is reported, and is not overwritten")
    func outboxLoadFailureSurfacedAndPreserved() async throws {
        let runtime = await makeRuntime()
        let writes = WriteCounter()
        await runtime.setPendingDeliveryPersistence(
            load: { throw CocoaError(.fileReadCorruptFile) },
            persist: { _ in await writes.bump() }
        )
        await runtime.start()
        let store = await runtime.taskStore
        let task = await store.addTask(title: "T", description: "d")
        #expect(await store.addWatch(TaskWatch(triggers: [.interrupted], action: .instructSmith("x"), createdBy: .user), to: task.id) == nil)
        await store.updateStatus(id: task.id, status: .interrupted, cause: .smithSetStatus)
        let reported = await waitUntil {
            await runtime.channel.allMessages().contains {
                $0.severity == .error && $0.content.contains("Couldn't read the queue of notifications waiting for Smith")
            }
        }
        #expect(reported)
        let reachedSmith = await waitUntil { await smithSaw(runtime, "Carry them out now") }
        #expect(reachedSmith, "delivery still works this launch, in memory")
        #expect(await writes.count == 0, "the unreadable file is never overwritten")
        await runtime.stopAll()
    }

    @Test("A start target that left the session before the watch fired is refused visibly")
    func targetMovedOutIsRefused() async throws {
        let runtime = await makeRuntime()
        await runtime.start()
        let store = await runtime.taskStore
        let upstream = await store.addTask(title: "A", description: "d")
        let downstream = await store.addTask(title: "B", description: "d")
        let watch = TaskWatch(triggers: [.completed], action: .startTask(taskID: downstream.id), createdBy: .user)
        #expect(await store.addWatch(watch, to: upstream.id) == nil)
        #expect(await store.archive(id: downstream.id))
        await store.updateStatus(id: upstream.id, status: .completed, cause: .smithSetStatus)
        let refused = await waitUntil {
            if case .refused(let reason) = await store.task(id: upstream.id)?.watch(id: watch.id)?.firing(occurrence: 1)?.state {
                return reason.contains("no longer an active task")
            }
            return false
        }
        #expect(refused)
        await runtime.stopAll()
    }

    private actor WriteCounter {
        private(set) var count = 0
        func bump() { count += 1 }
    }
}
