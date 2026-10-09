import Testing
import Foundation
@testable import AgentSmithKit

/// `abort`, `list_scheduled_wakes`, `cancel_wake` and `reschedule_wake` (#30): argument parsing,
/// the success path, and every refusal — and that a refusal never reaches the runtime hook.
@Suite("Wake and abort tools")
struct WakeAndAbortToolTests {

    /// Records what a stubbed runtime hook was called with.
    actor Calls<Value: Sendable> {
        private(set) var values: [Value] = []
        func record(_ value: Value) { values.append(value) }
    }

    private static func smithContext(
        wakes: [ScheduledWake] = [],
        scheduled: Calls<WakeRequest> = Calls(),
        cancelled: Calls<UUID> = Calls(),
        aborts: Calls<String> = Calls(),
        scheduleOutcome: @escaping @Sendable (WakeRequest) -> ScheduleWakeOutcome = { request in
            .scheduled(ScheduledWake(wakeAt: request.wakeAt, instructions: request.instructions, taskID: request.taskID, recurrence: request.recurrence))
        }
    ) -> ToolContext {
        TestToolContext.make(
            agentRole: .smith,
            scheduleWake: { request in
                await scheduled.record(request)
                return scheduleOutcome(request)
            },
            listScheduledWakes: { wakes },
            cancelScheduledWake: { id in
                await cancelled.record(id)
                return wakes.contains { $0.id == id }
            },
            abort: { reason, _ in await aborts.record(reason) }
        )
    }


    // MARK: - abort

    @Test("abort: available to Smith only")
    func abortAvailability() {
        #expect(AbortTool().isAvailable(in: ToolAvailabilityContext(agentRole: .smith)))
        #expect(!AbortTool().isAvailable(in: ToolAvailabilityContext(agentRole: .brown)))
    }

    @Test("abort: a missing, blank or non-string reason is refused and nothing is aborted")
    func abortRefusals() async {
        let aborts = Calls<String>()
        let context = Self.smithContext(aborts: aborts)
        for arguments: [String: AnyCodable] in [[:], ["reason": .string("")], ["reason": .string("  \n ")], ["reason": .int(3)]] {
            await expectMissingArgument("reason") { try await AbortTool().execute(arguments: arguments, context: context) }
        }
        #expect(await aborts.values.isEmpty)
    }

    @Test("abort: a reason aborts with that reason")
    func abortSucceeds() async throws {
        let aborts = Calls<String>()
        let result = try await AbortTool().execute(arguments: ["reason": .string("rm -rf attempted")], context: Self.smithContext(aborts: aborts))
        #expect(result.succeeded)
        #expect(await aborts.values == ["rm -rf attempted"])
    }

    // MARK: - list_scheduled_wakes

    @Test("list_scheduled_wakes: none scheduled is a success")
    func listEmpty() async throws {
        let result = try await ListScheduledWakesTool().execute(arguments: [:], context: Self.smithContext())
        #expect(result.succeeded)
    }

    @Test("list_scheduled_wakes: every wake is listed by id, with its task")
    func listWakes() async throws {
        let task = UUID()
        let first = ScheduledWake(wakeAt: Date().addingTimeInterval(60), instructions: "first", taskID: task)
        let second = ScheduledWake(wakeAt: Date().addingTimeInterval(120), instructions: "second")
        let result = try await ListScheduledWakesTool().execute(arguments: [:], context: Self.smithContext(wakes: [first, second]))
        #expect(result.succeeded)
        #expect(result.output.contains(first.id.uuidString))
        #expect(result.output.contains(second.id.uuidString))
        #expect(result.output.contains(task.uuidString))
    }

    // MARK: - cancel_wake

    @Test("cancel_wake: a missing wake_id is refused")
    func cancelMissing() async {
        await expectMissingArgument("wake_id") { try await CancelWakeTool().execute(arguments: [:], context: Self.smithContext()) }
    }

    @Test("cancel_wake: a malformed wake_id is refused without calling the runtime")
    func cancelMalformed() async throws {
        let cancelled = Calls<UUID>()
        let result = try await CancelWakeTool().execute(arguments: ["wake_id": .string("not-a-uuid")], context: Self.smithContext(cancelled: cancelled))
        #expect(!result.succeeded)
        #expect(await cancelled.values.isEmpty)
    }

    @Test("cancel_wake: an unknown wake fails; a known one is cancelled")
    func cancelKnownAndUnknown() async throws {
        let wake = ScheduledWake(wakeAt: Date().addingTimeInterval(60), instructions: "w")
        let cancelled = Calls<UUID>()
        let context = Self.smithContext(wakes: [wake], cancelled: cancelled)
        let unknown = UUID()
        let missed = try await CancelWakeTool().execute(arguments: ["wake_id": .string(unknown.uuidString)], context: context)
        #expect(!missed.succeeded)
        let hit = try await CancelWakeTool().execute(arguments: ["wake_id": .string(wake.id.uuidString)], context: context)
        #expect(hit.succeeded)
        #expect(await cancelled.values == [unknown, wake.id])
    }

    // MARK: - reschedule_wake

