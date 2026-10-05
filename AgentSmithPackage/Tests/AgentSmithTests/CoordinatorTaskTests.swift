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
            steps: [TaskStep(text: "Build", origin: .worker)], requiredCapabilities: [],
            relevantContext: .none
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
            descriptionAttachments: [], acceptanceCriteria: [], steps: [], requiredCapabilities: [],
            relevantContext: .none
        )
        #expect(third == .limitReached(limit: 2))
        #expect(await store.childTasks(ofCoordinator: coordinator.id).count == 2)

        let orphan = await store.addChildTask(
            coordinatorTaskID: UUID(), limit: 2, title: "Orphan", description: "d",
            descriptionAttachments: [], acceptanceCriteria: [], steps: [], requiredCapabilities: [],
            relevantContext: .none
        )
        #expect(orphan == .coordinatorNotFound)
    }

    @Test("the limit counts every child ever created, a permanently deleted one included")
    func limitCountsDeletedChildren() async throws {
        let store = TaskStore()
        let coordinator = await store.addTask(title: "Coordinator", description: "d")
        let child = try await createChild(store, coordinator: coordinator.id, limit: 1)
        #expect(await store.permanentlyDelete(id: child.id))
        #expect(await store.task(id: coordinator.id)?.childTasksCreated == 1)
        let next = await store.addChildTask(
            coordinatorTaskID: coordinator.id, limit: 1, title: "Again", description: "d",
            descriptionAttachments: [], acceptanceCriteria: [], steps: [], requiredCapabilities: [],
            relevantContext: .none
        )
        #expect(next == .limitReached(limit: 1))
    }

    @Test("an unfinished child with the same title is refused as a duplicate; a finished one is not")
    func duplicateTitleRefused() async throws {
        let store = TaskStore()
        let coordinator = await store.addTask(title: "Coordinator", description: "d")
        func add(_ title: String) async -> TaskStore.ChildTaskCreation {
            await store.addChildTask(
                coordinatorTaskID: coordinator.id, limit: 10, title: title, description: "d",
                descriptionAttachments: [], acceptanceCriteria: [], steps: [], requiredCapabilities: [],
                relevantContext: .none
            )
        }
        guard case .created(let first) = await add("Audit A") else {
            Issue.record("first child not created")
            return
        }
        #expect(await add("audit a") == .duplicateOfUnfinishedChild(first))
        _ = await store.driveStatus(id: first.id, to: .completed)
        guard case .created = await add("Audit A") else {
            Issue.record("a finished child blocked a new one with its title")
            return
        }
    }

    @Test("the counter survives a round trip and is absent from a task that created no children")
    func childCounterPersists() throws {
        var task = AgentTask(title: "T", description: "d")
        #expect(try !String(decoding: JSONEncoder().encode(task), as: UTF8.self).contains("childTasksCreated"))
        task.childTasksCreated = 3
        let decoded = try JSONDecoder().decode(AgentTask.self, from: JSONEncoder().encode(task))
        #expect(decoded.childTasksCreated == 3)
    }

    @Test("a child can't become a template while its coordinator is open")
    func childPromotionRefused() async throws {
        let store = TaskStore()
        let coordinator = await store.addTask(title: "Coordinator", description: "d")
        let child = try await createChild(store, coordinator: coordinator.id)
        #expect(await store.setTemplate(id: child.id, isTemplate: true) != nil)
        _ = await store.driveStatus(id: coordinator.id, to: .completed)
        #expect(await store.setTemplate(id: child.id, isTemplate: true) == nil)
        let template = try #require(await store.taskOrLibraryTemplate(id: child.id))
        #expect(template.coordinatorTaskID == nil, "a template is nobody's child")
    }

    // MARK: - Child progress

    @Test("each child status classifies for its waiting coordinator")
    func childProgressTable() {
        func progress(_ status: AgentTask.Status, disposition: AgentTask.TaskDisposition = .active,
                      holds: Bool = false, resumes: Bool = false) -> ChildTaskProgress {
            var task = AgentTask(title: "C", description: "d", status: status, disposition: disposition)
            if holds { task.startHolds = [TaskStartHold(watchedTaskID: UUID(), watchID: UUID())] }
            return task.progressAsChildTask(resumesAutomatically: resumes)
        }
        #expect(progress(.completed) == .finished)
        #expect(progress(.completed, disposition: .archived) == .finished, "an archived finished child is finished")
        #expect(progress(.failed) == .finished)
        #expect(progress(.running) == .progressing)
        #expect(progress(.pending) == .progressing)
        #expect(progress(.pending, holds: true) == .waitingOnOthers(.startHold))
        #expect(progress(.awaitingHelp) == .waitingOnOthers(.smith))
        #expect(progress(.awaitingReview) == .waitingOnOthers(.user))
        #expect(progress(.paused) == .stalled(.paused))
        #expect(progress(.interrupted) == .stalled(.interrupted))
        #expect(progress(.interrupted, resumes: true) == .progressing)
        #expect(progress(.pending, disposition: .archived) == .stalled(.leftActive(.archived)))
    }

    @Test("a stop the coordinator must react to is noted; one that resumes on its own is not")
    func stallNotes() {
        let child = AgentTask(title: "Child", description: "d", coordinatorTaskID: UUID())
        func note(_ to: AgentTask.Status, _ cause: TaskTransitionCause) -> String? {
            CoordinatorTaskBriefing.note(
                for: TaskStatusTransition(taskID: child.id, statusRevision: 2, from: .running, to: to, at: Date(), cause: cause),
                task: child
            )
        }
        #expect(note(.paused, .userPaused)?.contains("PAUSED by the user") == true)
        #expect(note(.interrupted, .userStopped)?.contains("STOPPED by the user") == true)
        #expect(note(.interrupted, .orphanRecovered)?.contains("worker was lost") == true)
        #expect(note(.interrupted, .capacityShed) == nil, "a capacity-shed child resumes on its own")
        #expect(note(.interrupted, .sessionShutdown) == nil)
    }

    @Test("an unfinished child archived under an open coordinator is reported; a finished one with nothing owed is not")
    func departureEmitted() async throws {
        let store = TaskStore()
        let coordinator = await store.addTask(title: "Coordinator", description: "d")
        _ = await store.driveStatus(id: coordinator.id, to: .running)
        let unfinished = try await createChild(store, coordinator: coordinator.id)
        let finished = try await createChild(store, coordinator: coordinator.id)
        _ = await store.driveStatus(id: finished.id, to: .failed)
        for record in await store.task(id: finished.id)?.pendingEffects ?? [] {
            await store.completeEffect(taskID: finished.id, recordID: record.id)
        }
        let events = StoreEventCollector()
        await store.setEventObserver { events.append($0) }

        #expect(await store.archive(id: unfinished.id))
        #expect(await store.archive(id: finished.id))
        let departures = events.values.compactMap { event -> CoordinatorChildDeparture? in
            if case .childLeftCoordination(let departure) = event { return departure }
            return nil
        }
        #expect(departures.map(\.child.id) == [unfinished.id])
        #expect(departures.first?.departure == .leftActive(.archived))
        #expect(departures.first.map(CoordinatorTaskBriefing.departureNote)?.contains("ARCHIVED") == true)
    }

    @Test("promoting a task to a template reports that it stopped coordinating")
    func promotionEmitsEvent() async throws {
        let store = TaskStore()
        let coordinator = await store.addTask(title: "Coordinator", description: "d")
        let events = StoreEventCollector()
        await store.setEventObserver { events.append($0) }
        #expect(await store.setTemplate(id: coordinator.id, isTemplate: true) == nil)
        #expect(events.values.contains(.promotedToTemplate(taskID: coordinator.id)))
    }

    @Test("a child's routing line follows its coordinator")
    func routingDescription() {
        #expect(CoordinatorTaskBriefing.routingDescription(coordinator: nil).contains("no longer exists"))
        let open = AgentTask(title: "C", description: "d", status: .running)
        #expect(CoordinatorTaskBriefing.routingDescription(coordinator: open).contains("reported to that task's worker"))
        let closed = AgentTask(title: "C", description: "d", status: .completed)
        #expect(CoordinatorTaskBriefing.routingDescription(coordinator: closed).contains("closed (completed)"))
    }

    // MARK: - Parking

    @Test("a worker takes its queued notes only after its briefing turn, and not once it handed its work off")
    func workerQueueGate() {
        #expect(!AgentActor.workerTakesQueuedNotifications(hasCompletedLLMTurn: false, park: nil),
                "a note about the task's children before the worker has read the task")
        #expect(AgentActor.workerTakesQueuedNotifications(hasCompletedLLMTurn: true, park: nil))
        #expect(AgentActor.workerTakesQueuedNotifications(hasCompletedLLMTurn: true, park: .awaitingChildTasks))
        #expect(!AgentActor.workerTakesQueuedNotifications(hasCompletedLLMTurn: true, park: .awaitingHandoff),
                "a coordinator that already submitted its own work must not be pulled back by a child")
    }

    @Test("a message addressed to a parked worker resumes it unless it is informational")
    func addressedMessageResumes() {
        let agentID = UUID()
        let fromSmith = ChannelMessage(sender: .agent(.smith), recipientID: agentID, content: "also do X",
                                       metadata: ["messageKind": .kind(.orchestratorMessage)])
        #expect(AgentActor.resumesParkedWorker(fromSmith, agentID: agentID))
        #expect(!AgentActor.resumesParkedWorker(fromSmith, agentID: UUID()))
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

        let paused = try await createChild(store, coordinator: coordinator.id)
        _ = await store.driveStatus(id: paused.id, to: .paused)
        let stalled = try await WaitForChildTasksTool().execute(arguments: [:], context: context)
        #expect(!stalled.succeeded, "waited on a paused child nobody will resume")
        #expect(stalled.output.contains("Not waiting"))
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

    /// Capacity 2: the coordinator waits on its child, which is running. The user cuts capacity to
    /// 1, which sheds the child (newest). The coordinator is now the only live worker, waiting on a
    /// child that is capacity-deferred — nothing running can free a slot. The cut drains, and the
    /// child resumes above the new limit (before the fix it waited forever: the drain neither ran on
    /// a cut nor looked at the deferred queue above capacity).
    @Test("a capacity cut under a waiting coordinator resumes its shed child above the limit")
    func capacityCutResumesShedChild() async throws {
        let gate = Gate()
        let runtime = makeRuntime(brownProvider: CoordinatorOrChildProvider(gate: gate, coordinatorMarker: Self.coordinatorMarker))
        await runtime.setOrchestrationSettings(OrchestrationSettings.builtIn.applying(OrchestrationSettingsOverride(
            autoRunNextTask: false,
            autoRunInterruptedTasks: false,
            enableTaskCompletionValidators: false,
            scopeToolSetOnTaskStart: false
        )))
        await runtime.setWorkerCapacity(2)
        await runtime.start()
        let store = await runtime.taskStore

        let coordinator = await store.addTask(title: "Coordinator", description: Self.coordinatorMarker)
        await runtime.restartForNewTask(taskID: coordinator.id, origin: .explicitUser)
        await runtime.waitForPendingRestarts()
        let child = try await createChild(store, coordinator: coordinator.id)
        await runtime.drainPendingTaskQueueForTesting()
        await runtime.waitForPendingRestarts()
        #expect(await waitUntil { await store.task(id: child.id)?.status == .running }, "the child never started below capacity")

        await gate.open()   // the coordinator's worker now waits on its child
        let firstChildWorker = await runtime.liveWorkerID(taskID: child.id)
        await runtime.setWorkerCapacity(1)
        await runtime.waitForPendingRestarts()
        let resumed = await waitUntil {
            guard await store.task(id: child.id)?.status == .running else { return false }
            guard let worker = await runtime.liveWorkerID(taskID: child.id) else { return false }
            return worker != firstChildWorker
        }
        #expect(resumed, "the shed child was never resumed although its coordinator waited on it")
        #expect(await store.task(id: coordinator.id)?.status == .running)
        await runtime.stopAll()
    }

    /// The child's outcome reaches the coordinator's worker through its durable broker queue and
    /// wakes it from `wait_for_child_tasks` — the worker stays alive, its task running.
    @Test("a child's outcome is delivered through the broker to the waiting coordinator, waking it")
    func outcomeDeliveredThroughBroker() async throws {
        let recorder = CoordinatorWakeRecorder()
        let runtime = makeRuntime(brownProvider: WakeRecordingProvider(recorder: recorder, coordinatorMarker: Self.coordinatorMarker))
        await runtime.setOrchestrationSettings(OrchestrationSettings.builtIn.applying(OrchestrationSettingsOverride(
            autoRunNextTask: false,
            autoRunInterruptedTasks: false,
            enableTaskCompletionValidators: false,
            scopeToolSetOnTaskStart: false
        )))
        await runtime.setWorkerCapacity(2)
        await runtime.start()
        let store = await runtime.taskStore

        let coordinator = await store.addTask(title: "Coordinator", description: Self.coordinatorMarker)
        let child = try await createChild(store, coordinator: coordinator.id)
        await runtime.restartForNewTask(taskID: coordinator.id, origin: .explicitUser)
        await runtime.waitForPendingRestarts()
        let coordinatorWorker = try #require(await runtime.liveWorkerID(taskID: coordinator.id))
        #expect(await waitUntil { await recorder.waitCalls >= 1 }, "the coordinator never waited")

        try await completeThroughValidation(store, child.id)
        let woken = await waitUntil { await recorder.sawNote(containing: "COMPLETED") }
        #expect(woken, "the coordinator was not woken with its child's outcome")
        #expect(await runtime.liveWorkerID(taskID: coordinator.id) == coordinatorWorker)
        #expect(await store.task(id: coordinator.id)?.status == .running)
        await runtime.stopAll()
    }

    private actor CoordinatorWakeRecorder {
        private(set) var waitCalls = 0
        private var texts: [String] = []
        func recordWait() { waitCalls += 1 }
        func record(_ newTexts: [String]) { texts.append(contentsOf: newTexts) }
        func sawNote(containing fragment: String) -> Bool { texts.contains { $0.contains(fragment) } }
    }

    /// The coordinator waits on its children at once, then records what woke it and thinks forever;
    /// a child's model thinks forever. Sleeps are cancellable so teardown is clean.
    private final class WakeRecordingProvider: LLMProvider, @unchecked Sendable {
        private let recorder: CoordinatorWakeRecorder
        private let coordinatorMarker: String
        init(recorder: CoordinatorWakeRecorder, coordinatorMarker: String) {
            self.recorder = recorder
            self.coordinatorMarker = coordinatorMarker
        }

        func send(messages: [LLMMessage], tools: [LLMToolDefinition], overrides: LLMCallOverrides) async throws -> LLMResponse {
            let texts = messages.compactMap { message -> String? in
                guard case .text(let text) = message.content else { return nil }
                return text
            }
            guard texts.contains(where: { $0.contains(coordinatorMarker) }) else {
                try await Task.sleep(for: .seconds(3600))
                return LLMResponse(text: "unreachable")
            }
            if await recorder.waitCalls == 0 {
                await recorder.recordWait()
                return LLMResponse(toolCalls: [LLMToolCall(id: "c\(UUID().uuidString.prefix(8))", name: "wait_for_child_tasks", arguments: "{}")])
            }
            await recorder.record(texts)
            try await Task.sleep(for: .seconds(3600))
            return LLMResponse(text: "unreachable")
        }
    }

    private static let coordinatorMarker = "COORDINATOR-MARKER-7f3a"

    /// The coordinator's model waits on its children once the gate opens; a child's model thinks
    /// forever (cancellably, so a shed worker stops cleanly).
    private final class CoordinatorOrChildProvider: LLMProvider, @unchecked Sendable {
        private let gate: Gate
        private let coordinatorMarker: String
        init(gate: Gate, coordinatorMarker: String) {
            self.gate = gate
            self.coordinatorMarker = coordinatorMarker
        }

        func send(messages: [LLMMessage], tools: [LLMToolDefinition], overrides: LLMCallOverrides) async throws -> LLMResponse {
            let isCoordinator = messages.contains { message in
                guard case .text(let text) = message.content else { return false }
                return text.contains(coordinatorMarker)
            }
            guard isCoordinator else {
                try await Task.sleep(for: .seconds(3600))
                return LLMResponse(text: "unreachable")
            }
            await gate.wait()
            return LLMResponse(toolCalls: [LLMToolCall(id: "c\(UUID().uuidString.prefix(8))", name: "wait_for_child_tasks", arguments: "{}")])
        }
    }

    // MARK: - Helpers

    private func createChild(_ store: TaskStore, coordinator: UUID, limit: Int = 10) async throws -> AgentTask {
        let creation = await store.addChildTask(
            coordinatorTaskID: coordinator, limit: limit, title: "Child \(UUID().uuidString.prefix(4))", description: "d",
            descriptionAttachments: [], acceptanceCriteria: [], steps: [], requiredCapabilities: [],
            relevantContext: .none
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

    private final class StoreEventCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var collected: [TaskStoreEvent] = []
        var values: [TaskStoreEvent] { lock.withLock { collected } }
        func append(_ event: TaskStoreEvent) { lock.withLock { collected.append(event) } }
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
            automaticallyResumingChildTaskIDs: { [] },
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

/// How a coordinator's note travels through the notification broker (`CoordinatorBriefingDelivery`).
@Suite("Coordinator briefing delivery")
struct CoordinatorBriefingDeliveryTests {
    private struct NoopRuntime: NotificationRuntime {
        func autoRunTask(_ taskID: UUID, amendment: String?) async -> AutoRunDispatchOutcome { .placed }
        func setTaskStatus(_ taskID: UUID, to status: AgentTask.Status) async -> Bool { true }
        func taskTitle(_ taskID: UUID) async -> String? { nil }
        func postSystemNotice(_ text: String, taskID: UUID?) async {}
        func startTaskForWatch(_ targetID: UUID, watchedTaskID: UUID, watchID: UUID, occurrence: Int) async -> AutoRunDispatchOutcome { .placed }
    }

    private let coordinatorID = UUID()

    private func record(cause: TaskTransitionCause = .validationPassed(validationWasRun: true)) -> TaskEffectRecord {
        let transition = TaskStatusTransition(taskID: UUID(), statusRevision: 4, from: .validating, to: .completed, at: Date(), cause: cause)
        return TaskEffectRecord(transition: transition, effect: .coordinatorBriefing(coordinatorTaskID: coordinatorID, note: "note"), release: .released)
    }

    @Test("the handler delivers the note, and refuses a missing note or a non-worker recipient")
    func handler() async throws {
        let handler = CoordinatorBriefingNotificationHandler()
        let good = CoordinatorBriefingDelivery.outcomeNotification(for: record(), coordinatorTaskID: coordinatorID, note: "Child done.", smithNote: nil)
        #expect(try await handler.handle(good, runtime: NoopRuntime()) == .deliver("Child done."))

        var noNote = good
        noNote.payload.data[CoordinatorBriefingDelivery.Key.note] = nil
        await #expect(throws: NotificationHandlerError.self) { try await handler.handle(noNote, runtime: NoopRuntime()) }
        var toSmith = good
        toSmith.recipient = .smith
        await #expect(throws: NotificationHandlerError.self) { try await handler.handle(toSmith, runtime: NoopRuntime()) }
    }

    @Test("the coordinator copy, Smith's fallback and the child's own Smith briefing have distinct ids; the reroute copy equals the direct one")
    func ids() throws {
        let effect = record()
        let coordinatorCopy = CoordinatorBriefingDelivery.outcomeNotification(for: effect, coordinatorTaskID: coordinatorID, note: "n", smithNote: "smith")
        let trigger = TriggerSource.taskTransition(taskID: effect.transition.taskID, statusRevision: effect.transition.statusRevision)
        let direct = CoordinatorBriefingDelivery.smithFallback(effectRecordID: effect.id, trigger: trigger, title: coordinatorCopy.title, smithNote: "smith")
        let smithOwnRecordID = NotificationID(namespace: trigger.namespace, key: "\(effect.transition.taskID.uuidString)|\(effect.transition.statusRevision)|smithBriefing")
        #expect(Set([coordinatorCopy.id, direct.id, smithOwnRecordID]).count == 3)

        let rerouted = try #require(try CoordinatorBriefingDelivery.smithFallback(rerouting: coordinatorCopy))
        #expect(rerouted.id == direct.id, "the reroute and the direct fallback must dedup")
        #expect(rerouted.recipient == .smith)

        let withoutSmithNote = CoordinatorBriefingDelivery.outcomeNotification(for: effect, coordinatorTaskID: coordinatorID, note: "n", smithNote: nil)
        #expect(try CoordinatorBriefingDelivery.smithFallback(rerouting: withoutSmithNote) == nil, "Smith is owed nothing")

        var broken = coordinatorCopy
        broken.payload.data[CoordinatorBriefingDelivery.Key.effectRecordID] = nil
        #expect(throws: NotificationHandlerError.self) { try CoordinatorBriefingDelivery.smithFallback(rerouting: broken) }
    }

    @Test("a departure's id is deterministic per child revision and destination")
    func departureIDs() {
        let child = AgentTask(title: "Child", description: "d", coordinatorTaskID: coordinatorID)
        let first = CoordinatorChildDeparture(id: UUID(), coordinatorTaskID: coordinatorID, child: child, departure: .leftActive(.archived), undeliveredOutcomes: [])
        let notification = CoordinatorBriefingDelivery.departureNotification(first)
        #expect(notification.id == CoordinatorBriefingDelivery.departureNotification(first).id, "a resubmission dedups")
        // Archive → restore → archive: the same child, revision and destination, but a new departure.
        let second = CoordinatorChildDeparture(id: UUID(), coordinatorTaskID: coordinatorID, child: child, departure: .leftActive(.archived), undeliveredOutcomes: [])
        #expect(notification.id != CoordinatorBriefingDelivery.departureNotification(second).id)
        #expect(notification.recipient == .taskWorker(taskID: coordinatorID))
    }
}
