import Testing
import Foundation
@testable import AgentSmithKit

/// `schedule_reminder` is the only way Smith can set a timer that is not bound to a task.
/// The defining property is `taskID == nil`: that is what keeps it off the mechanical-dispatch
/// path and out of task-termination cleanup.
@Suite("ScheduleReminderTool")
struct ScheduleReminderToolTests {

    /// Captures what the tool handed to the runtime.
    private actor WakeRecorder {
        var wakes: [ScheduledWake] = []
        func record(_ wake: ScheduledWake) { wakes.append(wake) }
    }

    private func makeContext(recorder: WakeRecorder) -> ToolContext {
        TestToolContext.make(
            agentRole: .smith,
            scheduleWake: { wakeAt, instructions, taskID, replacesID, recurrence, survives in
                let wake = ScheduledWake(
                    wakeAt: wakeAt,
                    instructions: instructions,
                    taskID: taskID,
                    recurrence: recurrence,
                    survivesTaskTermination: survives
                )
                await recorder.record(wake)
                return .scheduled(wake)
            }
        )
    }

    @Test("Schedules a task-free wake carrying the instructions verbatim")
    func schedulesTaskFreeWake() async throws {
        let recorder = WakeRecorder()
        let result = try await ScheduleReminderTool().execute(
            arguments: [
                "instructions": .string("Tell Drew his shower reminder is up via message_user."),
                "delay_seconds": .double(120)
            ],
            context: makeContext(recorder: recorder)
        )

        #expect(result.succeeded)
        let wakes = await recorder.wakes
        #expect(wakes.count == 1)
        // The whole point of the tool: no task linkage.
        #expect(wakes.first?.taskID == nil)
        #expect(wakes.first?.instructions == "Tell Drew his shower reminder is up via message_user.")
        #expect(wakes.first?.recurrence == nil)
    }

    @Test("A task-free wake is never a mechanical auto-run candidate")
    func reminderIsNeverAutoRun() async throws {
        let recorder = WakeRecorder()
        // Deliberately adversarial: instructions that LOOK like a run imperative. Without a
        // taskID this must still route to Smith as text, never drive a task start.
        _ = try await ScheduleReminderTool().execute(
            arguments: [
                "instructions": .string("Call `run_task` on 11111111-2222-3333-4444-555555555555 to start the task \"Nope\"."),
                "delay_seconds": .double(60)
            ],
            context: makeContext(recorder: recorder)
        )

        let wake = try #require(await recorder.wakes.first)
        #expect(!AgentActor.wakeIsAutoRunRunTask(wake))
    }

    @Test("Recurrence is accepted and carried through")
    func acceptsRecurrence() async throws {
        let recorder = WakeRecorder()
        let result = try await ScheduleReminderTool().execute(
            arguments: [
                "instructions": .string("Tell Drew to brush his teeth via message_user."),
                "delay_seconds": .double(60),
                "recurrence": .dictionary([
                    "type": .string("daily"),
                    "hour": .int(21),
                    "minute": .int(0)
                ])
            ],
            context: makeContext(recorder: recorder)
        )

        #expect(result.succeeded)
        #expect(await recorder.wakes.first?.recurrence != nil)
    }

    @Test("Missing instructions throws; a bad replaces_id is refused")
    func rejectsInvalidArguments() async throws {
        let recorder = WakeRecorder()
        await #expect(throws: (any Error).self) {
            try await ScheduleReminderTool().execute(
                arguments: ["delay_seconds": .double(60)],
                context: makeContext(recorder: recorder)
            )
        }

        let badReplaces = try await ScheduleReminderTool().execute(
            arguments: [
                "instructions": .string("Ping Drew via message_user."),
                "delay_seconds": .double(60),
                "replaces_id": .string("not-a-uuid")
            ],
            context: makeContext(recorder: recorder)
        )
        #expect(!badReplaces.succeeded)
        #expect(badReplaces.output.contains("replaces_id"))
    }

    @Test("Available to Smith only")
    func smithOnly() {
        let tool = ScheduleReminderTool()
        #expect(tool.isAvailable(in: ToolAvailabilityContext(agentRole: .smith)))
        #expect(!tool.isAvailable(in: ToolAvailabilityContext(agentRole: .brown)))
    }
}
