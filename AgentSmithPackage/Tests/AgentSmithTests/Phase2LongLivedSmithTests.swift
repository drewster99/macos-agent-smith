import Foundation
import Testing
import SemanticSearch
@testable import AgentSmithKit

/// Phase 2: Smith is long-lived; starting a task cycles the WORKER, not the world.

@Suite("Long-lived Smith worker cycling")
struct Phase2LongLivedSmithTests {

    private func makeRuntime(includeBrown: Bool = true) -> OrchestrationRuntime {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-smith-phase2-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        var providers: [AgentRole: any LLMProvider] = [
            .smith: MockLLMProvider(responses: [LLMResponse(text: "Standing by.")])
        ]
        var configurations: [AgentRole: ModelConfiguration] = [
            .smith: ModelConfiguration(name: "test", providerID: "test", modelID: "test-model")
        ]
        if includeBrown {
            providers[.brown] = MockLLMProvider(responses: [LLMResponse(text: "Working.")])
            providers[.securityAgent] = MockLLMProvider(responses: [LLMResponse(text: "SAFE")])
            configurations[.brown] = ModelConfiguration(name: "test", providerID: "test", modelID: "test-model")
            configurations[.securityAgent] = ModelConfiguration(name: "test", providerID: "test", modelID: "test-model")
        }
        return OrchestrationRuntime(
            providers: providers,
            configurations: configurations,
            providerAPITypes: [:],
            agentTuning: [:],
            semanticSearchEngine: SemanticSearchEngine(),
            usageStore: UsageStore(persistence: PersistenceManager(testingRoot: tmpRoot)),
            autoAdvanceEnabled: false,
            autoRunInterruptedTasks: false,
            memoryStore: nil
        )
    }

    @Test("Starting a task cycles the worker while Smith survives")
    func workerCycleKeepsSmithAlive() async {
        let runtime = makeRuntime()
        // Pre-flight scoping off: the mock Security Agent can't emit the scoping JSON,
        // and scoping behavior has its own coverage.
        await runtime.setToolSecurity(preflightScoping: false, perCallCheck: false, globalPolicy: [:])
        await runtime.start()
        let smithBefore = await runtime.agentIDForRole(.smith)
        #expect(smithBefore != nil)

        let store = await runtime.taskStore
        let task = await store.addTask(title: "First task", description: "do the thing")
        await runtime.restartForNewTask(taskID: task.id)
        await runtime.waitForPendingRestarts()

        let smithAfter = await runtime.agentIDForRole(.smith)
        #expect(smithAfter == smithBefore, "Smith must SURVIVE a task start — that is Phase 2's whole point")
        let brownID = await runtime.agentIDForRole(.brown)
        #expect(brownID != nil, "a worker must be live")
        let running = await store.task(id: task.id)
        #expect(running?.status == .running)
        #expect(running?.assigneeIDs.contains(brownID ?? UUID()) == true)

        // The old full-restart banner must NOT appear on the worker-cycle path.
        let transcript = await runtime.channel.allMessages()
        #expect(!transcript.contains { $0.content == "All agents stopped." },
                "worker cycling must not tear down the world")

        // Smith was informed in-context rather than rebuilt.
        let smithContext = await runtime.contextSnapshot(for: .smith)
        #expect(smithContext?.contains { $0.content.textValue?.contains("has been started") == true } == true)

