import Foundation
import Testing
import SemanticSearch
@testable import AgentSmithKit

/// #37: the runtime keeps ONE record of task starts queued on the lifecycle queue. Before it, every
/// drain pass queued another start for each still-pending task while the queue was backed up behind
/// scoping calls, `create_task` queued a start for every new task past capacity, and a stale start
/// for a task deleted meanwhile posted "Could not start task …: it was not found in the task store."
@Suite("Queued-start record (#37)")
struct QueuedStartRecordTests {

    private static let holdMarker = "HOLD-SCOPE"

    /// The Security Agent's model: scoping for a task titled with `holdMarker` waits until the test
    /// opens the gate (cancellably); everything else is approved at once.
    private final class GatedScopingProvider: LLMProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var open = false
        private var _heldCalls = 0
        var heldCalls: Int { lock.withLock { _heldCalls } }
        func release() { lock.withLock { open = true } }

        func send(messages: [LLMMessage], tools: [LLMToolDefinition], overrides: LLMCallOverrides) async throws -> LLMResponse {
            let held = messages.contains { message in
                guard case .text(let text) = message.content else { return false }
                return text.contains(QueuedStartRecordTests.holdMarker)
            }
            if held {
                lock.withLock { _heldCalls += 1 }
                while !lock.withLock({ open }) {
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
            return LLMResponse(text: "{\"toolResponses\":[{\"toolID\":\"file_read\",\"isAllowed\":true}]}")
        }
    }

    private func makeRuntime(security: GatedScopingProvider, capacity: Int, autoRunNextTask: Bool) async throws -> OrchestrationRuntime {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-smith-queued-start-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let configuration = ModelConfiguration(name: "test", providerID: "test", modelID: "test-model")
        let runtime = OrchestrationRuntime(
            providers: [
                .smith: MockLLMProvider(responses: [LLMResponse(text: "Standing by.")]),
                .securityAgent: security,
                .brown: StillThinkingLLMProvider()
            ],
            configurations: [.smith: configuration, .securityAgent: configuration, .brown: configuration],
            providerAPITypes: [:],
            agentTuning: [:],
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
            scopeToolSetOnTaskStart: true
        )))
        await runtime.setWorkerCapacity(capacity)
        await runtime.start()
        return runtime
    }

    private func waitUntil(timeout: Duration = .seconds(30), _ predicate: @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return await predicate()
    }

    @Test("repeated drains queue one start for a pending task, and its stale start after a delete posts no error")
    func drainsQueueOneStartAndDeletedTaskIsSilent() async throws {
        let security = GatedScopingProvider()
        let runtime = try await makeRuntime(security: security, capacity: 3, autoRunNextTask: true)
        let store = await runtime.taskStore

        // Hold the queue: a start stuck in its scoping call.
        let holder = await store.addTask(title: "\(Self.holdMarker) holder", description: "d")
        await runtime.restartForNewTask(taskID: holder.id, origin: .explicitUser)
        #expect(await waitUntil { security.heldCalls == 1 })

        // While it holds, every drain pass would queue another start for the still-pending task.
        let queued = await store.addTask(title: "Queued", description: "d")
        for _ in 0..<3 { await runtime.drainPendingTaskQueueForTesting() }
        #expect(await runtime.queuedStartCount(taskID: queued.id) == 1, "a drain queued a second start for a task that already had one")

        // Deleted before its start runs: the start finds nothing, and that is not an error.
        #expect(await store.softDelete(id: queued.id))
        security.release()
        #expect(await waitUntil { await runtime.queuedStartCount(taskID: queued.id) == 0 })
        let falseErrors = await runtime.channel.allMessages().filter { $0.content.contains("it was not found in the task store") }
        #expect(falseErrors.isEmpty, "\(falseErrors.map(\.content))")

        await runtime.stopAll()
    }

    /// A reservation holds a slot back from the drain; when its start ends WITHOUT a worker (its
    /// task deleted meanwhile, or refused), that slot is free again, and nothing else would notice.
    @Test("a queued start that ends without a worker hands its slot to the next pending task")
    func freedReservationStartsNextTask() async throws {
        let security = GatedScopingProvider()
        let runtime = try await makeRuntime(security: security, capacity: 3, autoRunNextTask: true)
        let store = await runtime.taskStore

        let running = await store.addTask(title: "Running", description: "d")
        await runtime.restartForNewTask(taskID: running.id, origin: .explicitUser)
        await runtime.waitForPendingRestarts()
        #expect(await runtime.liveWorkerID(taskID: running.id) != nil)

        // Slot 2: held in scoping. Slot 3: reserved by a start queued behind it.
        let holder = await store.addTask(title: "\(Self.holdMarker) holder", description: "d")
        await runtime.restartForNewTask(taskID: holder.id, origin: .explicitUser)
        #expect(await waitUntil { security.heldCalls == 1 })
        let doomed = await store.addTask(title: "Doomed", description: "d")
        await runtime.restartForNewTask(taskID: doomed.id, origin: .explicitUser)

        // Every slot is spoken for, so the next pending task waits.
        let next = await store.addTask(title: "Next", description: "d")
        await runtime.drainPendingTaskQueueForTesting()
        #expect(await runtime.queuedStartCount(taskID: next.id) == 0)

        // The reserved start's task goes away; when that start ends, its slot goes to `next`.
        #expect(await store.softDelete(id: doomed.id))
        security.release()
        #expect(await waitUntil { await runtime.liveWorkerID(taskID: next.id) != nil },
                "the slot a vanished task's start had reserved was never handed on")

        await runtime.stopAll()
    }

    @Test("create_task counts starts already queued against free slots")
    func createTaskCountsQueuedStarts() async throws {
        let security = GatedScopingProvider()
        let runtime = try await makeRuntime(security: security, capacity: 2, autoRunNextTask: false)
        let store = await runtime.taskStore
        let smithID = try #require(await runtime.agentIDForRole(.smith))

        // Slot 1: a start held in scoping. Slot 2: a start queued behind it, not yet claimed.
        let holder = await store.addTask(title: "\(Self.holdMarker) holder", description: "d")
        await runtime.restartForNewTask(taskID: holder.id, origin: .explicitUser)
        #expect(await waitUntil { security.heldCalls == 1 })
        let behind = await store.addTask(title: "Behind", description: "d")
        await runtime.restartForNewTask(taskID: behind.id, origin: .explicitUser)
        #expect(await runtime.queuedStartCount(taskID: behind.id) == 1)

        let context = await runtime.makeToolContext(agentID: smithID, role: .smith)
        let result = try await CreateTaskTool().execute(
            arguments: ["title": .string("Third"), "description": .string("d")],
            context: context
        )
        #expect(result.succeeded, "\(result.output)")
        #expect(result.output.contains("slot(s) are busy"), "create_task started a task past capacity: \(result.output)")
        let third = try #require(await store.allTasks().first { $0.title == "Third" })
        #expect(await runtime.queuedStartCount(taskID: third.id) == 0)

        security.release()
        await runtime.stopAll()
    }

    // MARK: - run_task shares the slot rule (stupid-check #1)

    private func heldHolderAndQueuedBehind(_ runtime: OrchestrationRuntime, _ security: GatedScopingProvider) async throws -> AgentTask {
        let store = await runtime.taskStore
        let holder = await store.addTask(title: "\(Self.holdMarker) holder", description: "d")
        await runtime.restartForNewTask(taskID: holder.id, origin: .explicitUser)
        #expect(await waitUntil { security.heldCalls == 1 })
        let behind = await store.addTask(title: "Behind", description: "d")
        await runtime.restartForNewTask(taskID: behind.id, origin: .explicitUser)
        return behind
    }

    @Test("run_task counts starts already queued against free slots")
    func runTaskCountsQueuedStarts() async throws {
        let security = GatedScopingProvider()
        let runtime = try await makeRuntime(security: security, capacity: 2, autoRunNextTask: false)
        let store = await runtime.taskStore
        let smithID = try #require(await runtime.agentIDForRole(.smith))
        _ = try await heldHolderAndQueuedBehind(runtime, security)
        let target = await store.addTask(title: "Target", description: "d")

        let context = await runtime.makeToolContext(agentID: smithID, role: .smith)
        let result = try await RunTaskTool().execute(
            arguments: ["task_id": .string(target.id.uuidString), "instructions": .string("go")], context: context)
        #expect(!result.succeeded, "run_task claimed a start past capacity: \(result.output)")
        #expect(await runtime.queuedStartCount(taskID: target.id) == 0)
        #expect(await store.task(id: target.id)?.status == .pending)
        #expect(await store.task(id: target.id)?.description == "d", "a refused run_task amended the task")

        security.release()
        await runtime.stopAll()
    }

    @Test("run_task on a task whose own start is queued queues no second start")
    func runTaskOnOwnQueuedStartIsRefused() async throws {
        let security = GatedScopingProvider()
        let runtime = try await makeRuntime(security: security, capacity: 3, autoRunNextTask: false)
        let store = await runtime.taskStore
        let smithID = try #require(await runtime.agentIDForRole(.smith))
        let behind = try await heldHolderAndQueuedBehind(runtime, security)

        let context = await runtime.makeToolContext(agentID: smithID, role: .smith)
        let result = try await RunTaskTool().execute(
            arguments: ["task_id": .string(behind.id.uuidString), "instructions": .string("extra")], context: context)
        #expect(!result.succeeded, "\(result.output)")
        #expect(await runtime.queuedStartCount(taskID: behind.id) == 1, "run_task queued a duplicate start")
        #expect(await store.task(id: behind.id)?.description == "d", "a refused run_task amended the task")

        security.release()
        await runtime.stopAll()
    }

    @Test("run_task on a template at capacity queues its instance and does not claim it is running")
    func runTaskTemplateAtCapacityQueuesInstance() async throws {
        let security = GatedScopingProvider()
        let runtime = try await makeRuntime(security: security, capacity: 2, autoRunNextTask: false)
        let store = await runtime.taskStore
        let smithID = try #require(await runtime.agentIDForRole(.smith))
        _ = try await heldHolderAndQueuedBehind(runtime, security)
        let template = await store.addTask(title: "Nightly", description: "d", isTemplate: true)
        let before = Set(await store.allTasks().map(\.id))

        let context = await runtime.makeToolContext(agentID: smithID, role: .smith)
        let result = try await RunTaskTool().execute(
            arguments: ["task_id": .string(template.id.uuidString), "instructions": .string("go")], context: context)
        #expect(result.succeeded, "\(result.output)")
        let instances = await store.allTasks().filter { !before.contains($0.id) }
        let instance = try #require(instances.count == 1 ? instances[0] : nil)
        #expect(result.output.contains(instance.id.uuidString))
        #expect(!result.output.contains("Running task"), "\(result.output)")
        #expect(await runtime.queuedStartCount(taskID: instance.id) == 1)

        security.release()
        #expect(await waitUntil { await runtime.queuedStartCount(taskID: instance.id) == 0 })
        #expect(await store.task(id: instance.id)?.status == .pending)
        #expect(await runtime.liveWorkerID(taskID: instance.id) == nil)
        await runtime.stopAll()
    }

    @Test("run_task starts a task when only a slot holder, and no queued start, is ahead of it")
    func runTaskStartsWhenSlotFree() async throws {
        let security = GatedScopingProvider()
        let runtime = try await makeRuntime(security: security, capacity: 2, autoRunNextTask: false)
        let store = await runtime.taskStore
        let smithID = try #require(await runtime.agentIDForRole(.smith))
        let holder = await store.addTask(title: "\(Self.holdMarker) holder", description: "d")
        await runtime.restartForNewTask(taskID: holder.id, origin: .explicitUser)
        #expect(await waitUntil { security.heldCalls == 1 })
        let target = await store.addTask(title: "Target", description: "d")

        let context = await runtime.makeToolContext(agentID: smithID, role: .smith)
        let result = try await RunTaskTool().execute(
            arguments: ["task_id": .string(target.id.uuidString), "instructions": .string("go")], context: context)
        #expect(result.succeeded, "\(result.output)")
        #expect(await runtime.queuedStartCount(taskID: target.id) == 1)

        security.release()
        await runtime.stopAll()
    }

    // MARK: - A clone's start is reserved under the clone (stupid-check #2)

    @Test("a template's start counts as one slot while its instance scopes")
    func templateStartCountsOneSlot() async throws {
        let security = GatedScopingProvider()
        let runtime = try await makeRuntime(security: security, capacity: 2, autoRunNextTask: false)
        let store = await runtime.taskStore
        let smithID = try #require(await runtime.agentIDForRole(.smith))

        let template = await store.addTask(title: "\(Self.holdMarker) template", description: "d", isTemplate: true)
        await runtime.restartForNewTask(taskID: template.id, origin: .explicitUser)
        #expect(await waitUntil { security.heldCalls == 1 })
        let instances = await store.allTasks().filter { $0.parentTaskID == template.id && !$0.isTemplate }
        let instance = try #require(instances.count == 1 ? instances[0] : nil)
        #expect(instance.status == .starting)
        #expect(await runtime.queuedStartCount(taskID: template.id) == 0)
        #expect(await runtime.queuedStartCount(taskID: instance.id) == 1)

        let context = await runtime.makeToolContext(agentID: smithID, role: .smith)
        let result = try await CreateTaskTool().execute(
            arguments: ["title": .string("Third"), "description": .string("d")], context: context)
        #expect(result.succeeded, "\(result.output)")
        #expect(!result.output.contains("slot(s) are busy"), "one template start took two slots: \(result.output)")

        security.release()
        #expect(await waitUntil { await runtime.liveWorkerID(taskID: instance.id) != nil })
        await runtime.stopAll()
    }

    @Test("a template started on the cold path gets one start, not two")
    func coldTemplateStartQueuesOneStart() async throws {
        let security = GatedScopingProvider()
        let runtime = try await makeRuntime(security: security, capacity: 2, autoRunNextTask: true)
        let store = await runtime.taskStore
        await runtime.stopAll()  // no Smith: the next start takes the cold path

        let template = await store.addTask(title: "\(Self.holdMarker) template", description: "d", isTemplate: true)
        await runtime.restartForNewTask(taskID: template.id, origin: .explicitUser)
        #expect(await waitUntil { security.heldCalls == 1 })
        let instances = await store.allTasks().filter { $0.parentTaskID == template.id && !$0.isTemplate }
        let instance = try #require(instances.count == 1 ? instances[0] : nil)
        let startsQueued = await runtime.queuedStartCount(taskID: template.id) + runtime.queuedStartCount(taskID: instance.id)
        #expect(startsQueued == 1, "the launch drain queued a second start for the template's instance")

        security.release()
        #expect(await waitUntil { await runtime.liveWorkerID(taskID: instance.id) != nil })
        #expect(await waitUntil { await runtime.taskIDsWithQueuedStart().isEmpty })
        await runtime.stopAll()
    }

    @Test("a template start that cannot make its instance leaves no reservation behind")
    func failedInstantiationReleasesReservation() async throws {
        let security = GatedScopingProvider()
        let runtime = try await makeRuntime(security: security, capacity: 2, autoRunNextTask: true)
        let store = await runtime.taskStore
        let template = await store.addTask(
            title: "Needs input", description: "d", isTemplate: true,
            templateInputDefinitions: [TemplateInputDefinition(name: "target", description: "t", required: true)]
        )
        await runtime.restartForNewTask(taskID: template.id, origin: .explicitUser)
        await runtime.waitForPendingRestarts()
        #expect(await runtime.taskIDsWithQueuedStart().isEmpty)
        #expect(await store.allTasks().allSatisfy { $0.parentTaskID != template.id })
        let refusals = await runtime.channel.allMessages().filter {
            $0.kind == .taskLifecycle && $0.content.contains("Could not start template")
        }
        #expect(refusals.count == 1)
        await runtime.stopAll()
    }
}
