import Foundation
import Testing
import SemanticSearch
@testable import AgentSmithKit

/// One task maps to one session's transcript (#15). A task restored into a session other than the
/// one it started in is never run there in place — that would split its transcript across two
/// logs. An explicit start runs a fresh clone in this session and leaves the original alone;
/// nothing automatic starts it at all.
@Suite("Tasks from another session")
struct ForeignSessionTaskTests {

    // MARK: - Model

    @Test("Which tasks belong to another session")
    func belongsToAnotherSessionTable() {
        let home = UUID(), other = UUID()
        #expect(!AgentTask(title: "t", description: "d", sessionID: home).belongsToAnotherSession(than: home))
        #expect(AgentTask(title: "t", description: "d", sessionID: other).belongsToAnotherSession(than: home))
        #expect(AgentTask(title: "t", description: "d", sessionID: nil).belongsToAnotherSession(than: home),
                "a legacy task's transcript lives in an unknown log")
        #expect(!AgentTask(title: "t", description: "d", sessionID: other).belongsToAnotherSession(than: nil),
                "a standalone store has no home session, so nothing is foreign")
        #expect(!AgentTask(title: "t", description: "d", isTemplate: true, sessionID: other).belongsToAnotherSession(than: home),
                "a template belongs to no session; starting one always clones")
    }

    private static func foreignTask(sessionID: UUID) -> AgentTask {
        var task = AgentTask(
            title: "Audit logs",
            description: "Check the logs",
            status: .failed,
            result: "earlier result",
            updates: [AgentTask.TaskUpdate(message: "earlier update")],
            approvedTools: ["bash"],
            userToolOverrides: ["gh": true],
            requiresUserAcceptance: true,
            acceptanceCriteria: [AcceptanceCriterion(name: "Logs checked", validationPrompt: "Were the logs checked?", waivable: false, origin: .smith)],
            steps: [
                TaskStep(text: "Open the log", status: .completed, note: "done", origin: .smith),
                TaskStep(text: "Removed step", status: .removed, note: nil, origin: .smith)
            ],
            coordinatorTaskID: UUID(),
            sessionID: sessionID
        )
        task.childTasksCreated = 2
        return task
    }

    @Test("The clone carries the work and nothing about the earlier run; the original keeps everything")
    func cloneFields() async {
        let home = UUID(), other = UUID()
        let store = TaskStore()
        await store.setSessionID(home)
        let original = Self.foreignTask(sessionID: other)
        await store.restore([original])

        let clone = await store.cloneForRunInThisSession(source: original)

        #expect(clone.id != original.id)
        #expect(clone.sessionID == home)
        #expect(clone.status == .pending)
        #expect(clone.title == original.title && clone.description == original.description)
        #expect(clone.userToolOverrides == ["gh": true])
        #expect(clone.requiresUserAcceptance)
        #expect(clone.acceptanceCriteria.map(\.name) == ["Logs checked"])
        #expect(clone.acceptanceCriteria.first?.id != original.acceptanceCriteria.first?.id, "fresh criterion ids")
        #expect(clone.validation == nil)
        #expect(clone.steps.map(\.text) == ["Open the log"], "removed steps stay with the original")
        #expect(clone.steps.allSatisfy { $0.status == .pending && $0.note == nil })
        #expect(clone.result == nil)
        #expect(clone.approvedTools == nil)
        #expect(clone.coordinatorTaskID == nil)
        #expect(clone.childTasksCreated == 0)
        #expect(clone.updates.count == 1)
        #expect(await store.task(id: clone.id) != nil)

        let after = await store.task(id: original.id)
        #expect(after?.status == .failed)
        #expect(after?.result == "earlier result")
        #expect(after?.sessionID == other, "a task's origin session never changes")
        #expect(after?.updates.count == 2, "the original only gains a note naming its clone")
    }

    @Test("prepareForRun leaves a task from another session untouched, as it does a template")
    func prepareForRunDoesNotResetForeignTask() async {
        let store = TaskStore()
        await store.setSessionID(UUID())
        let original = Self.foreignTask(sessionID: UUID())
        await store.restore([original])

        #expect(await store.prepareForRun(id: original.id) == .ready)
        let after = await store.task(id: original.id)
        #expect(after?.status == .failed, "a failed foreign task is not reset in place")
        #expect(after?.result == "earlier result")
    }

    // MARK: - Runtime

    private func makeRuntime(autoAdvance: Bool = false, inactiveTaskStore: InactiveTaskStore = InactiveTaskStore()) throws -> OrchestrationRuntime {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-smith-foreign-session-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let configuration = ModelConfiguration(name: "test", providerID: "test", modelID: "test-model")
        return OrchestrationRuntime(
            providers: [
                .smith: MockLLMProvider(responses: [LLMResponse(text: "Standing by.")]),
                .securityAgent: MockLLMProvider(responses: [LLMResponse(text: "SAFE")]),
                .brown: StillThinkingLLMProvider()
            ],
            configurations: [.smith: configuration, .securityAgent: configuration, .brown: configuration],
            providerAPITypes: [:],
            agentTuning: [:],
            semanticSearchEngine: SemanticSearchEngine(),
            usageStore: UsageStore(persistence: PersistenceManager(testingRoot: tmpRoot)),
            autoAdvanceEnabled: autoAdvance,
            autoRunInterruptedTasks: false,
            memoryStore: nil,
            inactiveTaskStore: inactiveTaskStore
        )
    }

    private func startedRuntime(autoAdvance: Bool = false, inactiveTaskStore: InactiveTaskStore = InactiveTaskStore()) async throws -> (OrchestrationRuntime, TaskStore, home: UUID) {
        let runtime = try makeRuntime(autoAdvance: autoAdvance, inactiveTaskStore: inactiveTaskStore)
        await runtime.setOrchestrationSettings(OrchestrationSettings.builtIn.applying(
            OrchestrationSettingsOverride(autoRunNextTask: autoAdvance, scopeToolSetOnTaskStart: false)))
        let store = await runtime.taskStore
        let home = UUID()
        await store.setSessionID(home)
        await runtime.start()
        return (runtime, store, home)
    }

    /// The tasks in `store` other than `excluded`, i.e. the clones a start made.
    private func clones(in store: TaskStore, excluding excluded: UUID) async -> [AgentTask] {
        await store.allTasks().filter { $0.id != excluded }
    }

    @Test("Play on a task from another session runs a clone here; the original is untouched")
    func playRunsAClone() async throws {
        let (runtime, store, home) = try await startedRuntime()
        let original = AgentTask(title: "Foreign", description: "d", sessionID: UUID())
        await store.restore([original])

        await runtime.restartForNewTask(taskID: original.id, origin: .explicitUser)
        await runtime.waitForPendingRestarts()

        let made = await clones(in: store, excluding: original.id)
        #expect(made.count == 1)
        let clone = try #require(made.first)
        #expect(clone.sessionID == home)
        #expect(clone.status == .running)
        #expect(await runtime.liveWorkerID(taskID: clone.id) != nil)
        let after = await store.task(id: original.id)
        #expect(after?.status == .pending)
        #expect(after?.assigneeIDs.isEmpty == true)
        #expect(await runtime.liveWorkerID(taskID: original.id) == nil)
        let banner = await runtime.channel.allMessages().first { $0.kind == .taskCreated && $0.metadata?["taskID"] == .string(clone.id.uuidString) }
        #expect(banner?.metadata?["clonedFromTask"] == .string(original.id.uuidString))

        await runtime.stopAll()
    }

    @Test("run_task on a completed task from another session runs an amended clone and hands Smith the clone's id")
    func runTaskRunsAnAmendedClone() async throws {
        let (runtime, store, _) = try await startedRuntime()
        let original = AgentTask(title: "Foreign done", description: "original description", status: .completed, result: "kept", sessionID: UUID())
        await store.restore([original])
        let smithID = try #require(await runtime.agentIDForRole(.smith))
        let context = await runtime.makeToolContext(agentID: smithID, role: .smith)

        let result = try await RunTaskTool().execute(
            arguments: ["task_id": .string(original.id.uuidString), "instructions": .string("Also check the archive.")],
            context: context
        )
        #expect(result.succeeded, "\(result.output)")
        await runtime.waitForPendingRestarts()

        let clone = try #require(await clones(in: store, excluding: original.id).first)
        #expect(result.output.contains(clone.id.uuidString), "Smith must be handed the clone's id, not the original's")
        #expect(clone.description.contains("Also check the archive."), "the amendment lands on the clone")
        #expect(clone.status == .running)
        let after = await store.task(id: original.id)
        #expect(after?.status == .completed, "the original is not reopened")
        #expect(after?.result == "kept")
        #expect(after?.description == "original description", "the original is not amended")

        await runtime.stopAll()
    }

    @Test("Auto-advance never starts or clones a task from another session")
    func autoAdvanceSkipsForeignTasks() async throws {
        let (runtime, store, _) = try await startedRuntime(autoAdvance: true)
        let original = AgentTask(title: "Foreign pending", description: "d", sessionID: UUID())
        await store.restore([original])

        await runtime.drainPendingTaskQueueForTesting()
        await runtime.waitForPendingRestarts()

        #expect(await clones(in: store, excluding: original.id).isEmpty)
        #expect(await store.task(id: original.id)?.status == .pending)
        #expect(await runtime.liveWorkerID(taskID: original.id) == nil)

        await runtime.stopAll()
    }

    @Test("A task restored into its own session runs in place")
    func ownSessionTaskRunsInPlace() async throws {
        let (runtime, store, home) = try await startedRuntime()
        let own = AgentTask(title: "Mine", description: "d", sessionID: home)
        await store.restore([own])

        await runtime.restartForNewTask(taskID: own.id, origin: .explicitUser)
        await runtime.waitForPendingRestarts()

        #expect(await clones(in: store, excluding: own.id).isEmpty)
        #expect(await store.task(id: own.id)?.status == .running)
        #expect(await runtime.liveWorkerID(taskID: own.id) != nil)

        await runtime.stopAll()
    }

    @Test("run_task on an ARCHIVED task from another session clones from the archive and leaves the original archived")
    func runTaskOnArchivedForeignTask() async throws {
        let inactive = InactiveTaskStore()
        let original = AgentTask(title: "Archived elsewhere", description: "d", status: .completed, disposition: .archived, result: "kept", sessionID: UUID())
        await inactive.insert(original)
        let (runtime, store, home) = try await startedRuntime(inactiveTaskStore: inactive)
        let smithID = try #require(await runtime.agentIDForRole(.smith))
        let context = await runtime.makeToolContext(agentID: smithID, role: .smith)

        let result = try await RunTaskTool().execute(arguments: ["task_id": .string(original.id.uuidString)], context: context)
        #expect(result.succeeded, "\(result.output)")
        await runtime.waitForPendingRestarts()

        let clone = try #require(await store.allTasks().first { $0.title == original.title })
        #expect(clone.id != original.id && clone.sessionID == home)
        #expect(await store.task(id: original.id) == nil, "the original is not restored into this session")
        #expect(await inactive.task(id: original.id)?.disposition == .archived)
        #expect(await inactive.task(id: original.id)?.result == "kept")

        await runtime.stopAll()
    }

    @Test("run_task with no task_id never auto-picks a task from another session")
    func bareRunTaskSkipsForeignTasks() async throws {
        let (runtime, store, _) = try await startedRuntime()
        let original = AgentTask(title: "Only pending, but foreign", description: "d", sessionID: UUID())
        await store.restore([original])
        let smithID = try #require(await runtime.agentIDForRole(.smith))
        let context = await runtime.makeToolContext(agentID: smithID, role: .smith)

        let result = try await RunTaskTool().execute(arguments: [:], context: context)
        #expect(!result.succeeded, "with only a foreign task, there is nothing to auto-pick: \(result.output)")
        #expect(await store.allTasks().count == 1, "nothing was cloned")

        await runtime.stopAll()
    }

    @Test("The restart backstop never re-queues a pending scheduled task from another session")
    func restartBackstopSkipsForeignTasks() async throws {
        let (runtime, store, _) = try await startedRuntime()
        let original = AgentTask(title: "Fired elsewhere", description: "d", status: .pending, scheduledRunAt: Date().addingTimeInterval(-60), sessionID: UUID())
        await store.restore([original])

        await runtime.stopAll()
        await runtime.start()
        await runtime.drainPendingTaskQueueForTesting()
        await runtime.waitForPendingRestarts()

        #expect(await store.allTasks().count == 1, "no clone was made")
        #expect(await store.task(id: original.id)?.status == .pending)

        await runtime.stopAll()
    }

    @Test("Backstop: no worker is spawned for a task from another session, and the refusal is shown")
    func spawnRefusesForeignTask() async throws {
        let (runtime, store, _) = try await startedRuntime()
        let foreign = AgentTask(title: "Foreign", description: "d", sessionID: UUID())
        await store.restore([foreign])
        #expect(await runtime.spawnBrown(for: foreign) == nil)
        #expect(await runtime.liveWorkerID(taskID: foreign.id) == nil)
        #expect(await runtime.channel.allMessages().contains {
            $0.kind == .taskLifecycle && $0.severity == .error && $0.metadata?["taskID"] == .string(foreign.id.uuidString)
        })
        await runtime.stopAll()
    }

    @Test("Assigning a validator model releases only this session's parked tasks")
    func validationReleaseSkipsForeignTasks() async throws {
        let store = TaskStore()
        let home = UUID()
        await store.setSessionID(home)
        func parked(_ title: String, sessionID: UUID) -> AgentTask {
            var task = AgentTask(title: title, description: "d", status: .awaitingReview, sessionID: sessionID)
            task.validationBlockedReason = "no validator model"
            return task
        }
        let own = parked("Mine", sessionID: home)
        let foreign = parked("Foreign", sessionID: UUID())
        await store.restore([own, foreign])
        #expect(await store.releaseValidationBlockedTasks() == [own.id])
        #expect(await store.task(id: foreign.id)?.status == .awaitingReview)
    }

    @Test("A clone of a worker-written task is still reviewed as worker-written")
    func cloneKeepsWorkerProvenance() async throws {
        let store = TaskStore()
        let home = UUID()
        await store.setSessionID(home)
        let root = await store.addTask(title: "Root", description: "The user's request.")
        guard case .created(let child) = await store.addChildTask(
            coordinatorTaskID: root.id, limit: 10, title: "Child", description: "worker-written",
            descriptionAttachments: [], acceptanceCriteria: [], steps: [], requiredCapabilities: [],
            relevantContext: .none
        ) else { Issue.record("child not created"); return }
        var foreignChild = child
        foreignChild.sessionID = UUID()
        await store.restore([foreignChild])

        let clone = await store.cloneForRunInThisSession(source: foreignChild)
        #expect(clone.coordinatorTaskID == nil, "the clone reports to no coordinator")
        #expect(clone.clonedFromWorkerAuthoredTaskID == foreignChild.id)
        let expected = TaskIntentProvenance.workerAuthored(originatingTask: .init(id: root.id, title: "Root", description: "The user's request."))
        #expect(await store.intentProvenance(of: clone) == expected)

        let userTask = AgentTask(title: "User's", description: "d", sessionID: UUID())
        await store.restore([userTask])
        let userClone = await store.cloneForRunInThisSession(source: userTask)
        #expect(userClone.clonedFromWorkerAuthoredTaskID == nil, "a clone of the user's own task carries no worker link")
        #expect(await store.intentProvenance(of: userClone) == .requester)

        // The source gone (deleted, or out of reach): still worker-written, never the user's.
        let orphan = AgentTask(title: "Orphan", description: "d", clonedFromWorkerAuthoredTaskID: UUID(), sessionID: home)
        #expect(await store.intentProvenance(of: orphan) == .workerAuthored(originatingTask: nil))
    }
}
