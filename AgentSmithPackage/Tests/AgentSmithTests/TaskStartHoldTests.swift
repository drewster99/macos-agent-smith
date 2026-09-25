import Testing
import Foundation
import SemanticSearch
import SwiftLLMKit
@testable import AgentSmithKit

@Suite("Start holds — store")
struct TaskStartHoldStoreTests {

    @Test("A startTask watch holds its target; cancelling the watch releases the hold")
    func holdFollowsWatch() async throws {
        let store = TaskStore()
        let upstream = await store.addTask(title: "A", description: "d")
        let downstream = await store.addTask(title: "B", description: "d")
        let watch = TaskWatch(triggers: [.completed], action: .startTask(taskID: downstream.id), createdBy: .user)
        #expect(await store.addWatch(watch, to: upstream.id) == nil)
        #expect(await store.task(id: downstream.id)?.startHolds == [TaskStartHold(watchedTaskID: upstream.id, watchID: watch.id)])
        #expect(await store.tasksHeld(by: upstream.id).map(\.id) == [downstream.id])
        #expect(await store.cancelWatch(watch.id, on: upstream.id) == nil)
        #expect(await store.task(id: downstream.id)?.startHolds.isEmpty == true)
    }

    @Test("Overriding a hold cancels the chain link it supersedes")
    func overrideCancelsWatch() async throws {
        let store = TaskStore()
        let upstream = await store.addTask(title: "A", description: "d")
        let downstream = await store.addTask(title: "B", description: "d")
        let watch = TaskWatch(triggers: [.completed], action: .startTask(taskID: downstream.id), createdBy: .user)
        #expect(await store.addWatch(watch, to: upstream.id) == nil)
        #expect(await store.overrideStartHolds(of: downstream.id).count == 1)
        #expect(await store.task(id: downstream.id)?.startHolds.isEmpty == true)
        guard case .cancelled = await store.task(id: upstream.id)?.watch(id: watch.id)?.state else {
            Issue.record("the superseded watch should be cancelled"); return
        }
    }

    @Test("A queued run's origin persists, and entries written before origins decode as scheduled")
    func queuedOriginPersists() throws {
        let entry = PendingScheduledRun(taskID: UUID(), amendment: nil, origin: .watchSatisfied(watchID: UUID()))
        #expect(try JSONDecoder().decode(PendingScheduledRun.self, from: JSONEncoder().encode(entry)) == entry)
        let legacy = try #require("{\"taskID\":\"\(UUID().uuidString)\"}".data(using: .utf8))
        #expect(try JSONDecoder().decode(PendingScheduledRun.self, from: legacy).origin == .scheduled)
    }

    @Test("Only the user's explicit start overrides a hold")
    func overridePolicy() {
        #expect(TaskStartOrigin.explicitUser.overridesStartHolds)
        for origin: TaskStartOrigin in [.smithTool, .scheduled, .autoAdvance, .launchResume, .capacityResume, .watchSatisfied(watchID: UUID())] {
            #expect(!origin.overridesStartHolds, "\(origin)")
        }
    }
}

@Suite("Start holds — every start path", .serialized)
struct TaskStartHoldRuntimeTests {

    private func waitUntil(timeout: Duration = .seconds(15), _ predicate: @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return await predicate()
    }