    @Test("reschedule_wake: a missing wake_id is refused")
    func rescheduleMissing() async {
        await expectMissingArgument("wake_id") { try await RescheduleWakeTool().execute(arguments: ["delay_seconds": .int(60)], context: Self.smithContext()) }
    }

    @Test("reschedule_wake: every refusal leaves the schedule untouched")
    func rescheduleRefusals() async throws {
        let wake = ScheduledWake(wakeAt: Date().addingTimeInterval(60), instructions: "w")
        let scheduled = Calls<WakeRequest>()
        let context = Self.smithContext(wakes: [wake], scheduled: scheduled)
        let refused: [[String: AnyCodable]] = [
            ["wake_id": .string("nope"), "delay_seconds": .int(60)],
            ["wake_id": .string(UUID().uuidString), "delay_seconds": .int(60)],
            ["wake_id": .string(wake.id.uuidString)],
            ["wake_id": .string(wake.id.uuidString), "delay_seconds": .int(1)],
            ["wake_id": .string(wake.id.uuidString), "delay_seconds": .int(60), "recurrence": .dictionary(["type": .string("fortnightly")])]
        ]
        for arguments in refused {
            let result = try await RescheduleWakeTool().execute(arguments: arguments, context: context)
            #expect(!result.succeeded, "\(arguments)")
        }
        #expect(await scheduled.values.isEmpty)
    }

    @Test("reschedule_wake: moves the time, replaces the wake, keeps its instructions and recurrence")
    func rescheduleKeepsWake() async throws {
        let task = UUID()
        let daily = Recurrence.daily(at: TimeOfDay(hour: 9, minute: 0))
        let wake = ScheduledWake(wakeAt: Date().addingTimeInterval(60), instructions: "check in", taskID: task, recurrence: daily)
        let scheduled = Calls<WakeRequest>()
        let before = Date()
        let result = try await RescheduleWakeTool().execute(
            arguments: ["wake_id": .string(wake.id.uuidString), "delay_seconds": .int(600)],
            context: Self.smithContext(wakes: [wake], scheduled: scheduled)
        )
        #expect(result.succeeded)
        let request = try #require(await scheduled.values.first)
        #expect(request.replacesID == wake.id)
        #expect(request.instructions == "check in")
        #expect(request.taskID == task)
        #expect(request.recurrence == daily)
        #expect(request.wakeAt.timeIntervalSince(before) >= 599)
    }

    @Test("reschedule_wake: recurrence {type: none} makes it one-shot")
    func rescheduleClearsRecurrence() async throws {
        let wake = ScheduledWake(wakeAt: Date().addingTimeInterval(60), instructions: "w", recurrence: .daily(at: TimeOfDay(hour: 9, minute: 0)))
        let scheduled = Calls<WakeRequest>()
        let result = try await RescheduleWakeTool().execute(
            arguments: ["wake_id": .string(wake.id.uuidString), "delay_seconds": .int(600), "recurrence": .dictionary(["type": .string("none")])],
            context: Self.smithContext(wakes: [wake], scheduled: scheduled)
        )
        #expect(result.succeeded)
        #expect(try #require(await scheduled.values.first).recurrence == nil)
    }

    @Test("reschedule_wake: a placeholder recurrence (null, blank, {}) keeps the existing pattern")
    func reschedulePlaceholderRecurrenceKeeps() async throws {
        let daily = Recurrence.daily(at: TimeOfDay(hour: 9, minute: 0))
        for placeholder: AnyCodable in [.null, .string(" "), .dictionary([:])] {
            let wake = ScheduledWake(wakeAt: Date().addingTimeInterval(60), instructions: "w", recurrence: daily)
            let scheduled = Calls<WakeRequest>()
            let result = try await RescheduleWakeTool().execute(
                arguments: ["wake_id": .string(wake.id.uuidString), "delay_seconds": .int(600), "recurrence": placeholder],
                context: Self.smithContext(wakes: [wake], scheduled: scheduled)
            )
            #expect(result.succeeded, "\(placeholder)")
            #expect(try #require(await scheduled.values.first).recurrence == daily, "\(placeholder)")
        }
    }

    @Test("parseRecurrence reads every placeholder (absent, null, blank, {}) as no recurrence — shared by schedule_reminder and schedule_task_action")
    func recurrencePlaceholdersAreAbsent() {
        for raw: AnyCodable? in [nil, .null, .string(""), .string("  "), .dictionary([:])] {
            guard case .value(nil) = TimerArgumentParsing.parseRecurrence(raw) else {
                Issue.record("\(String(describing: raw)) was not read as absent")
                continue
            }
        }
        guard case .invalid = TimerArgumentParsing.parseRecurrence(.string("daily")) else {
            Issue.record("a non-blank string must still be refused")
            return
        }
    }

    @Test("reschedule_wake: a runtime rejection is reported as a failure")
    func rescheduleRuntimeRejects() async throws {
        let wake = ScheduledWake(wakeAt: Date().addingTimeInterval(60), instructions: "w")
        let result = try await RescheduleWakeTool().execute(
            arguments: ["wake_id": .string(wake.id.uuidString), "delay_seconds": .int(600)],
            context: Self.smithContext(wakes: [wake], scheduleOutcome: { _ in .error("system is restarting") })
        )
        #expect(!result.succeeded)
    }
}
