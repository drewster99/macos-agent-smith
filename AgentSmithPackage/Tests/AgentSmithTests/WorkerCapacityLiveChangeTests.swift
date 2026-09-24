import Foundation
import Testing
import SemanticSearch
@testable import AgentSmithKit

/// Changing "Max simultaneous tasks" on a live run: raising it fills the new slots at once; lowering
/// it stops the newest workers above the limit and resumes their tasks automatically as slots free.
@Suite("Live worker capacity changes")
struct WorkerCapacityLiveChangeTests {

    private func waitUntil(timeout: Duration = .seconds(30), _ predicate: @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return await predicate()
    }

    /// Mock workers with long poll intervals so they sit idle instead of burning turns and tripping
    /// the degenerate-loop guard (which would free slots for reasons unrelated to the test).
    private func makeRuntime(autoRunNextTask: Bool) async -> (OrchestrationRuntime, URL) {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-smith-capacity-live", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let config = ModelConfiguration(name: "test", providerID: "test", modelID: "test-model")
        let runtime = OrchestrationRuntime(
            providers: [
                .smith: MockLLMProvider(responses: [LLMResponse(text: "Standing by.")]),
                .securityAgent: MockLLMProvider(responses: [LLMResponse(text: "SAFE")]),
                .brown: MockLLMProvider(responses: [LLMResponse(text: "Working.")]),
            ],
            configurations: [.smith: config, .securityAgent: config, .brown: config],
            providerAPITypes: [:],
            agentTuning: [
                .brown: AgentTuningConfig(pollInterval: 3600),
                .smith: AgentTuningConfig(pollInterval: 3600),
                .securityAgent: AgentTuningConfig(pollInterval: 3600),
            ],
            semanticSearchEngine: SemanticSearchEngine(),
            usageStore: UsageStore(persistence: PersistenceManager(testingRoot: tmpRoot)),
            autoAdvanceEnabled: autoRunNextTask,
            autoRunInterruptedTasks: false,
            memoryStore: nil
        )
        await runtime.setOrchestrationSettings(OrchestrationSettings.builtIn.applying(OrchestrationSettingsOverride(
            autoRunNextTask: autoRunNextTask,
            autoRunInterruptedTasks: false,
            enableTaskCompletionValidators: false,
            scopeToolSetOnTaskStart: false
        )))
        return (runtime, tmpRoot)
    }

    @Test("raising capacity starts a queued task immediately")
    func raisingCapacityFillsNewSlots() async throws {
        let (runtime, tmpRoot) = await makeRuntime(autoRunNextTask: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        await runtime.setWorkerCapacity(1)
        await runtime.start()
        let store = await runtime.taskStore

        let taskA = await store.addTask(title: "A", description: "d")
        await runtime.restartForNewTask(taskID: taskA.id)
        await runtime.waitForPendingRestarts()
        let taskB = await store.addTask(title: "B", description: "d")
        #expect(await store.task(id: taskB.id)?.status == .pending, "B queues behind the only slot")

        await runtime.setWorkerCapacity(2)
        await runtime.waitForPendingRestarts()
        let started = await waitUntil { await store.task(id: taskB.id)?.status != .pending }
        #expect(started, "B must start as soon as the capacity is raised, not when A finishes")
        #expect(await store.task(id: taskA.id)?.status == .running)
        await runtime.stopAll()
    }

    @Test("lowering capacity stops the newest worker; raising it again resumes that task on its own")
    func loweringCapacityDefersNewestAndResumes() async throws {
        // Auto-run OFF: the deferred task must resume anyway — the user shrank a limit, they did
        // not ask for the work to halt.
        let (runtime, tmpRoot) = await makeRuntime(autoRunNextTask: false)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        await runtime.setWorkerCapacity(2)
        await runtime.start()
        let store = await runtime.taskStore

        let older = await store.addTask(title: "Older", description: "d")
        await runtime.restartForNewTask(taskID: older.id)
        await runtime.waitForPendingRestarts()
        let newer = await store.addTask(title: "Newer", description: "d")
        await runtime.restartForNewTask(taskID: newer.id)
        await runtime.waitForPendingRestarts()
        #expect(await runtime.workerSlots().live == 2)

        await runtime.setWorkerCapacity(1)
        #expect(await runtime.workerSlots().live == 1)
        #expect(await store.task(id: newer.id)?.status == .interrupted, "the most recently started task is the one stopped")
        #expect(await store.task(id: older.id)?.status == .running, "the older task keeps its worker")

        await runtime.setWorkerCapacity(2)
        await runtime.waitForPendingRestarts()
        let resumed = await waitUntil { await store.task(id: newer.id)?.status == .running }
        #expect(resumed, "the deferred task resumes by itself once a slot frees, even with auto-run off")
        await runtime.stopAll()
    }

    @Test("setting capacity before a run starts neither starts nor stops anything")
    func capacityBeforeStartOnlyStoresTheNumber() async {
        let (runtime, tmpRoot) = await makeRuntime(autoRunNextTask: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        let store = await runtime.taskStore
        let pending = await store.addTask(title: "P", description: "d")
        await runtime.setWorkerCapacity(5)
        await runtime.waitForPendingRestarts()
        #expect(await store.task(id: pending.id)?.status == .pending)
        #expect(await runtime.workerSlots().capacity == 5)
    }
}
