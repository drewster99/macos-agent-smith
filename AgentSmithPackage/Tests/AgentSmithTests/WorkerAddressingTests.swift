import Testing
import Foundation
@testable import AgentSmithKit

/// Regression coverage for addressing a WORKER rather than "the Brown role".
///
/// Both tools here resolved their recipient with `agentIDForRole(.brown)`, which returns the
/// OLDEST live worker. That is an arbitrary answer once `maxConcurrentWorkers > 1`:
///   - `message_brown` had no `task_id` at all, so every message went to the oldest worker
///     and was labelled in the UI with whatever task that worker happened to own. Smith's
///     correction for one task could land in another worker's context.
///   - `amend_task` guarded with `task.assigneeIDs.contains(brownID)`, so it never
///     misdelivered — but when the target task's worker wasn't the oldest, the guard failed
///     and the amendment was silently dropped while the caller was told it would be picked
///     up on the next start. That worker kept running on the un-amended description.
///
/// Both now resolve through `workerIDForTask` (backed by
/// `OrchestrationRuntime.liveWorkerID(taskID:)`), which resolves task → worker.
@Suite("Worker addressing with concurrent workers")
struct WorkerAddressingTests {

    /// A `workerIDForTask` that behaves like the real runtime resolver: task → its assigned
    /// live worker, and nothing else. `agentIDForRole(.brown)` is deliberately wired to the
    /// OLDEST worker so a regression to the role lookup shows up as a wrong recipient.
    private static func makeContext(
        channel: MessageChannel,
        taskStore: TaskStore,
        liveWorkers: [UUID],
        oldestWorker: UUID
    ) -> ToolContext {
        ToolContext(
            agentID: UUID(),
            agentRole: .smith,
            channel: channel,
            taskStore: taskStore,
            spawnBrown: { nil },
            terminateAgent: { _, _ in false },
            abort: { _, _ in },
            agentRoleForID: { id in liveWorkers.contains(id) ? .brown : nil },
            agentIDForRole: { role in role == .brown ? oldestWorker : nil },
            workerIDForTask: { [taskStore] taskID in
                guard let task = await taskStore.task(id: taskID) else { return nil }
                let live = task.assigneeIDs.filter { liveWorkers.contains($0) }
                return live.count == 1 ? live[0] : nil
            },
            memoryStore: MemoryStore(engine: SemanticSearchEngine())
        )
    }

    /// Two tasks running concurrently; `older` is the one `agentIDForRole(.brown)` would pick.
    private struct TwoWorkers {
        let channel = MessageChannel()
        let taskStore = TaskStore()
        let olderWorker = UUID()
        let newerWorker = UUID()
        var olderTask: AgentTask!
        var newerTask: AgentTask!

        static func make() async -> TwoWorkers {
            var fixture = TwoWorkers()
            fixture.olderTask = await fixture.taskStore.addTask(title: "Older task", description: "first")
            await fixture.taskStore.assignAgent(taskID: fixture.olderTask.id, agentID: fixture.olderWorker)
            await fixture.taskStore.updateStatus(id: fixture.olderTask.id, status: .running)

            fixture.newerTask = await fixture.taskStore.addTask(title: "Newer task", description: "second")
            await fixture.taskStore.assignAgent(taskID: fixture.newerTask.id, agentID: fixture.newerWorker)
            await fixture.taskStore.updateStatus(id: fixture.newerTask.id, status: .running)
            return fixture
        }

        func context() -> ToolContext {
            WorkerAddressingTests.makeContext(
                channel: channel,
                taskStore: taskStore,
                liveWorkers: [olderWorker, newerWorker],
                oldestWorker: olderWorker
            )
        }
    }

    // MARK: - message_brown

    @Test("message_brown reaches the worker on the named task, not the oldest worker")
    func messageBrownAddressesTheNamedTask() async throws {
        let fixture = await TwoWorkers.make()

        let result = try await MessageBrownTool().execute(
            arguments: [
                "task_id": .string(fixture.newerTask.id.uuidString),
                "message": .string("stop editing the wrong repo")
            ],
            context: fixture.context()
        )

        #expect(result.succeeded)

        let delivered = await fixture.channel.allMessages().filter { $0.content.contains("stop editing the wrong repo") }
        #expect(delivered.count == 1, "expected exactly one delivery")
        #expect(
            delivered.first?.recipientID == fixture.newerWorker,
            "message must reach the NEWER task's worker; got \(String(describing: delivered.first?.recipientID))"
        )
        #expect(
            delivered.first?.recipientID != fixture.olderWorker,
            "the oldest live worker must not receive another task's message"
        )
        // The UI label must name the addressed task, not whatever the recipient happened to own.
        if case .string(let label)? = delivered.first?.metadata?["recipientTaskTitle"] {
            #expect(label == "Newer task")
        } else {
            Issue.record("delivery carried no recipientTaskTitle label")
        }
    }

    @Test("message_brown QUEUES for a task with no live worker, and never falls back to another")
    func messageBrownQueuesWhenTaskHasNoWorker() async throws {
        let fixture = await TwoWorkers.make()
        let idle = await fixture.taskStore.addTask(title: "Queued task", description: "not started")

        let result = try await MessageBrownTool().execute(
            arguments: [
                "task_id": .string(idle.id.uuidString),
                "message": .string("hello?")
            ],
            context: fixture.context()
        )

        // Used to fail outright. It now queues: `create_task`/`run_task` return before the worker
        // is spawned, so "no worker yet" means the message is EARLY, not misaddressed.
        #expect(result.succeeded)
        #expect(result.output.contains("QUEUED"))
        let queued = await fixture.taskStore.task(id: idle.id)?.pendingWorkerMessages
        #expect(queued?.map(\.text) == ["hello?"])

        // The original guard, unchanged and still the important one: queuing must not become a
        // back door to delivering into some OTHER task's worker context.
        let delivered = await fixture.channel.allMessages().filter { $0.content.contains("hello?") }
        #expect(delivered.isEmpty, "a task with no worker must not have its message rerouted to a live one")
    }

    @Test("message_brown rejects an unknown task id")
    func messageBrownRejectsUnknownTask() async throws {
        let fixture = await TwoWorkers.make()
        let result = try await MessageBrownTool().execute(
            arguments: ["task_id": .string(UUID().uuidString), "message": .string("hi")],
            context: fixture.context()
        )
        #expect(result.succeeded == false)
        #expect(result.output.contains("No active task with id"))
    }

    // MARK: - amend_task

    @Test("amend_task delivers to a running worker that is not the oldest one")
    func amendReachesNonOldestWorker() async throws {
        let fixture = await TwoWorkers.make()

        let result = try await AmendTaskTool().execute(
            arguments: [
                "task_id": .string(fixture.newerTask.id.uuidString),
                "amendment": .string("also cover the German locale")
            ],
            context: fixture.context()
        )

        #expect(result.succeeded)
        #expect(
            result.output.contains("delivered to the running Brown"),
            "the caller must be told delivery happened, not that it will land on a future start; got: \(result.output)"
        )

        let delivered = await fixture.channel.allMessages().filter { $0.content.contains("also cover the German locale") }
        #expect(delivered.count == 1)
        #expect(delivered.first?.recipientID == fixture.newerWorker)
    }
}
