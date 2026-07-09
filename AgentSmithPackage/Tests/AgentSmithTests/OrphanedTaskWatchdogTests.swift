import Foundation
import Testing
@testable import AgentSmithKit

/// The zombie-task defenses: `update_task` cannot mint an in-flight status, and the
/// monitor's watchdog recovers a `running` task that has no worker (the shape that
/// spins in the UI forever and blocks the auto-run queue).

@Suite("Orphaned running-task defenses")
struct OrphanedTaskWatchdogTests {

    @Test("update_task refuses to set `running` directly")
    func updateTaskRefusesRunning() async throws {
        let taskStore = TaskStore()
        let task = await taskStore.addTask(title: "t", description: "d")
        let context = TestToolContext.make(agentRole: .smith, taskStore: taskStore)

        let result = try await UpdateTaskTool().execute(
            arguments: ["task_id": .string(task.id.uuidString), "status": .string("running")],
            context: context
        )
        #expect(!result.succeeded)
        #expect(result.output.contains("run_task"), "the refusal must teach the correct tool")
        #expect(await taskStore.task(id: task.id)?.status == .pending)
    }

    @Test("The watchdog interrupts a running task with no worker after two ticks, sparing assigned ones")
    func watchdogRecoversOrphan() async throws {
        let taskStore = TaskStore()
        let channel = MessageChannel()
        let orphan = await taskStore.addTask(title: "Orphaned", description: "d")
        await taskStore.updateStatus(id: orphan.id, status: .running)
        let healthy = await taskStore.addTask(title: "Healthy", description: "d")
        await taskStore.updateStatus(id: healthy.id, status: .running)
        await taskStore.assignAgent(taskID: healthy.id, agentID: UUID())

        let timer = MonitoringTimer(interval: 0.05, channel: channel, taskStore: taskStore)
        await timer.start()
        defer { Task { await timer.stop() } }

        // Poll until the two-strike rule fires (needs ≥2 ticks; allow generous slack).
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await taskStore.task(id: orphan.id)?.status == .interrupted { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        #expect(await taskStore.task(id: orphan.id)?.status == .interrupted, "orphan is recovered")
        #expect(await taskStore.task(id: healthy.id)?.status == .running, "a task WITH a worker is untouched")

        let posted = await channel.allMessages()
        #expect(posted.contains { message in
            if case .string("task_update_guidance") = message.metadata?["messageKind"] {
                return message.content.contains("Orphaned")
            }
            return false
        }, "the recovery is announced with Smith-visible guidance")
    }
}
