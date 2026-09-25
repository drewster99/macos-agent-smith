import Testing
import Foundation
@testable import AgentSmithKit

@Suite("Watch cancellation withdraws handed-off deliveries")
struct WatchWithdrawalTests {
    private struct NoopRuntime: NotificationRuntime {
        func autoRunTask(_ taskID: UUID, amendment: String?) async -> AutoRunDispatchOutcome { .placed }
        func setTaskStatus(_ taskID: UUID, to status: AgentTask.Status) async -> Bool { true }
        func taskTitle(_ taskID: UUID) async -> String? { nil }
        func postSystemNotice(_ text: String, taskID: UUID?) async {}
        func startTaskForWatch(_ targetID: UUID, watchedTaskID: UUID, watchID: UUID, occurrence: Int) async -> AutoRunDispatchOutcome { .placed }
    }

    private func smithNote(_ key: String) -> AgentNotification {
        AgentNotification(
            id: NotificationID(namespace: "taskwatch", key: key),
            triggerSource: .taskWatch(watchID: UUID(), occurrence: 1),
            recipient: .smith, title: "t", createdAt: Date(),
            payload: Payload(type: KnownNotificationType.taskBriefing.rawValue, data: ["note": .string("do it")])
        )
    }

    private func pullBroker() async -> NotificationBroker {
        let broker = NotificationBroker(runtime: NoopRuntime())
        await broker.registerHandler(type: KnownNotificationType.taskBriefing.rawValue, TaskBriefingNotificationHandler())
        await broker.registerPullRecipient(.smith)
        return broker
    }

    @Test("A delivery queued for Smith but not yet handed out is withdrawn")
    func queuedIsWithdrawn() async {
        let broker = await pullBroker()
        let note = smithNote("queued")
        await broker.submit(note)
        #expect(await broker.withdraw([note.id], reason: "cancelled") == [note.id])
        #expect(await broker.deliveryStatus(note.id) == .dropped(reason: .withdrawn))
        #expect(await broker.drainPendingDeliveries(for: .smith).isEmpty)
    }

    @Test("A delivery Smith has already been handed cannot be withdrawn")
    func leasedIsNotWithdrawn() async {
        let broker = await pullBroker()
        let note = smithNote("leased")
        await broker.submit(note)
        _ = await broker.drainPendingDeliveries(for: .smith)
        #expect(await broker.withdraw([note.id], reason: "cancelled").isEmpty)
        #expect(await broker.deliveryStatus(note.id) == .pending)
    }

    @Test("A push waiting on a retry is withdrawn and never retried")
    func pushRetryIsWithdrawn() async {
        actor CountingTarget: RecipientTarget {
            private(set) var attempts = 0
            func deliver(_ text: String, for notification: AgentNotification) async -> PushDeliveryOutcome {
                attempts += 1
                return .retryable("busy")
            }
        }
        let broker = NotificationBroker(runtime: NoopRuntime())
        await broker.registerHandler(type: KnownNotificationType.taskBriefing.rawValue, TaskBriefingNotificationHandler())
        let target = CountingTarget()
        await broker.registerRecipientTarget(.external("macos"), target)
        let banner = AgentNotification(
            id: NotificationID(namespace: "taskwatch", key: "push"),
            triggerSource: .taskWatch(watchID: UUID(), occurrence: 1),
            recipient: .external("macos"), title: "t", createdAt: Date(),
            payload: Payload(type: KnownNotificationType.taskBriefing.rawValue, data: ["note": .string("x")])
        )
        await broker.submit(banner)
        #expect(await broker.withdraw([banner.id], reason: "cancelled") == [banner.id])
        try? await Task.sleep(for: .milliseconds(1_500))
        #expect(await target.attempts == 1, "the scheduled retry saw the withdrawal and did nothing")
        #expect(await broker.deliveryStatus(banner.id) == .dropped(reason: .withdrawn))
    }

    @Test("Cancelling a watch reports the firings it had already handed off")
    func cancelReportsHandedOffFirings() async throws {
        final class Events: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: [TaskStoreEvent] = []
            func add(_ event: TaskStoreEvent) { lock.withLock { stored.append(event) } }
            var all: [TaskStoreEvent] { lock.withLock { stored } }
        }
        let events = Events()
        let store = TaskStore()
        await store.setEventObserver { events.add($0) }
        let task = await store.addTask(title: "t", description: "d")
        let watch = TaskWatch(triggers: [.completed], action: .summarizeToUser, createdBy: .user)
        #expect(await store.addWatch(watch, to: task.id) == nil)
        await store.updateStatus(id: task.id, status: .completed, cause: .smithSetStatus)
        await store.setWatchFiringState(taskID: task.id, watchID: watch.id, occurrence: 1, to: .inFlight)
        #expect(await store.cancelWatch(watch.id, on: task.id) == nil)
        #expect(events.all.contains(.watchCancelled(taskID: task.id, watchID: watch.id, handedOffOccurrences: [1])))
    }

    @Test("A withdrawal asked for while a push attempt is under way is honored when that attempt asks for a retry")
    func withdrawDuringAttempt() async {
        actor GatedTarget: RecipientTarget {
            private(set) var attempts = 0
            private var gate: CheckedContinuation<Void, Never>?
            private var entered: CheckedContinuation<Void, Never>?
            private var hasEntered = false
            func waitUntilEntered() async {
                guard !hasEntered else { return }
                await withCheckedContinuation { entered = $0 }
            }
            func release() { gate?.resume(); gate = nil }
            func deliver(_ text: String, for notification: AgentNotification) async -> PushDeliveryOutcome {
                attempts += 1
                hasEntered = true
                entered?.resume(); entered = nil
                await withCheckedContinuation { gate = $0 }
                return .retryable("busy")
            }
        }
        let broker = NotificationBroker(runtime: NoopRuntime())
        await broker.registerHandler(type: KnownNotificationType.taskBriefing.rawValue, TaskBriefingNotificationHandler())
        let target = GatedTarget()
        await broker.registerRecipientTarget(.external("macos"), target)
        let banner = AgentNotification(
            id: NotificationID(namespace: "taskwatch", key: "gated"),
            triggerSource: .taskWatch(watchID: UUID(), occurrence: 1),
            recipient: .external("macos"), title: "t", createdAt: Date(),
            payload: Payload(type: KnownNotificationType.taskBriefing.rawValue, data: ["note": .string("x")])
        )
        let submission = Task { await broker.submit(banner) }
        await target.waitUntilEntered()
        #expect(await broker.withdraw([banner.id], reason: "cancelled").isEmpty, "mid-attempt: deferred, not yet withdrawn")
        await target.release()
        _ = await submission.value
        #expect(await broker.deliveryStatus(banner.id) == .dropped(reason: .withdrawn))
        try? await Task.sleep(for: .milliseconds(1_500))
        #expect(await target.attempts == 1, "no retry after the withdrawal")
    }
}
