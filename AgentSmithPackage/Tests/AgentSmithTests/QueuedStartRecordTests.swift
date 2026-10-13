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
}
