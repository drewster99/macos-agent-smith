import Foundation
import Testing
import SemanticSearch
@testable import AgentSmithKit

/// Tests for the 2026-07-08 incident stabilizers: `run_task`'s non-destructive
/// auto-resolve and the wake replay filter that stops resurrection restart storms.

// MARK: - run_task auto-resolve

@Suite("RunTaskTool auto-resolve")
struct RunTaskToolAutoResolveTests {

    private func makeContext(taskStore: TaskStore) -> ToolContext {
        TestToolContext.make(agentRole: .smith, taskStore: taskStore)
    }

    @Test("Auto-resolved target never gets its description amended")
    func autoResolveDoesNotAmend() async throws {
        let store = TaskStore()
        let task = await store.addTask(title: "Plain pending task", description: "Original description.")

        let result = try await RunTaskTool().execute(
            arguments: ["instructions": .string("INCLUDE ALL THIS TEXT VERBATIM IN THE TASK: unrelated new work")],
            context: makeContext(taskStore: store)
        )

        #expect(result.succeeded, "Expected success, got: \(result.output)")
        #expect(result.output.contains("auto-resolved"))
        #expect(result.output.contains("NOT applied"))
        let after = await store.task(id: task.id)
        #expect(after?.description == "Original description.")
        #expect(after?.description.contains("[Amendment]") == false)
    }

    @Test("Explicitly named target still gets the amendment")
    func explicitTargetAmends() async throws {
        let store = TaskStore()
        let task = await store.addTask(title: "Named task", description: "Original description.")

        let result = try await RunTaskTool().execute(
            arguments: [
                "task_id": .string(task.id.uuidString),
                "instructions": .string("User granted sudo for this run.")
            ],
            context: makeContext(taskStore: store)
        )

        #expect(result.succeeded, "Expected success, got: \(result.output)")
        let after = await store.task(id: task.id)
        #expect(after?.description.contains("[Amendment]: User granted sudo for this run.") == true)
    }

    @Test("A once-scheduled task is never an auto-resolve candidate")
    func scheduledTaskExcludedFromAutoResolve() async throws {
        let store = TaskStore()
        // Past `scheduledRunAt` → created directly in .pending, exactly like a reminder
        // the wake system promoted at fire time. This is the 9 PM-reminder shape.
        let reminder = await store.addTask(
            title: "9pm Reminder",
            description: "Send the reminder.",
            scheduledRunAt: Date(timeIntervalSinceNow: -1800)
        )
        #expect(reminder.status == .pending)

        let result = try await RunTaskTool().execute(
            arguments: ["instructions": .string("verbatim new request text")],
            context: makeContext(taskStore: store)
        )

        #expect(!result.succeeded, "Expected failure (no auto-resolve candidate), got: \(result.output)")
        #expect(result.output.contains("Missing required argument 'task_id'"))
        let after = await store.task(id: reminder.id)
        #expect(after?.status == .pending)
        #expect(after?.description.contains("[Amendment]") == false)
    }
}

// MARK: - Wake replay filter

@Suite("OrchestrationRuntime wake replay filter")
struct WakeReplayFilterTests {

    private func makeRuntime() -> OrchestrationRuntime {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-smith-phase0-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        return OrchestrationRuntime(
            providers: [:],
            configurations: [:],
            providerAPITypes: [:],
            agentTuning: [:],
            semanticSearchEngine: SemanticSearchEngine(),
            usageStore: UsageStore(persistence: PersistenceManager(testingRoot: tmpRoot)),
            autoAdvanceEnabled: true,
            autoRunInterruptedTasks: false,
            memoryStore: nil
        )
    }

    private func autoRunWake(taskID: UUID, wakeAt: Date) -> ScheduledWake {
        ScheduledWake(
            wakeAt: wakeAt,
            instructions: "Call `run_task` on \(taskID.uuidString) to start the task \"t\".",
            taskID: taskID
        )
    }

