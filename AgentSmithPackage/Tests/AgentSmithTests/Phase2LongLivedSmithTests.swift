import Foundation
import Testing
import SemanticSearch
@testable import AgentSmithKit

/// Phase 2: Smith is long-lived; starting a task cycles the WORKER, not the world.

@Suite("Long-lived Smith worker cycling")
struct Phase2LongLivedSmithTests {

    private func waitUntil(timeout: Duration = .seconds(2), _ predicate: @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await predicate()
    }

    private func makeRuntime(includeBrown: Bool = true, autoRunInterrupted: Bool = false) -> OrchestrationRuntime {
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
            autoRunInterruptedTasks: autoRunInterrupted,
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

    @Test("spawnBrown cycles the same task's worker; at capacity a different task's spawn is refused, never evicting")
    func spawnPolicyCyclesButNeverEvicts() async {
        let runtime = makeRuntime()
        await runtime.setToolSecurity(preflightScoping: false, perCallCheck: false, globalPolicy: [:])
        await runtime.setWorkerCapacity(1)
        await runtime.start()
        let store = await runtime.taskStore

        // Same-task respawn: the task's existing worker is replaced, count stays 1.
        let taskA = await store.addTask(title: "A", description: "d")
        let workerA1 = await runtime.spawnBrown(for: taskA)
        let workerA2 = await runtime.spawnBrown(for: taskA)
        #expect(workerA1 != nil && workerA2 != nil && workerA1 != workerA2)
        #expect(await runtime.agentIDForRole(.brown) == workerA2)

        // Different task at capacity: the spawn is REFUSED; the incumbent is untouchable.
        let taskB = await store.addTask(title: "B", description: "d")
        let workerB = await runtime.spawnBrown(for: taskB)
        #expect(workerB == nil, "capacity never evicts — the spawn fails cleanly")
        #expect(await runtime.agentIDForRole(.brown) == workerA2, "task A's worker survives")

        await runtime.stopAll()
    }

    @Test("At capacity 2, workers for two tasks coexist; a third spawn is refused")
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

        let workerC = await runtime.spawnBrown(for: taskC)
        #expect(workerC == nil, "the third spawn is refused — nobody is evicted")
        #expect(await runtime.isAgentRegistered(workerA))
        #expect(await runtime.isAgentRegistered(workerB))

        await runtime.stopAll()
    }

    @Test("A start racing past the tool checks is PENDED by the serialized gate, not failed, not evicting")
    func capacityGatePendsTheRaceLoser() async {
        let runtime = makeRuntime()
        await runtime.setToolSecurity(preflightScoping: false, perCallCheck: false, globalPolicy: [:])
        await runtime.setWorkerCapacity(1)
        await runtime.start()
        let store = await runtime.taskStore

        // Task A occupies the only slot, genuinely running.
        let taskA = await store.addTask(title: "A", description: "d")
        await runtime.restartForNewTask(taskID: taskA.id)
        await runtime.waitForPendingRestarts()
        let workerA = await runtime.agentIDForRole(.brown)
        #expect(workerA != nil)

        // A second start arrives anyway (the tool-check race). The lifecycle-queue gate
        // pends it instead of failing it or evicting task A's worker.
        let taskB = await store.addTask(title: "B", description: "d")
        await runtime.restartForNewTask(taskID: taskB.id)
        await runtime.waitForPendingRestarts()

        #expect(await store.task(id: taskB.id)?.status == .pending, "the race loser queues")
        #expect(await store.task(id: taskA.id)?.status == .running, "the incumbent keeps running")
        #expect(await runtime.agentIDForRole(.brown) == workerA, "task A's worker is untouched")

        await runtime.stopAll()
    }

    @Test("Starting a template clones a fresh instance and runs it; the template stays put")
    func templateStartClonesAndRuns() async {
        let runtime = makeRuntime()
        await runtime.setToolSecurity(preflightScoping: false, perCallCheck: false, globalPolicy: [:])
        await runtime.start()
        let store = await runtime.taskStore
        let template = await store.addTask(title: "Nightly", description: "d", isTemplate: true)

        await runtime.restartForNewTask(taskID: template.id)
        await runtime.waitForPendingRestarts()

        // The template itself never ran — it's still a pending template.
        let templateAfter = await store.task(id: template.id)
        #expect(templateAfter?.isTemplate == true)
        #expect(templateAfter?.status == .pending)
        #expect(templateAfter?.assigneeIDs.isEmpty == true)

        // A single fresh instance was created and is the one running.
        let instances = await store.allTasks().filter { $0.parentTaskID == template.id }
        #expect(instances.count == 1)
        #expect(instances.first?.isTemplate == false)
        #expect(instances.first?.status == .running)

        await runtime.stopAll()
    }

