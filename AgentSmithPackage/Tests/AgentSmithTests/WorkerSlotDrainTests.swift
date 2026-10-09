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
/// Capacity 1 is the only case covered. The same window also ran a larger pool one worker short;
/// covering that needs workers that stay alive, which `StillThinkingLLMProvider` now provides.
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
            .brown: StillThinkingLLMProvider()
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
            // The worker stays mid-call (`StillThinkingLLMProvider`) rather than answering: a
            // worker that answers text-only trips the degenerate-loop guard and self-terminates —
            // and that path removes its handle BEFORE writing the status, which is the ordering
            // the bug under test does NOT have. So a spinning worker let the test sometimes
            // exercise the already-correct path and pass with the fix reverted.
            agentTuning: [
                .brown: AgentTuningConfig(pollInterval: 3600),
                .smith: AgentTuningConfig(pollInterval: 3600),
                .securityAgent: AgentTuningConfig(pollInterval: 3600)
            ],
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

    @Test("Tearing down the only worker at capacity 1 advances the queued task behind it")
    func teardownAdvancesQueueAtCapacityOne() async throws {
        let runtime = makeRuntime()
        await configureForCompletionWithoutValidators(runtime)
        await runtime.setWorkerCapacity(1)
        await runtime.start()
        let store = await runtime.taskStore

        let taskA = await store.addTask(title: "A", description: "d")
        await runtime.restartForNewTask(taskID: taskA.id, origin: .explicitUser)
        await runtime.waitForPendingRestarts()
        #expect(await store.task(id: taskA.id)?.status == .running)
        #expect(await runtime.agentIDForRole(.brown) != nil, "A must hold the only worker slot")

        let taskB = await store.addTask(title: "B", description: "d")
        #expect(await store.task(id: taskB.id)?.status == .pending)

        // Tear the worker down with A still `.running`, so NO terminal status transition fires and
        // the only thing that can admit B is the drain this teardown kicks.
        //
        // Deliberately not driven through validation-completion, the shape the bug had: the
        // terminal-status hook runs its own drain, which would admit B with the fix reverted. (An
        // answering mock worker once confounded this further by dying on its own; the worker here
        // stays mid-call.) Isolating the teardown removes every confound: with A `.running` and its
        // worker gone, nothing else in the system has any reason to start B.
        let brownForA = try #require(await runtime.agentIDForRole(.brown))
        #expect(await store.task(id: taskA.id)?.status == .running)
        _ = await runtime.terminateAgent(id: brownForA)

        let advanced = await waitUntil(timeout: .seconds(15)) {
            await store.task(id: taskB.id)?.status != .pending
        }
        #expect(
            advanced,
            "B stayed .pending after the only worker was torn down — the freed slot never drained the queue"
        )

        await runtime.stopAll()
    }

    @Test("A worker's precondition report frees its slot for the queued task behind it")
    func preconditionReportAdvancesQueueAtCapacityOne() async throws {
        let runtime = makeRuntime()
        await configureForCompletionWithoutValidators(runtime)
        await runtime.setWorkerCapacity(1)
        await runtime.start()
        let store = await runtime.taskStore

        let attested = TaskPrecondition(kind: .workerAttested(statement: "the fixture exists"), origin: .smith)
        let taskA = await store.addTask(title: "A", description: "d", preconditions: [attested])
        await runtime.restartForNewTask(taskID: taskA.id, origin: .explicitUser)
        await runtime.waitForPendingRestarts()
        let workerForA = try #require(await runtime.liveWorkerID(taskID: taskA.id))

        let taskB = await store.addTask(title: "B", description: "d")
        #expect(await store.task(id: taskB.id)?.status == .pending)

        let outcome = await runtime.handlePreconditionReport(from: workerForA, preconditionID: attested.id, evidence: "no fixture")
        guard case .blocked = outcome else { Issue.record("the report must block A: \(outcome)"); return }

        let advanced = await waitUntil(timeout: .seconds(15)) {
            await store.task(id: taskB.id)?.status != .pending
        }
        #expect(advanced, "B stayed .pending after A's worker was ended by its precondition report")

        await runtime.stopAll()
    }
}
