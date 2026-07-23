import Testing
import Foundation
@testable import AgentSmithKit

@Suite("WakeScheduler — timer-driven notification production")
struct WakeSchedulerTests {

    private actor RuntimeSpy: NotificationRuntime {
        private(set) var autoRan: [UUID] = []
        func autoRunTask(_ taskID: UUID) async { autoRan.append(taskID) }
        func setTaskStatus(_ taskID: UUID, to status: AgentTask.Status) async -> Bool { true }
        func taskTitle(_ taskID: UUID) async -> String? { nil }
        func postSystemNotice(_ text: String, taskID: UUID?) async {}
    }

    private actor Captured {
        private(set) var persisted: [[ScheduledWake]] = []
        private(set) var promoted: [UUID] = []
        func recordPersist(_ wakes: [ScheduledWake]) { persisted.append(wakes) }
        func recordPromote(_ id: UUID) { promoted.append(id) }
        var lastPersisted: [ScheduledWake] { persisted.last ?? [] }
    }

    private func makeBroker(_ runtime: RuntimeSpy) async -> NotificationBroker {
        let broker = NotificationBroker(runtime: runtime)
        await broker.registerHandler(type: "task_action", TaskActionNotificationHandler())
        await broker.registerHandler(type: "reminder", ReminderNotificationHandler())
        await broker.registerPullRecipient(.smith)
        return broker
    }

    @Test("scheduling persists the wake and fires the onScheduled callback")
    func schedulePersists() async {
        let captured = Captured()
        let scheduler = WakeScheduler()
        await scheduler.restore([])   // mark restored so persistence is armed
        await scheduler.setPersistence { await captured.recordPersist($0) }

        let outcome = await scheduler.scheduleWake(wakeAt: Date().addingTimeInterval(3600), instructions: "ping", action: nil)
        guard case .scheduled = outcome else { Issue.record("expected scheduled"); return }
        #expect(await scheduler.listScheduledWakes().count == 1)
        #expect(await captured.lastPersisted.count == 1)
    }

    @Test("a fired run wake promotes its task and produces a task_action that runs it")
    func firedRunWakeRunsTask() async {
        let runtime = RuntimeSpy()
        let broker = await makeBroker(runtime)
        let captured = Captured()
        let taskID = UUID()

        let scheduler = WakeScheduler()
        await scheduler.setBroker(broker)
        await scheduler.setPromotion { await captured.recordPromote($0) }
        await scheduler.restore([
            ScheduledWake(wakeAt: Date().addingTimeInterval(-1), instructions: "run", taskID: taskID, action: .run)
        ])

        await scheduler.fireDue()

        #expect(await captured.promoted == [taskID], "the scheduled task was promoted before running")
        #expect(await runtime.autoRan == [taskID], "the run wake produced a task_action the broker ran")
        #expect(await scheduler.listScheduledWakes().isEmpty, "a one-shot fired wake is removed")
    }

    @Test("a fired reminder wake is queued for Smith to drain, not pushed")
    func firedReminderQueuesForSmith() async {
        let runtime = RuntimeSpy()
        let broker = await makeBroker(runtime)
        let scheduler = WakeScheduler()
        await scheduler.setBroker(broker)
        await scheduler.restore([
            ScheduledWake(wakeAt: Date().addingTimeInterval(-1), instructions: "stretch", action: nil)
        ])

        await scheduler.fireDue()

        let drained = await broker.drainPendingDeliveries(for: .smith)
        #expect(drained.count == 1)
        #expect(drained.first?.text.contains("stretch") == true)
    }

    @Test("a fired recurring wake schedules its next occurrence in the FUTURE (no catch-up storm)")
    func recurringWakeRollsForwardToFuture() async {
        let runtime = RuntimeSpy()
        let broker = await makeBroker(runtime)
        let scheduler = WakeScheduler()
        await scheduler.setBroker(broker)
        // A 60s-interval reminder whose last fire was a full day ago.
        await scheduler.restore([
            ScheduledWake(wakeAt: Date().addingTimeInterval(-86_400), instructions: "hourly", recurrence: .interval(seconds: 60), action: nil)
        ])

        await scheduler.fireDue()

        let remaining = await scheduler.listScheduledWakes()
        #expect(remaining.count == 1, "exactly one successor, not a backlog")
        #expect(remaining.first!.wakeAt > Date(), "the successor is in the future — catch-up collapsed")
    }

    @Test("cancelWakesForTask removes non-surviving wakes, keeps survivors")
    func cancelForTaskKeepsSurvivors() async {
        let taskID = UUID()
        let scheduler = WakeScheduler()
        await scheduler.restore([
            ScheduledWake(wakeAt: Date().addingTimeInterval(600), instructions: "transient", taskID: taskID, survivesTaskTermination: false, action: .summarize),
            ScheduledWake(wakeAt: Date().addingTimeInterval(600), instructions: "survivor", taskID: taskID, survivesTaskTermination: true, action: .run),
        ])
        let cancelled = await scheduler.cancelWakesForTask(taskID)
        #expect(cancelled.count == 1)
        let remaining = await scheduler.listScheduledWakes()
        #expect(remaining.count == 1)
        #expect(remaining.first?.survivesTaskTermination == true)
    }
}
