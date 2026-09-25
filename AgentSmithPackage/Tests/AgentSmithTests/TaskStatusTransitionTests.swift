import Testing
import Foundation
import SemanticSearch
import SwiftLLMKit
@testable import AgentSmithKit

/// The status funnel: one writer, one typed event per real change, causes validated against the
/// matrix, compare-and-set results that tell the truth.
@Suite("Task status transitions")
struct TaskStatusTransitionTests {

    /// Collects a store's events in order.
    private final class EventRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [TaskStoreEvent] = []
        func record(_ event: TaskStoreEvent) { lock.withLock { recorded.append(event) } }
        var events: [TaskStoreEvent] { lock.withLock { recorded } }
        var transitions: [TaskStatusTransition] {
            events.compactMap { if case .transition(let transition) = $0 { transition } else { nil } }
        }
        var lifecycle: [TaskLifecycleEvent] {
            events.compactMap { if case .lifecycle(let event) = $0 { event } else { nil } }
        }
    }

    private func observedStore() async -> (TaskStore, EventRecorder) {
        let store = TaskStore()
        let recorder = EventRecorder()
        await store.setEventObserver { recorder.record($0) }
        return (store, recorder)
    }

    @Test("A real change emits exactly one transition carrying the cause, and bumps the revision")
    func realChangeEmitsOnce() async throws {
        let (store, recorder) = await observedStore()
        let task = await store.addTask(title: "t", description: "d")
        #expect(await store.updateStatus(id: task.id, status: .starting, cause: .startClaimed))
        let transition = try #require(recorder.transitions.first)
        #expect(recorder.transitions.count == 1)
        #expect(transition.from == .pending)
        #expect(transition.to == .starting)
        #expect(transition.cause == .startClaimed)
        #expect(transition.statusRevision == 1)
        #expect(await store.task(id: task.id)?.statusRevision == 1)
    }

    @Test("A no-op write emits nothing and reports the task is already there")
    func noOpEmitsNothing() async {
        let (store, recorder) = await observedStore()
        let task = await store.addTask(title: "t", description: "d")
        await store.driveStatus(id: task.id, to: .running)
        let before = recorder.transitions.count
        #expect(await store.updateStatus(id: task.id, status: .running, cause: .workerAcknowledged))
        #expect(recorder.transitions.count == before, "Brown's acknowledgement of a running task is not an event")
    }

    @Test("A cause that does not permit the move is refused, changes nothing, and emits nothing")
    func illegalCauseRefused() async {
        let (store, recorder) = await observedStore()
        let task = await store.addTask(title: "t", description: "d")
        #expect(await store.updateStatus(id: task.id, status: .completed, cause: .workerStarted) == false)
        #expect(await store.task(id: task.id)?.status == .pending)
        #expect(recorder.transitions.isEmpty)
    }

    @Test("The compare-and-set wrappers return false when the write itself is refused")
    func casIsTruthful() async {
        let store = TaskStore()
        let task = await store.addTask(title: "t", description: "d")
        await store.driveStatus(id: task.id, to: .validating)
        // Compare passes (the task IS validating), but `.awaitingReview` needs a stored result.
        #expect(await store.updateStatus(id: task.id, to: .awaitingReview, ifCurrentlyIn: [.validating], cause: .validationEscalated) == false)
        #expect(await store.updateStatus(id: task.id, ifCurrentlyEquals: .validating, to: .completed, cause: .workerStarted) == false)
        #expect(await store.task(id: task.id)?.status == .validating)
    }

    @Test("Restoring persisted tasks is not a live event")
    func restoreIsSilent() async {
        let (store, recorder) = await observedStore()
        var persisted = AgentTask(title: "t", description: "d")
        persisted.status = .completed
        await store.restore([persisted])
        #expect(recorder.events.isEmpty)
    }

    @Test("Events arrive in the order the writes happened")
    func eventsAreOrdered() async {
        let (store, recorder) = await observedStore()
        let task = await store.addTask(title: "t", description: "d")
        await store.updateStatus(id: task.id, status: .starting, cause: .startClaimed)
        await store.updateStatus(id: task.id, status: .running, cause: .workerStarted)
        await store.setResult(id: task.id, result: "done", commentary: nil)
        await store.updateStatus(id: task.id, status: .validating, cause: .submittedForValidation)
        await store.updateStatus(id: task.id, status: .completed, cause: .validationPassed(validationWasRun: true))
        #expect(recorder.transitions.map(\.to) == [.starting, .running, .validating, .completed])
        #expect(recorder.transitions.map(\.statusRevision) == [1, 2, 3, 4])
        #expect(recorder.transitions.last?.entersTerminal == true)
    }

    @Test("Reset and reopen are typed transitions")
    func resetAndReopenEmit() async {
        let (store, recorder) = await observedStore()
        let failed = await store.addTask(title: "f", description: "d")
        await store.driveStatus(id: failed.id, to: .failed)
        let completed = await store.addTask(title: "c", description: "d")
        await store.driveStatus(id: completed.id, to: .completed)
        #expect(await store.resetFailedTask(id: failed.id))
        #expect(await store.reopenCompletedTask(id: completed.id))
        let causes = recorder.transitions.suffix(2).map(\.cause)
        #expect(causes == [.resetForRun, .reopenedForRun])
    }

    @Test("Help, validation park and release are typed transitions")
    func helpAndValidationParkEmit() async {
        let (store, recorder) = await observedStore()
        let task = await store.addTask(title: "t", description: "d")
        await store.driveStatus(id: task.id, to: .running)
        #expect(await store.requestHelp(id: task.id, request: "blocked"))
        #expect(recorder.transitions.last?.cause == .helpRequested)
        await store.updateStatus(id: task.id, status: .running, cause: .helpProvided)
        await store.setResult(id: task.id, result: "done", commentary: nil)
        await store.updateStatus(id: task.id, status: .validating, cause: .submittedForValidation)
        #expect(await store.blockValidation(id: task.id, reason: "no validator"))
        #expect(recorder.transitions.last?.cause == .validationBlocked)
        #expect(await store.releaseValidationBlockedTasks() == [task.id])
        #expect(recorder.transitions.last?.cause == .validationReleased)
    }

    @Test("Launch reconciliation recovers running and starting tasks with typed causes")
    func reconcileAfterLaunch() async {
        var running = AgentTask(title: "running", description: "d")
        running.status = .running
        var submitted = AgentTask(title: "submitted", description: "d")
        submitted.status = .running
        submitted.result = "the work"
        var starting = AgentTask(title: "starting", description: "d")
        starting.status = .starting
        let (store, recorder) = await observedStore()
        await store.restore([running, submitted, starting])
        #expect(await store.reconcileAfterLaunch())
        #expect(await store.task(id: running.id)?.status == .interrupted)
        #expect(await store.task(id: submitted.id)?.status == .validating)
        #expect(await store.task(id: starting.id)?.status == .pending)
        let causes = Set(recorder.transitions.map(\.cause))
        #expect(causes == [.coldBootRecovery(.interrupt), .coldBootRecovery(.resumeValidation), .coldBootSpawnAbandoned])
        #expect(await store.reconcileAfterLaunch() == false, "idempotent")
    }

    @Test("Archive, delete and restore are lifecycle events, not transitions")
    func lifecycleEvents() async {
        let (store, recorder) = await observedStore()
        let a = await store.addTask(title: "a", description: "d")
        let b = await store.addTask(title: "b", description: "d")
        #expect(await store.archive(id: a.id))
        #expect(await store.unarchive(id: a.id))
        #expect(await store.permanentlyDelete(id: b.id))
        #expect(recorder.transitions.isEmpty)
        #expect(recorder.lifecycle == [
            .leftActive(taskID: a.id, disposition: .archived),
            .restoredToActive(taskID: a.id),
            .permanentlyDeleted(taskID: b.id)
        ])
    }

    @Test("The cause matrix: update_task can only set its documented statuses")
    func smithSetStatusMatrix() {
        for from in AgentTask.Status.allCases {
            for to in AgentTask.Status.allCases {
                #expect(TaskTransitionCause.smithSetStatus.permits(from: from, to: to) == UpdateTaskStatusPolicy.settable.contains(to))
            }
        }
    }

    @Test("A transition round-trips through Codable (it is persisted inside effect records)")
    func transitionCodable() throws {
        let transition = TaskStatusTransition(
            taskID: UUID(), statusRevision: 7, from: .running, to: .interrupted,
            at: Date(timeIntervalSince1970: 1_000), cause: .coldBootRecovery(.interrupt)
        )
        let decoded = try JSONDecoder().decode(TaskStatusTransition.self, from: JSONEncoder().encode(transition))
        #expect(decoded == transition)
        let scheduled = TaskTransitionCause.scheduledAction(.pause)
        #expect(try JSONDecoder().decode(TaskTransitionCause.self, from: JSONEncoder().encode(scheduled)) == scheduled)
    }
}

/// The runtime reacts to lifecycle events through its one serialized consumer.
@Suite("Task lifecycle reactions", .serialized)
struct TaskLifecycleReactionTests {

    private func waitUntil(timeout: Duration = .seconds(10), _ predicate: @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return await predicate()
    }

    private func makeRuntime() -> OrchestrationRuntime {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-smith-lifecycle-reactions", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let configuration = ModelConfiguration(name: "test", providerID: "test", modelID: "test-model")
        return OrchestrationRuntime(
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
    }

    @Test("Permanently deleting an active task cancels its scheduled wakes (the old hook missed this)")
    func permanentDeleteCancelsWakes() async {
        let runtime = makeRuntime()
        await runtime.start()
        let store = await runtime.taskStore
        let task = await store.addTask(title: "t", description: "d")
        await runtime.restoreScheduledWakes([
            ScheduledWake(wakeAt: Date().addingTimeInterval(3600), instructions: "later", taskID: task.id)
        ])
        #expect(await runtime.currentScheduledWakes()?.count == 1)
        #expect(await store.permanentlyDelete(id: task.id))
        let cancelled = await waitUntil { await runtime.currentScheduledWakes()?.isEmpty == true }
        #expect(cancelled)
        await runtime.stopAll()
    }
}