    private func makeRuntime(autoAdvance: Bool = false, autoRunInterrupted: Bool = false) async -> OrchestrationRuntime {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-smith-start-holds", isDirectory: true)
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
            autoAdvanceEnabled: autoAdvance,
            autoRunInterruptedTasks: autoRunInterrupted,
            memoryStore: nil
        )
        await runtime.setOrchestrationSettings(OrchestrationSettings.builtIn.applying(OrchestrationSettingsOverride(
            autoRunNextTask: autoAdvance, autoRunInterruptedTasks: autoRunInterrupted, scopeToolSetOnTaskStart: false
        )))
        return runtime
    }

    /// A held B, chained after A.
    private func chain(_ store: TaskStore) async -> (upstream: AgentTask, downstream: AgentTask, watch: TaskWatch) {
        let upstream = await store.addTask(title: "A", description: "d")
        let downstream = await store.addTask(title: "B", description: "d")
        let watch = TaskWatch(triggers: [.completed], action: .startTask(taskID: downstream.id), createdBy: .user)
        _ = await store.addWatch(watch, to: upstream.id)
        return (upstream, downstream, watch)
    }

    @Test("Auto-advance never starts a held task")
    func autoAdvanceSkipsHeld() async {
        let runtime = await makeRuntime(autoAdvance: true)
        await runtime.start()
        let store = await runtime.taskStore
        let (upstream, downstream, _) = await chain(store)
        await store.updateStatus(id: upstream.id, status: .interrupted, cause: .smithSetStatus)
        await runtime.drainPendingTaskQueueForTesting()
        await runtime.waitForPendingRestarts()
        #expect(await store.task(id: downstream.id)?.status == .pending)
        await runtime.stopAll()
    }

    @Test("A scheduled run, Smith, and a stray watch start are turned away at the gate")
    func nonUserOriginsRefused() async {
        let runtime = await makeRuntime()
        await runtime.start()
        let store = await runtime.taskStore
        let (_, downstream, _) = await chain(store)
        for origin: TaskStartOrigin in [.scheduled, .smithTool, .autoAdvance, .launchResume, .capacityResume, .watchSatisfied(watchID: UUID())] {
            await runtime.restartForNewTask(taskID: downstream.id, origin: origin)
            await runtime.waitForPendingRestarts()
            #expect(await store.task(id: downstream.id)?.status == .pending, "\(origin) must not start a held task")
        }
        let refusedScheduled = await runtime.channel.allMessages().contains { $0.kind == .scheduledRunRefused }
        #expect(refusedScheduled, "a refused scheduled run is reported")
        await runtime.stopAll()
    }

    @Test("The user's Play starts a held task and cancels the watch it supersedes")
    func playOverrides() async {
        let runtime = await makeRuntime()
        await runtime.start()
        let store = await runtime.taskStore
        let (upstream, downstream, watch) = await chain(store)
        await runtime.restartForNewTask(taskID: downstream.id, origin: .explicitUser)
        let started = await waitUntil { await store.task(id: downstream.id)?.startedAt != nil }
        #expect(started)
        guard case .cancelled = await store.task(id: upstream.id)?.watch(id: watch.id)?.state else {
            Issue.record("the superseded watch should be cancelled"); return
        }
        await runtime.stopAll()
    }

    @Test("A task waiting on two tasks starts only when the second fires")
    func multipleDependencies() async {
        let runtime = await makeRuntime()
        await runtime.start()
        let store = await runtime.taskStore
        let first = await store.addTask(title: "A1", description: "d")
        let second = await store.addTask(title: "A2", description: "d")
        let downstream = await store.addTask(title: "B", description: "d")
        _ = await store.addWatch(TaskWatch(triggers: [.completed], action: .startTask(taskID: downstream.id), createdBy: .user), to: first.id)
        _ = await store.addWatch(TaskWatch(triggers: [.completed], action: .startTask(taskID: downstream.id), createdBy: .user), to: second.id)
        await store.updateStatus(id: first.id, status: .completed, cause: .smithSetStatus)
        let oneLeft = await waitUntil { await store.task(id: downstream.id)?.startHolds.count == 1 }
        #expect(oneLeft)
        #expect(await store.task(id: downstream.id)?.status == .pending)
        await store.updateStatus(id: second.id, status: .completed, cause: .smithSetStatus)
        let started = await waitUntil { await store.task(id: downstream.id)?.startedAt != nil }
        #expect(started)
        await runtime.stopAll()
    }

    @Test("A watched task that fails without firing its startTask watch leaves the user told")
    func strandedByFailure() async {
        let runtime = await makeRuntime()
        await runtime.start()
        let store = await runtime.taskStore
        let (upstream, downstream, _) = await chain(store)
        await store.updateStatus(id: upstream.id, status: .failed, cause: .smithSetStatus)
        let warned = await waitUntil {
            await runtime.channel.allMessages().contains { $0.taskID == downstream.id && $0.severity == .warning && $0.content.contains("still waiting") }
        }
        #expect(warned)
        #expect(await store.task(id: downstream.id)?.status == .pending)
        await runtime.stopAll()
    }

    @Test("Deleting the watched task leaves the user told")
    func strandedByDeletion() async {
        let runtime = await makeRuntime()
        await runtime.start()
        let store = await runtime.taskStore
        let (upstream, downstream, _) = await chain(store)
        #expect(await store.permanentlyDelete(id: upstream.id))
        let warned = await waitUntil {
            await runtime.channel.allMessages().contains { $0.taskID == downstream.id && $0.severity == .warning && $0.content.contains("still waiting") }
        }
        #expect(warned)
        await runtime.stopAll()
    }

    @Test("A held interrupted task is not auto-resumed at launch")
    func launchResumeSkipsHeld() async {
        let runtime = await makeRuntime(autoRunInterrupted: true)
        let store = await runtime.taskStore
        let upstream = await store.addTask(title: "A", description: "d")
        let downstream = await store.addTask(title: "B", description: "d")
        _ = await store.addWatch(TaskWatch(triggers: [.completed], action: .startTask(taskID: downstream.id), createdBy: .user), to: upstream.id)
        await store.updateStatus(id: downstream.id, status: .interrupted, cause: .smithSetStatus)
        await runtime.start()
        await runtime.waitForPendingRestarts()
        #expect(await store.task(id: downstream.id)?.status == .interrupted)
        await runtime.stopAll()
    }
}
