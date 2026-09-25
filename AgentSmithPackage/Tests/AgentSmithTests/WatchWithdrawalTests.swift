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

    @Test("Cancelling a watch withdraws the firings it had already handed off before it returns")
    func cancelWithdrawsHandedOffFiringsBeforeReturning() async throws {
        final class Calls: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: [(UUID, [Int])] = []
            func add(_ call: (UUID, [Int])) { lock.withLock { stored.append(call) } }
            var all: [(UUID, [Int])] { lock.withLock { stored } }
        }
        let calls = Calls()
        let store = TaskStore()
        await store.setWatchWithdrawal { watchID, occurrences in
            // Suspends on purpose: `cancelWatch` must still not return before this finishes.
            try? await Task.sleep(for: .milliseconds(50))
            calls.add((watchID, occurrences))
        }
        let task = await store.addTask(title: "t", description: "d")
        let watch = TaskWatch(triggers: [.completed], action: .summarizeToUser, createdBy: .user)
        #expect(await store.addWatch(watch, to: task.id) == nil)
        await store.updateStatus(id: task.id, status: .completed, cause: .smithSetStatus)
        await store.setWatchFiringState(taskID: task.id, watchID: watch.id, occurrence: 1, to: .inFlight)
        #expect(await store.cancelWatch(watch.id, on: task.id) == nil)
        let recorded = calls.all
        #expect(recorded.count == 1)
        #expect(recorded.first?.0 == watch.id)
        #expect(recorded.first?.1 == [1])
    }

    @Test("Cancelling a watch with nothing handed off asks for no withdrawal")
    func cancelWithNothingHandedOff() async throws {
        final class Count: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func bump() { lock.withLock { value += 1 } }
            var current: Int { lock.withLock { value } }
        }
        let count = Count()
        let store = TaskStore()
        await store.setWatchWithdrawal { _, _ in count.bump() }
        let task = await store.addTask(title: "t", description: "d")
        let watch = TaskWatch(triggers: [.completed], action: .summarizeToUser, createdBy: .user)
        #expect(await store.addWatch(watch, to: task.id) == nil)
        #expect(await store.cancelWatch(watch.id, on: task.id) == nil)
        #expect(count.current == 0)
    }

    @Test("A batch withdrawal claims every id before settling any, so none can be leased meanwhile")
    func batchWithdrawClaimsAll() async {
        let broker = await pullBroker()
        let items = (1...5).map { smithNote("batch\($0)") }
        for item in items { await broker.submit(item) }
        async let withdrawn = broker.withdraw(items.map(\.id), reason: "cancelled")
        async let drained = broker.drainPendingDeliveries(for: .smith)
        let (withdrawnIDs, batch) = await (withdrawn, drained)
        let leasedIDs = Set(batch.map(\.notification.id))
        #expect(Set(withdrawnIDs).isDisjoint(with: leasedIDs))
        #expect(Set(withdrawnIDs).union(leasedIDs) == Set(items.map(\.id)))
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