    @Test("Starting a template through the runtime preserves supplied template inputs")
    func templateStartPreservesRuntimeInputValues() async {
        let runtime = makeRuntime()
        await runtime.setToolSecurity(preflightScoping: false, perCallCheck: false, globalPolicy: [:])
        await runtime.start()
        let store = await runtime.taskStore
        let template = await store.addTask(title: "Targeted run", description: "d", isTemplate: true)
        _ = await store.setTemplateInputDefinitions(id: template.id, definitions: [
            TemplateInputDefinition(name: "target_app", description: "App name or bundle ID.", required: true),
            TemplateInputDefinition(name: "locale", description: "Locale to test.", required: false)
        ])

        await runtime.restartForNewTask(
            taskID: template.id,
            templateInputValues: ["target_app": "  Notes  ", "locale": "   "]
        )
        await runtime.waitForPendingRestarts()

        let instances = await store.allTasks().filter { $0.parentTaskID == template.id }
        #expect(instances.count == 1)
        #expect(instances.first?.status == .running)
        #expect(instances.first?.templateInputValues == ["target_app": "Notes"])

        await runtime.stopAll()
    }

    @Test("A per-run amendment lands on the cloned instance, never the template")
    func templateAmendmentAppliesToCloneNotTemplate() async {
        let runtime = makeRuntime()
        await runtime.setToolSecurity(preflightScoping: false, perCallCheck: false, globalPolicy: [:])
        await runtime.start()
        let store = await runtime.taskStore
        let template = await store.addTask(title: "Nightly", description: "base description", isTemplate: true)

        await runtime.restartForNewTask(taskID: template.id, amendment: "run only the smoke suite")
        await runtime.waitForPendingRestarts()

        // The reusable template's description is untouched — no welded per-run text.
        let templateAfter = await store.task(id: template.id)
        #expect(templateAfter?.description == "base description")

        // The cloned instance — which is what Brown's briefing reads fresh by id — carries BOTH the
        // base description and the per-run amendment.
        let instance = await store.allTasks().first { $0.parentTaskID == template.id }
        #expect(instance != nil)
        #expect(instance?.description.contains("base description") == true)
        #expect(instance?.description.contains("run only the smoke suite") == true)

        await runtime.stopAll()
    }

