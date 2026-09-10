import Foundation
import Testing
import SemanticSearch
@testable import AgentSmithKit

/// A freed worker slot must actually advance the queue.
///
/// `TaskStore.updateStatus` fires `onTaskTerminated` SYNCHRONOUSLY from inside the status write,
/// and `completeValidatedTask` flips the task to `.completed` BEFORE tearing its worker down. So
/// the drain that hook schedules observed the finished task's Brown still registered, computed
/// zero free slots, admitted nothing — and nothing re-drained. At `maxConcurrentWorkers == 1` a
/// queued task was stranded permanently, while `create_task` had already told Smith "auto-run will
/// start it when a slot frees. Do NOT call run_task on it."
///
/// Reproduced 11 times in 12 runs before the fix. The kick now lives in `terminateAgent`, so it
/// covers every terminal transition rather than the one someone remembered to annotate.
///
/// Capacity 1 is deliberately the ONLY case covered. The same window also ran a larger pool one
/// worker short, but that is not observable with a mock provider: a mock worker trips the
/// degenerate-loop guard within about a second and fails on its own, freeing further slots, so
/// "exactly one slot freed" and "the live worker was not evicted" both read false for reasons
/// that have nothing to do with draining. A test asserting them would be a flake, not a guard —
/// proving it needs a worker that stays alive, which is scaffolding this suite does not have.
@Suite("Worker slot drain")
struct WorkerSlotDrainTests {

    /// Generous by default. This suite spawns a real runtime with three mock agents, and on a
    /// full parallel `swift test` run the setup steps are slow enough under CPU contention that a
    /// short deadline reports a stall that isn't one. A long timeout costs nothing when the code is
    /// correct — it returns the moment the predicate holds — and only the failing case pays it.
    private func waitUntil(
        timeout: Duration = .seconds(30),
        _ predicate: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return await predicate()
    }

    private func makeRuntime() -> OrchestrationRuntime {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-smith-worker-slot-drain", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let providers: [AgentRole: any LLMProvider] = [
            .smith: MockLLMProvider(responses: [LLMResponse(text: "Standing by.")]),
            .securityAgent: MockLLMProvider(responses: [LLMResponse(text: "SAFE")]),
            .brown: MockLLMProvider(responses: [LLMResponse(text: "Working.")])
        ]
        let configurations: [AgentRole: ModelConfiguration] = [
            .smith: ModelConfiguration(name: "test", providerID: "test", modelID: "test-model"),
            .securityAgent: ModelConfiguration(name: "test", providerID: "test", modelID: "test-model"),
            .brown: ModelConfiguration(name: "test", providerID: "test", modelID: "test-model")
        ]
        return OrchestrationRuntime(
            providers: providers,
            configurations: configurations,
            providerAPITypes: [:],
            agentTuning: [:],
            semanticSearchEngine: SemanticSearchEngine(),
            usageStore: UsageStore(persistence: PersistenceManager(testingRoot: tmpRoot)),
            autoAdvanceEnabled: true,
            autoRunInterruptedTasks: false,
            memoryStore: nil
        )
    }

    /// Validation OFF routes `performTaskValidation` straight into
    /// `completeValidatedTask(validationWasRun: false)` — the exact flip-then-terminate ordering
    /// under test — with no validator model needed.
    private func configureForCompletionWithoutValidators(_ runtime: OrchestrationRuntime) async {
        await runtime.setOrchestrationSettings(
            OrchestrationSettings.builtIn.applying(
                OrchestrationSettingsOverride(
                    autoRunNextTask: true,
                    autoRunInterruptedTasks: false,
                    enableTaskCompletionValidators: false,
                    scopeToolSetOnTaskStart: false
                )
            )
        )
    }

    @Test("A completing task at capacity 1 advances the queued task behind it")
    func completionAdvancesQueueAtCapacityOne() async {
        let runtime = makeRuntime()
        await configureForCompletionWithoutValidators(runtime)
        await runtime.setWorkerCapacity(1)
        await runtime.start()
        let store = await runtime.taskStore

        let taskA = await store.addTask(title: "A", description: "d")
        await runtime.restartForNewTask(taskID: taskA.id)
        await runtime.waitForPendingRestarts()
        #expect(await store.task(id: taskA.id)?.status == .running)
        #expect(await runtime.agentIDForRole(.brown) != nil, "A must hold the only worker slot")

        let taskB = await store.addTask(title: "B", description: "d")
        #expect(await store.task(id: taskB.id)?.status == .pending)

        await store.updateStatus(id: taskA.id, status: .validating)
        await runtime.startTaskValidation(taskID: taskA.id)
        let aCompleted = await waitUntil { await store.task(id: taskA.id)?.status == .completed }
        let aStatus = await store.task(id: taskA.id)?.status
        #expect(aCompleted, "A never completed; it is \(String(describing: aStatus))")

        // Assert on "left .pending", not "== .running": the mock worker trips the degenerate-loop
        // guard within about a second and lands `.failed`, so polling for `.running` reports a
        // false stall. What is under test is whether B was ever ADMITTED.
        let advanced = await waitUntil(timeout: .seconds(15)) {
            await store.task(id: taskB.id)?.status != .pending
        }
        #expect(
            advanced,
            "B stayed .pending after A completed — the freed slot never drained the queue"
        )

        await runtime.stopAll()
    }
}