    @Test("A fired wake (past-due, task already promoted) is not replayed")
    func firedWakeIsDropped() async {
        let runtime = makeRuntime()
        let store = await runtime.taskStore
        // Past scheduledRunAt → .pending, i.e. "the wake already fired and promoted it".
        let task = await store.addTask(
            title: "9pm Reminder", description: "d",
            scheduledRunAt: Date(timeIntervalSinceNow: -120)
        )
        let stale = autoRunWake(taskID: task.id, wakeAt: Date(timeIntervalSinceNow: -120))

        let kept = await runtime.replayableWakes(from: [stale], resumingTaskID: nil)
        #expect(kept.isEmpty)
    }

    @Test("An elapsed-while-quit wake (task still .scheduled) is replayed")
    func elapsedWhileQuitWakeIsKept() async {
        let runtime = makeRuntime()
        let store = await runtime.taskStore
        // Future scheduledRunAt → task sits in .scheduled; a past-due wake for it means
        // the app was quit at fire time and the documented catch-up must happen.
        let task = await store.addTask(
            title: "Scheduled", description: "d",
            scheduledRunAt: Date(timeIntervalSinceNow: 3600)
        )
        let wake = autoRunWake(taskID: task.id, wakeAt: Date(timeIntervalSinceNow: -60))

        let kept = await runtime.replayableWakes(from: [wake], resumingTaskID: nil)
        #expect(kept.count == 1)
    }

    @Test("A future wake on a pending task survives (schedule_task_action case)")
    func futureWakeOnPendingTaskIsKept() async {
        let runtime = makeRuntime()
        let store = await runtime.taskStore
        let task = await store.addTask(title: "Pending", description: "d")
        let wake = autoRunWake(taskID: task.id, wakeAt: Date(timeIntervalSinceNow: 3600))

        let kept = await runtime.replayableWakes(from: [wake], resumingTaskID: nil)
        #expect(kept.count == 1)
    }

    @Test("The wake for the task this restart is resuming is dropped")
    func resumingTaskWakeIsDropped() async {
        let runtime = makeRuntime()
        let store = await runtime.taskStore
        let task = await store.addTask(
            title: "Resuming", description: "d",
            scheduledRunAt: Date(timeIntervalSinceNow: 3600)
        )
        let wake = autoRunWake(taskID: task.id, wakeAt: Date(timeIntervalSinceNow: 3600))

        let kept = await runtime.replayableWakes(from: [wake], resumingTaskID: task.id)
        #expect(kept.isEmpty)
    }

    @Test("Duplicate auto-run wakes collapse to one")
    func duplicateAutoRunWakesAreDeduped() async {
        let runtime = makeRuntime()
        let store = await runtime.taskStore
        let task = await store.addTask(
            title: "Scheduled", description: "d",
            scheduledRunAt: Date(timeIntervalSinceNow: 3600)
        )
        let fireAt = Date(timeIntervalSinceNow: 3600)
        // Same (taskID, wakeAt) under three distinct wake IDs — the incident's disk
        // snapshot had exactly this shape.
        let wakes = [
            autoRunWake(taskID: task.id, wakeAt: fireAt),
            autoRunWake(taskID: task.id, wakeAt: fireAt),
            autoRunWake(taskID: task.id, wakeAt: fireAt)
        ]

        let kept = await runtime.replayableWakes(from: wakes, resumingTaskID: nil)
        #expect(kept.count == 1)
    }

    @Test("Non-auto-run wakes are kept even when past-due")
    func smithImperativeWakesAreKept() async {
        let runtime = makeRuntime()
        let wake = ScheduledWake(
            wakeAt: Date(timeIntervalSinceNow: -300),
            instructions: "Tell Drew his shower reminder is up.",
            taskID: nil
        )

        let kept = await runtime.replayableWakes(from: [wake], resumingTaskID: nil)
        #expect(kept.count == 1)
    }
}