    @Test("Auto-advance never starts a template")
    func autoAdvanceSkipsTemplates() async {
        let runtime = makeRuntime()
        await runtime.setToolSecurity(preflightScoping: false, perCallCheck: false, globalPolicy: [:])
        await runtime.setAutoAdvance(true)
        await runtime.start()
        let store = await runtime.taskStore

        // A pending template + a pending normal task, both eligible for slots.
        let template = await store.addTask(title: "Template", description: "d", isTemplate: true)
        let normal = await store.addTask(title: "Normal", description: "d")

        // Drive the auto-advance drain (as a task-termination would).
        await runtime.drainPendingTaskQueueForTesting()
        await runtime.waitForPendingRestarts()

        // The normal task started; the template did not (no clone, still pending template).
        #expect(await store.task(id: normal.id)?.status == .running)
        let templateAfter = await store.task(id: template.id)
        #expect(templateAfter?.isTemplate == true)
        #expect(templateAfter?.status == .pending)
        #expect(await store.allTasks().contains { $0.parentTaskID == template.id } == false, "no instance was cloned by auto-advance")

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

    @Test("Cold boot validates running task that already has submitted result")
    func coldBootValidatesRunningTaskWithSubmittedResult() async {
        let runtime = makeRuntime()
        await runtime.setToolSecurity(preflightScoping: false, perCallCheck: false, globalPolicy: [:])
        let store = await runtime.taskStore
        let task = await store.addTask(title: "Reply to Drew", description: "Send the reply.")
        await store.updateStatus(id: task.id, status: .running)
        await store.setResult(id: task.id, result: "Reply sent.", commentary: nil)

        await runtime.start()
        let recovered = await waitUntil {
            let status = await store.task(id: task.id)?.status
            return status == .validating || status == .awaitingReview || status == .completed || status == .failed
        }

        #expect(recovered)
        let taskAfter = await store.task(id: task.id)
        #expect(taskAfter?.status != .interrupted)
        #expect(taskAfter?.result == "Reply sent.")

        await runtime.stopAll()
    }

    @Test("Cold boot resumes ALL interrupted tasks up to worker capacity, not just the first")
    func coldBootResumesAllInterruptedUpToCapacity() async {
        let runtime = makeRuntime(autoRunInterrupted: true)
        await runtime.setToolSecurity(preflightScoping: false, perCallCheck: false, globalPolicy: [:])
        await runtime.setWorkerCapacity(2)
        let store = await runtime.taskStore

        // Two tasks that were mid-run when the app quit.
        let a = await store.addTask(title: "A", description: "d")
        let b = await store.addTask(title: "B", description: "d")
        await store.updateStatus(id: a.id, status: .interrupted)
        await store.updateStatus(id: b.id, status: .interrupted)

        await runtime.start()

        #expect(await store.task(id: a.id)?.status == .running, "first interrupted task resumes")
        #expect(await store.task(id: b.id)?.status == .running, "the SECOND also resumes — both were running at quit")
        let aWorker = await store.task(id: a.id)?.assigneeIDs.first
        let bWorker = await store.task(id: b.id)?.assigneeIDs.first
        #expect(aWorker != nil && bWorker != nil && aWorker != bWorker, "each resumed task gets its own fresh worker")

        await runtime.stopAll()
    }

    @Test("Cold-boot resume is capped by capacity: at capacity 1, one of two interrupted tasks stays interrupted")
    func coldBootResumeCappedByCapacity() async {
        let runtime = makeRuntime(autoRunInterrupted: true)
        await runtime.setToolSecurity(preflightScoping: false, perCallCheck: false, globalPolicy: [:])
        await runtime.setWorkerCapacity(1)
        let store = await runtime.taskStore

        let a = await store.addTask(title: "A", description: "d")
        let b = await store.addTask(title: "B", description: "d")
        await store.updateStatus(id: a.id, status: .interrupted)
        await store.updateStatus(id: b.id, status: .interrupted)

        await runtime.start()

        let statuses = [await store.task(id: a.id)?.status, await store.task(id: b.id)?.status]
        #expect(statuses.filter { $0 == .running }.count == 1, "exactly one resumes at capacity 1")
        #expect(statuses.filter { $0 == .interrupted }.count == 1, "the other stays interrupted for a manual start")

        await runtime.stopAll()
    }

    @Test("Launch resume queue drains overflow interrupted tasks as slots free")
    func launchResumeQueueDrainsOverflow() async {
        let runtime = makeRuntime(autoRunInterrupted: true)
        await runtime.setToolSecurity(preflightScoping: false, perCallCheck: false, globalPolicy: [:])
        await runtime.setWorkerCapacity(2)
        let store = await runtime.taskStore
        func statusOf(_ id: UUID) async -> AgentTask.Status? { await store.task(id: id)?.status }

        let a = await store.addTask(title: "A", description: "d")
        let b = await store.addTask(title: "B", description: "d")
        let c = await store.addTask(title: "C", description: "d")
        for t in [a, b, c] { await store.updateStatus(id: t.id, status: .interrupted) }

        await runtime.start()

        // Capacity 2: two resume now, the third waits in the launch queue.
        var boot: [AgentTask.Status?] = []
        for t in [a, b, c] { boot.append(await statusOf(t.id)) }
        #expect(boot.filter { $0 == .running }.count == 2, "two resume at capacity")
        #expect(boot.filter { $0 == .interrupted }.count == 1, "the third waits, queued")

        // One running task completes and frees its slot.
        var freedID: UUID?
        for t in [a, b, c] where await statusOf(t.id) == .running { freedID = t.id; break }
        if let freedID {
            await runtime.terminateTaskAgents(taskID: freedID)
            await store.updateStatus(id: freedID, status: .completed)
        }
        await runtime.drainPendingTaskQueueForTesting()
        await runtime.waitForPendingRestarts()

        var after: [AgentTask.Status?] = []
        for t in [a, b, c] { after.append(await statusOf(t.id)) }
        #expect(after.filter { $0 == .interrupted }.count == 0, "the queued interrupted task resumed when a slot freed")
        #expect(after.filter { $0 == .running }.count == 2, "two running again (one completed, the queued one took its slot)")

        await runtime.stopAll()
    }

    @Test("A task Stopped MID-session is not re-resumed — only the launch batch auto-resumes")
    func midSessionStopStaysStopped() async {
        let runtime = makeRuntime(autoRunInterrupted: true)
        await runtime.setToolSecurity(preflightScoping: false, perCallCheck: false, globalPolicy: [:])
        await runtime.setWorkerCapacity(2)
        let store = await runtime.taskStore

        let a = await store.addTask(title: "A", description: "d")
        await store.updateStatus(id: a.id, status: .interrupted)

        await runtime.start()
        #expect(await store.task(id: a.id)?.status == .running, "the launch-time interrupt resumes")

        // The user Stops it mid-session — it becomes interrupted again, but is NOT on the
        // launch resume queue (it was removed when first resumed), so the drain leaves it be.
        await runtime.terminateTaskAgents(taskID: a.id)
        await store.updateStatus(id: a.id, status: .interrupted)
        await runtime.drainPendingTaskQueueForTesting()
        await runtime.waitForPendingRestarts()

        #expect(await store.task(id: a.id)?.status == .interrupted, "a mid-session Stop stays stopped; auto-resume does not re-run it")

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