        await runtime.stopAll()
    }

    @Test("A second task start replaces the worker, still under the same Smith")
    func secondTaskReplacesWorker() async {
        let runtime = makeRuntime()
        await runtime.setToolSecurity(preflightScoping: false, perCallCheck: false, globalPolicy: [:])
        await runtime.start()
        let smithID = await runtime.agentIDForRole(.smith)
        let store = await runtime.taskStore

        let first = await store.addTask(title: "First", description: "d")
        await runtime.restartForNewTask(taskID: first.id)
        await runtime.waitForPendingRestarts()
        let firstBrown = await runtime.agentIDForRole(.brown)

        // Finish the first task so the second is allowed to start.
        await store.updateStatus(id: first.id, status: .completed)

        let second = await store.addTask(title: "Second", description: "d")
        await runtime.restartForNewTask(taskID: second.id)
        await runtime.waitForPendingRestarts()
        let secondBrown = await runtime.agentIDForRole(.brown)

        #expect(await runtime.agentIDForRole(.smith) == smithID, "same Smith across both tasks")
        #expect(firstBrown != nil && secondBrown != nil)
        #expect(firstBrown != secondBrown, "each task gets a FRESH worker")

        await runtime.stopAll()
    }

    @Test("spawnBrown for the same task cycles that task's worker; capacity 1 evicts the incumbent")
    func spawnPolicyCyclesAndEvicts() async {
        let runtime = makeRuntime()
        await runtime.setToolSecurity(preflightScoping: false, perCallCheck: false, globalPolicy: [:])
        await runtime.start()
        let store = await runtime.taskStore

        // Same-task respawn: the task's existing worker is replaced, count stays 1.
        let taskA = await store.addTask(title: "A", description: "d")
        let workerA1 = await runtime.spawnBrown(for: taskA)
        let workerA2 = await runtime.spawnBrown(for: taskA)
        #expect(workerA1 != nil && workerA2 != nil && workerA1 != workerA2)
        #expect(await runtime.agentIDForRole(.brown) == workerA2)

        // Different task at capacity 1: the incumbent is evicted (historical policy).
        let taskB = await store.addTask(title: "B", description: "d")
        let workerB = await runtime.spawnBrown(for: taskB)
        #expect(workerB != nil)
        #expect(await runtime.agentIDForRole(.brown) == workerB, "only task B's worker survives at capacity 1")

        await runtime.stopAll()
    }

    @Test("At capacity 2, workers for two tasks coexist; a third spawn evicts the oldest")
    func capacityTwoAllowsConcurrentWorkers() async {
        let runtime = makeRuntime()
        await runtime.setToolSecurity(preflightScoping: false, perCallCheck: false, globalPolicy: [:])
        await runtime.setWorkerCapacity(2)
        await runtime.start()
        let store = await runtime.taskStore

        let taskA = await store.addTask(title: "A", description: "d")
        let taskB = await store.addTask(title: "B", description: "d")
        let taskC = await store.addTask(title: "C", description: "d")
        guard let workerA = await runtime.spawnBrown(for: taskA),
              let workerB = await runtime.spawnBrown(for: taskB) else {
            Issue.record("worker spawns failed")
            return
        }
        #expect(await runtime.isAgentRegistered(workerA), "worker A survives worker B's spawn at capacity 2")
        #expect(await runtime.isAgentRegistered(workerB))

        guard let workerC = await runtime.spawnBrown(for: taskC) else {
            Issue.record("third worker spawn failed")
            return
        }
        #expect(!(await runtime.isAgentRegistered(workerA)), "the OLDEST worker is evicted at capacity")
        #expect(await runtime.isAgentRegistered(workerB))
        #expect(await runtime.isAgentRegistered(workerC))

        await runtime.stopAll()
    }

    @Test("A worker spawn failure marks the task failed and tells the surviving Smith")
    func spawnFailureNotifiesSmithInContext() async {
        let runtime = makeRuntime(includeBrown: false)
        await runtime.setToolSecurity(preflightScoping: false, perCallCheck: false, globalPolicy: [:])
        await runtime.start()
        let smithBefore = await runtime.agentIDForRole(.smith)

        let store = await runtime.taskStore
        let task = await store.addTask(title: "Doomed", description: "no brown provider exists")
        await runtime.restartForNewTask(taskID: task.id)
        await runtime.waitForPendingRestarts()

        let after = await store.task(id: task.id)
        #expect(after?.status == .failed)
        #expect(await runtime.agentIDForRole(.smith) == smithBefore, "Smith survives the failure too")
        let smithContext = await runtime.contextSnapshot(for: .smith)
        #expect(smithContext?.contains { $0.content.textValue?.contains("could not be started") == true } == true)

        await runtime.stopAll()
    }

    @Test("Auto-compact is a no-op below the threshold")
    func autoCompactNoOpBelowThreshold() async {
        let runtime = makeRuntime(includeBrown: false)
        await runtime.start()
        let before = await runtime.contextSnapshot(for: .smith)?.count
        await runtime.autoCompactSmithIfNeeded()
        let after = await runtime.contextSnapshot(for: .smith)?.count
        #expect(before == after, "a small context must not be compacted")
        await runtime.stopAll()
    }
}
