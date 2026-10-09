import Testing
import Foundation
@testable import AgentSmithKit

/// `schedule_task_action` and `manage_task_disposition` (#30): argument parsing, the success path,
/// and every refusal — a refusal must neither schedule anything nor move the task.
@Suite("Task action and disposition tools")
struct TaskActionAndDispositionToolTests {

    actor Requests {
        private(set) var values: [WakeRequest] = []
        func record(_ value: WakeRequest) { values.append(value) }
    }

    private static func context(
        store: TaskStore,
        channel: MessageChannel = MessageChannel(),
        requests: Requests = Requests(),
        outcome: @escaping @Sendable (WakeRequest) -> ScheduleWakeOutcome = { request in
            .scheduled(ScheduledWake(wakeAt: request.wakeAt, instructions: request.instructions, taskID: request.taskID, recurrence: request.recurrence, action: request.action))
        }
    ) -> ToolContext {
        TestToolContext.make(
            agentRole: .smith, channel: channel, taskStore: store,
            scheduleWake: { request in
                await requests.record(request)
                return outcome(request)
            }
        )
    }

    // MARK: - schedule_task_action

    @Test("schedule_task_action: every refusal schedules nothing")
    func scheduleRefusals() async throws {
        let store = TaskStore()
        let task = await store.addTask(title: "t", description: "d")
        let requests = Requests()
        let context = Self.context(store: store, requests: requests)
        let id = AnyCodable.string(task.id.uuidString)
        let refused: [[String: AnyCodable]] = [
            ["action": .string("run"), "delay_seconds": .int(60)],
            ["task_id": .string("nope"), "action": .string("run"), "delay_seconds": .int(60)],
            ["task_id": .string(UUID().uuidString), "action": .string("run"), "delay_seconds": .int(60)],
            ["task_id": id, "delay_seconds": .int(60)],
            ["task_id": id, "action": .string("explode"), "delay_seconds": .int(60)],
            ["task_id": id, "action": .string("run")],
            ["task_id": id, "action": .string("run"), "delay_seconds": .int(1)],
            ["task_id": id, "action": .string("run"), "at_time": .string("next tuesday")],
            ["task_id": id, "action": .string("run"), "delay_seconds": .int(60), "replaces_id": .string("nope")],
            ["task_id": id, "action": .string("run"), "delay_seconds": .int(60), "recurrence": .dictionary(["type": .string("fortnightly")])]
        ]
        for arguments in refused {
            let result = try await ScheduleTaskActionTool().execute(arguments: arguments, context: context)
            #expect(!result.succeeded, "\(arguments)")
        }
        #expect(await requests.values.isEmpty)
        #expect(await store.task(id: task.id)?.isTemplate == false)
    }

    @Test("schedule_task_action: schedules the action for the task and posts a banner")
    func scheduleSucceeds() async throws {
        let store = TaskStore()
        let task = await store.addTask(title: "Nightly report", description: "d")
        let channel = MessageChannel()
        let requests = Requests()
        let result = try await ScheduleTaskActionTool().execute(
            arguments: ["task_id": .string(task.id.uuidString), "action": .string("summarize"), "delay_seconds": .int(120),
                        "extra_instructions": .string("keep it short"), "replaces_id": .string(""), "recurrence": .null],
            context: Self.context(store: store, channel: channel, requests: requests)
        )
        #expect(result.succeeded)
        let request = try #require(await requests.values.first)
        #expect(request.taskID == task.id)
        #expect(request.action == .summarize)
        #expect(request.replacesID == nil)
        #expect(request.recurrence == nil)
        #expect(request.extraInstructions == "keep it short")
        #expect(await channel.allMessages().contains { $0.kind == .taskActionScheduled })
    }

    @Test("schedule_task_action: 'stop' is read as interrupt")
    func scheduleStopIsInterrupt() async throws {
        let store = TaskStore()
        let task = await store.addTask(title: "t", description: "d")
        let requests = Requests()
        let result = try await ScheduleTaskActionTool().execute(
            arguments: ["task_id": .string(task.id.uuidString), "action": .string("Stop"), "delay_seconds": .int(60)],
            context: Self.context(store: store, requests: requests)
        )
        #expect(result.succeeded)
        #expect(try #require(await requests.values.first).action == .interrupt)
    }

    @Test("schedule_task_action: a recurring run makes the task a template")
    func scheduleRecurringRunPromotes() async throws {
        let store = TaskStore()
        let task = await store.addTask(title: "t", description: "d")
        let result = try await ScheduleTaskActionTool().execute(
            arguments: ["task_id": .string(task.id.uuidString), "action": .string("run"), "delay_seconds": .int(60),
                        "recurrence": .dictionary(["type": .string("daily"), "hour": .int(9), "minute": .int(0)])],
            context: Self.context(store: store)
        )
        #expect(result.succeeded)
        #expect(await store.taskOrLibraryTemplate(id: task.id)?.isTemplate == true)
    }

    @Test("schedule_task_action: a placeholder recurrence ({}, blank) is a one-shot and doesn't make a template")
    func schedulePlaceholderRecurrence() async throws {
        for placeholder: AnyCodable in [.dictionary([:]), .string("  ")] {
            let store = TaskStore()
            let task = await store.addTask(title: "t", description: "d")
            let requests = Requests()
            let result = try await ScheduleTaskActionTool().execute(
                arguments: ["task_id": .string(task.id.uuidString), "action": .string("run"), "delay_seconds": .int(60), "recurrence": placeholder],
                context: Self.context(store: store, requests: requests)
            )
            #expect(result.succeeded, "\(placeholder)")
            #expect(try #require(await requests.values.first).recurrence == nil, "\(placeholder)")
            #expect(await store.task(id: task.id)?.isTemplate == false, "\(placeholder)")
        }
    }

