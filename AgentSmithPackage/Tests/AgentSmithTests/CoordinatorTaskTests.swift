import Foundation
import Testing
import SemanticSearch
import SwiftLLMKit
@testable import AgentSmithKit

/// A worker can coordinate other tasks (decided 2026-10-05, user): it creates CHILD tasks that other
/// workers run, waits for them while staying alive (its task stays running), and is told each one's
/// outcome instead of Smith. When every live worker is a coordinator waiting on its children, one
/// child may start above capacity so the work always makes progress.
@Suite("Coordinator tasks")
struct CoordinatorTaskTests {

    private static let sharedEngine = SemanticSearchEngine()

    // MARK: - Briefing subscriber

    @Test("the coordinator is told how a child ended, never that it started")
    func coordinatorNotes() {
        let child = AgentTask(title: "Child", description: "d", result: "Built it.", coordinatorTaskID: UUID())
        func transition(to status: AgentTask.Status, cause: TaskTransitionCause) -> TaskStatusTransition {
            TaskStatusTransition(taskID: child.id, statusRevision: 1, from: .running, to: status, at: Date(), cause: cause)
        }
        let completed = CoordinatorTaskBriefing.note(for: transition(to: .completed, cause: .validationPassed(validationWasRun: true)), task: child)
        #expect(completed?.contains("COMPLETED") == true)
        #expect(completed?.contains("Built it.") == true)
        #expect(CoordinatorTaskBriefing.note(for: transition(to: .failed, cause: .userFailed), task: child)?.contains("FAILED") == true)
        #expect(CoordinatorTaskBriefing.note(for: transition(to: .awaitingReview, cause: .validationEscalated), task: child) != nil)
        #expect(CoordinatorTaskBriefing.note(for: transition(to: .running, cause: .workerStarted), task: child) == nil)

        #expect(CoordinatorTaskBriefing.replacesSmithBriefing(.workerStarted))
        #expect(CoordinatorTaskBriefing.replacesSmithBriefing(.validationPassed(validationWasRun: true)))
        #expect(!CoordinatorTaskBriefing.replacesSmithBriefing(.userAcceptanceRequested(validationWasRun: true)),
                "a sign-off park waits on the user, so Smith must still hear about it")
    }

    @Test("a child's outcome is recorded for its active coordinator, and the routine Smith note is not")
    func effectsWhileCoordinatorActive() async throws {
        let store = TaskStore()
        let coordinator = await store.addTask(title: "Coordinator", description: "d")
        _ = await store.driveStatus(id: coordinator.id, to: .running)
        let child = try await createChild(store, coordinator: coordinator.id)

        try await completeThroughValidation(store, child.id)
        let effects = try #require(await store.task(id: child.id)?.pendingEffects.map(\.effect))
        #expect(effects.contains { if case .coordinatorBriefing(let id, _) = $0 { return id == coordinator.id } else { return false } })
        #expect(!effects.contains { if case .smithBriefing = $0 { return true } else { return false } })
    }

    @Test("once the coordinator has finished, a child's outcome goes to Smith instead")
    func effectsAfterCoordinatorFinished() async throws {
        let store = TaskStore()
        let coordinator = await store.addTask(title: "Coordinator", description: "d")
        let child = try await createChild(store, coordinator: coordinator.id)
        _ = await store.driveStatus(id: coordinator.id, to: .completed)

        try await completeThroughValidation(store, child.id)
        let effects = try #require(await store.task(id: child.id)?.pendingEffects.map(\.effect))
        #expect(!effects.contains { if case .coordinatorBriefing = $0 { return true } else { return false } })
        #expect(effects.contains { if case .smithBriefing = $0 { return true } else { return false } })
    }

    // MARK: - Store

    @Test("a child is written whole, linked to its coordinator, and refused at the limit")
    func addChildTask() async throws {
        let store = TaskStore()
        let coordinator = await store.addTask(title: "Coordinator", description: "d")
        let criterion = AcceptanceCriterion(name: "Built", validationPrompt: "Check it built.", origin: .worker)
        let creation = await store.addChildTask(
            coordinatorTaskID: coordinator.id, limit: 2, title: "One", description: "d",
            descriptionAttachments: [], acceptanceCriteria: [criterion],
            steps: [TaskStep(text: "Build", origin: .worker)], requiredCapabilities: []
        )
        guard case .created(let first) = creation else {
            Issue.record("expected .created, got \(creation)")
            return
        }
        #expect(first.coordinatorTaskID == coordinator.id)
        #expect(first.acceptanceCriteria.map(\.name) == ["Built"])
        #expect(first.steps.map(\.text) == ["Build"])
        #expect(first.status == .pending)

        _ = try await createChild(store, coordinator: coordinator.id, limit: 2)
        let third = await store.addChildTask(
            coordinatorTaskID: coordinator.id, limit: 2, title: "Three", description: "d",
            descriptionAttachments: [], acceptanceCriteria: [], steps: [], requiredCapabilities: []
        )
        #expect(third == .limitReached(limit: 2))
        #expect(await store.childTasks(ofCoordinator: coordinator.id).count == 2)

        let orphan = await store.addChildTask(
            coordinatorTaskID: UUID(), limit: 2, title: "Orphan", description: "d",
            descriptionAttachments: [], acceptanceCriteria: [], steps: [], requiredCapabilities: []
        )
        #expect(orphan == .coordinatorNotFound)
    }

    // MARK: - Parking

    @Test("a child's outcome resumes only a worker waiting on its children")
    func childOutcomeResumesOnlyAWaitingWorker() {
        let agentID = UUID()
        let outcome = ChannelMessage(
            sender: .system, recipientID: agentID, content: "child done",
            metadata: ["messageKind": .kind(.childTaskOutcome)]
        )
        #expect(AgentActor.resumesParkedWorker(outcome, agentID: agentID, park: .awaitingChildTasks))
        #expect(!AgentActor.resumesParkedWorker(outcome, agentID: agentID, park: .awaitingHandoff),
                "a coordinator that already submitted its own work must not be pulled back by a child")
        let fromSmith = ChannelMessage(sender: .agent(.smith), recipientID: agentID, content: "also do X",
                                       metadata: ["messageKind": .kind(.orchestratorMessage)])
        #expect(AgentActor.resumesParkedWorker(fromSmith, agentID: agentID, park: .awaitingChildTasks))
    }

    // MARK: - Tools

    @Test("the coordination tools are Brown's, and only waiting is pre-cleared by security")
    func toolRegistration() {
        #expect(BrownBehavior.toolNames.contains("create_child_task"))
        #expect(BrownBehavior.toolNames.contains("wait_for_child_tasks"))
        #expect(!SmithBehavior.tools().contains { $0.name == "create_child_task" })
        #expect(WaitForChildTasksTool().successEffects == [.waitsForChildTasks])
        // Sequenced after any create_child_task in the same response, never run alongside it.
        #expect(AgentActor.taskLifecycleTools.contains("wait_for_child_tasks"))
        #expect(CreateChildTaskTool().successEffects.isEmpty)
    }

    @Test("create_child_task links the child, authors it as the worker, and asks the runtime to start it")
    func createChildTaskTool() async throws {
        let store = TaskStore()
        let coordinator = await store.addTask(title: "Coordinator", description: "d")
        let workerID = UUID()
        await store.assignAgent(taskID: coordinator.id, agentID: workerID)
        let started = StartRecorder()
        let context = makeContext(store: store, agentID: workerID, started: started, childLimit: 1)

        let result = try await CreateChildTaskTool().execute(
            arguments: [
                "title": .string("Audit A"),
                "description": .string("Audit module A."),
                "required_capabilities": .array([.string("Read source files")]),
                "steps": .array([.string("Read it")])
            ],
            context: context
        )
        #expect(result.succeeded, "\(result.output)")
        let child = try #require(await store.childTasks(ofCoordinator: coordinator.id).first)
        #expect(child.requiredCapabilities.first?.addedBy == .worker)
        #expect(child.steps.first?.origin == .worker)
        #expect(started.ids == [child.id])

        let refused = try await CreateChildTaskTool().execute(
            arguments: ["title": .string("Audit B"), "description": .string("Audit module B.")],
            context: context
        )
        #expect(!refused.succeeded, "the limit of 1 was not enforced")
        #expect(started.ids == [child.id])
    }

    @Test("wait_for_child_tasks waits only while a child is unfinished")
    func waitTool() async throws {
        let store = TaskStore()
        let coordinator = await store.addTask(title: "Coordinator", description: "d")
        let workerID = UUID()
        await store.assignAgent(taskID: coordinator.id, agentID: workerID)
        let context = makeContext(store: store, agentID: workerID, started: StartRecorder(), childLimit: 10)

        #expect(try await !WaitForChildTasksTool().execute(arguments: [:], context: context).succeeded,
                "waited with no children")
        let child = try await createChild(store, coordinator: coordinator.id)
        #expect(try await WaitForChildTasksTool().execute(arguments: [:], context: context).succeeded)
        _ = await store.driveStatus(id: child.id, to: .completed)
        let finished = try await WaitForChildTasksTool().execute(arguments: [:], context: context)
        #expect(!finished.succeeded, "waited for an outcome that already happened")
        #expect(finished.output.contains("Completed"))
    }

    // MARK: - Runtime: one start above capacity

    /// Capacity 1, auto-run OFF. The coordinator holds the only slot. Its child stays queued while
    /// the coordinator is working; the moment the coordinator's worker parks in
    /// `wait_for_child_tasks`, the child starts above capacity — and the coordinator's worker is
    /// still alive, its task still running.
    @Test("when every live worker waits on its children, one child starts above capacity")
    func overshootWhenAllWorkersWait() async throws {
        let gate = Gate()
        let runtime = makeRuntime(brownProvider: GatedWaitProvider(gate: gate))
        await runtime.setOrchestrationSettings(OrchestrationSettings.builtIn.applying(OrchestrationSettingsOverride(
            autoRunNextTask: false,
            autoRunInterruptedTasks: false,
            enableTaskCompletionValidators: false,
            scopeToolSetOnTaskStart: false
        )))
        await runtime.setWorkerCapacity(1)
        await runtime.start()
        let store = await runtime.taskStore

        let coordinator = await store.addTask(title: "Coordinator", description: "d")
        await runtime.restartForNewTask(taskID: coordinator.id, origin: .explicitUser)
        await runtime.waitForPendingRestarts()
        #expect(await store.task(id: coordinator.id)?.status == .running)
        let coordinatorWorker = try #require(await runtime.liveWorkerID(taskID: coordinator.id))

        let child = try await createChild(store, coordinator: coordinator.id)
        await runtime.drainPendingTaskQueueForTesting()
        await runtime.waitForPendingRestarts()
        #expect(await store.task(id: child.id)?.status == .pending,
                "the child started above capacity while its coordinator was still working")

        await gate.open()   // the coordinator's worker now calls wait_for_child_tasks
        let childStarted = await waitUntil { await store.task(id: child.id)?.startedAt != nil }
        #expect(childStarted, "the child never started although every live worker was waiting")
        #expect(await runtime.liveWorkerID(taskID: coordinator.id) == coordinatorWorker,
                "the waiting coordinator's worker was stopped")
        #expect(await store.task(id: coordinator.id)?.status == .running)
        await runtime.stopAll()
    }

    // MARK: - Helpers

    private func createChild(_ store: TaskStore, coordinator: UUID, limit: Int = 10) async throws -> AgentTask {
        let creation = await store.addChildTask(
            coordinatorTaskID: coordinator, limit: limit, title: "Child \(UUID().uuidString.prefix(4))", description: "d",
            descriptionAttachments: [], acceptanceCriteria: [], steps: [], requiredCapabilities: []
        )
        guard case .created(let child) = creation else {
            throw CoordinatorTestError.childNotCreated
        }
        return child
    }

    private enum CoordinatorTestError: Error { case childNotCreated, statusNotReached }

    /// Completes a task the way a real run does — validated, then passed — so the transition
    /// carries the cause Smith's briefing describes.
    private func completeThroughValidation(_ store: TaskStore, _ id: UUID) async throws {
        guard await store.driveStatus(id: id, to: .validating),
              await store.updateStatus(id: id, status: .completed, cause: .validationPassed(validationWasRun: true)) else {
            throw CoordinatorTestError.statusNotReached
        }
    }

    private final class StartRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var started: [UUID] = []
        var ids: [UUID] { lock.withLock { started } }
        func record(_ id: UUID) { lock.withLock { started.append(id) } }
    }

    private func makeContext(store: TaskStore, agentID: UUID, started: StartRecorder, childLimit: Int) -> ToolContext {
        ToolContext(
            agentID: agentID,
            agentRole: .brown,
            channel: MessageChannel(),
            taskStore: store,
            spawnBrown: { _ in nil },
            terminateAgent: { _, _ in false },
            abort: { _, _ in },
            agentRoleForID: { _ in .brown },
            startChildTask: { started.record($0) },
            maxChildTasksPerTask: { childLimit },
            memoryStore: MemoryStore(engine: Self.sharedEngine),
            setToolExecutionStatus: { _, _ in },
            hasToolSucceeded: { _ in false },
            hasToolFailed: { _ in false }
        )
    }

    /// Holds its caller until the test opens it.
    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    /// Every worker's model: blocks until the gate opens, then asks to wait for child tasks.
    private final class GatedWaitProvider: LLMProvider, @unchecked Sendable {
        private let gate: Gate
        init(gate: Gate) { self.gate = gate }

        func send(messages: [LLMMessage], tools: [LLMToolDefinition], overrides: LLMCallOverrides) async throws -> LLMResponse {
            await gate.wait()
            return LLMResponse(toolCalls: [LLMToolCall(id: "c\(UUID().uuidString.prefix(8))", name: "wait_for_child_tasks", arguments: "{}")])
        }
    }

    private func waitUntil(timeout: Duration = .seconds(30), _ predicate: @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return await predicate()
    }

    private func makeRuntime(brownProvider: any LLMProvider) -> OrchestrationRuntime {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-smith-coordinator-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let config = ModelConfiguration(name: "test", providerID: "test", modelID: "test-model")
        return OrchestrationRuntime(
            providers: [
                .smith: MockLLMProvider(responses: [LLMResponse(text: "Standing by.")]),
                .securityAgent: MockLLMProvider(responses: [LLMResponse(text: "SAFE")]),
                .brown: brownProvider
            ],
            configurations: [.smith: config, .securityAgent: config, .brown: config],
            providerAPITypes: [:],
            agentTuning: [
                .brown: AgentTuningConfig(pollInterval: 3600),
                .smith: AgentTuningConfig(pollInterval: 3600),
                .securityAgent: AgentTuningConfig(pollInterval: 3600)
            ],
            semanticSearchEngine: Self.sharedEngine,
            usageStore: UsageStore(persistence: PersistenceManager(testingRoot: tmpRoot)),
            autoAdvanceEnabled: false,
            autoRunInterruptedTasks: false,
            memoryStore: nil
        )
    }
}