    @Test("schedule_task_action: a runtime rejection fails and posts no banner")
    func scheduleRuntimeRejects() async throws {
        let store = TaskStore()
        let task = await store.addTask(title: "t", description: "d")
        let channel = MessageChannel()
        let result = try await ScheduleTaskActionTool().execute(
            arguments: ["task_id": .string(task.id.uuidString), "action": .string("pause"), "delay_seconds": .int(60)],
            context: Self.context(store: store, channel: channel, outcome: { _ in .error("system is restarting") })
        )
        #expect(!result.succeeded)
        #expect(await !channel.allMessages().contains { $0.kind == .taskActionScheduled })
    }

    // MARK: - manage_task_disposition

    private static func dispositionStore() async -> TaskStore {
        let store = TaskStore(inactiveStore: InactiveTaskStore())
        await store.setDurablePersistHooks(inactive: { true })
        return store
    }

    private static func run(_ arguments: [String: AnyCodable], _ store: TaskStore) async throws -> ToolExecutionResult {
        try await ManageTaskDispositionTool().execute(arguments: arguments, context: context(store: store))
    }

    @Test("manage_task_disposition: missing task_id or action is refused")
    func dispositionMissing() async {
        let store = await Self.dispositionStore()
        for (arguments, name) in [([String: AnyCodable](), "task_id"), (["task_id": .string(UUID().uuidString)], "action")] {
            do {
                _ = try await Self.run(arguments, store)
                Issue.record("expected missingRequiredArgument(\(name))")
            } catch ToolCallError.missingRequiredArgument(let missing) {
                #expect(missing == name)
            } catch {
                Issue.record("unexpected error \(error)")
            }
        }
    }

    @Test("manage_task_disposition: a malformed or unknown task id, or an unknown action, changes nothing")
    func dispositionBadInput() async throws {
        let store = await Self.dispositionStore()
        let task = await store.addTask(title: "t", description: "d")
        #expect(await store.driveStatus(id: task.id, to: .failed))
        for arguments: [String: AnyCodable] in [
            ["task_id": .string("nope"), "action": .string("archive")],
            ["task_id": .string(UUID().uuidString), "action": .string("archive")],
            ["task_id": .string(task.id.uuidString), "action": .string("shred")]
        ] {
            #expect(try await !Self.run(arguments, store).succeeded, "\(arguments)")
        }
        #expect(await store.taskAnyDisposition(id: task.id)?.disposition == .active)
    }

    @Test("manage_task_disposition: a task in progress can be neither archived nor deleted")
    func dispositionInProgressRefused() async throws {
        let store = await Self.dispositionStore()
        let task = await store.addTask(title: "t", description: "d")
        #expect(await store.driveStatus(id: task.id, to: .running))
        for action in ["archive", "delete"] {
            #expect(try await !Self.run(["task_id": .string(task.id.uuidString), "action": .string(action)], store).succeeded)
        }
        #expect(await store.taskAnyDisposition(id: task.id)?.disposition == .active)
    }

    @Test("manage_task_disposition: a pending (not in progress) task can be archived and deleted")
    func dispositionPendingAllowed() async throws {
        for (action, expected) in [("archive", AgentTask.TaskDisposition.archived), ("delete", .recentlyDeleted)] {
            let store = await Self.dispositionStore()
            let task = await store.addTask(title: "t", description: "d")
            #expect(try await Self.run(["task_id": .string(task.id.uuidString), "action": .string(action)], store).succeeded, "\(action)")
            #expect(await store.taskAnyDisposition(id: task.id)?.disposition == expected, "\(action)")
        }
    }

    @Test("manage_task_disposition: unarchive and undelete refuse a task that is not in that bucket")
    func dispositionWrongBucket() async throws {
        let store = await Self.dispositionStore()
        let task = await store.addTask(title: "t", description: "d")
        #expect(await store.driveStatus(id: task.id, to: .failed))
        for action in ["unarchive", "undelete"] {
            #expect(try await !Self.run(["task_id": .string(task.id.uuidString), "action": .string(action)], store).succeeded)
        }
        #expect(await store.taskAnyDisposition(id: task.id)?.disposition == .active)
    }

    @Test("manage_task_disposition: archive → unarchive, delete → undelete round trips")
    func dispositionRoundTrips() async throws {
        let store = await Self.dispositionStore()
        let task = await store.addTask(title: "t", description: "d")
        #expect(await store.driveStatus(id: task.id, to: .failed))
        let id = AnyCodable.string(task.id.uuidString)
        let steps: [(action: String, expected: AgentTask.TaskDisposition)] = [
            ("archive", .archived), ("unarchive", .active), ("delete", .recentlyDeleted), ("undelete", .active)
        ]
        for step in steps {
            #expect(try await Self.run(["task_id": id, "action": .string(step.action)], store).succeeded, "\(step.action)")
            #expect(await store.taskAnyDisposition(id: task.id)?.disposition == step.expected, "\(step.action)")
        }
    }
}
