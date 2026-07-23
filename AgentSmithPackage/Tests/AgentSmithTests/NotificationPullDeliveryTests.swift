import Testing
import Foundation
@testable import AgentSmithKit

@Suite("NotificationBroker — pull delivery (persistence until delivery)")
struct NotificationPullDeliveryTests {

    private struct NoopRuntime: NotificationRuntime {
        func autoRunTask(_ taskID: UUID) async {}
        func setTaskStatus(_ taskID: UUID, to status: AgentTask.Status) async -> Bool { true }
        func taskTitle(_ taskID: UUID) async -> String? { nil }
        func postSystemNotice(_ text: String, taskID: UUID?) async {}
    }

    private struct DeliverHandler: NotificationHandler {
        let text: String
        func handle(_ n: AgentNotification, runtime: any NotificationRuntime) async throws -> HandlerOutcome {
            .deliver(text)
        }
    }

    private func reminder(_ key: String) -> AgentNotification {
        AgentNotification(
            id: NotificationID(namespace: "timer", key: key),
            triggerSource: .timer(scheduleID: UUID(), occurrence: Date(timeIntervalSince1970: 1)),
            recipient: .smith, title: "t", createdAt: Date(),
            payload: Payload(type: "reminder")
        )
    }

    @Test("a .deliver to a pull recipient is queued, not pushed; drain returns it and marks delivered")
    func queuedThenDrained() async {
        let broker = NotificationBroker(runtime: NoopRuntime())
        await broker.registerHandler(type: "reminder", DeliverHandler(text: "hello"))
        await broker.registerPullRecipient(.smith)

        let n = reminder("a")
        await broker.submit(n)

        // Not settled yet — it's pending until drained.
        #expect(await broker.deliveryStatus(n.id) == .pending)

        let drained = await broker.drainPendingDeliveries(for: .smith)
        #expect(drained.map(\.text) == ["hello"])
        if case .delivered = await broker.deliveryStatus(n.id) {} else { Issue.record("expected delivered after drain") }

        // A second drain is empty; a re-submit is deduped (already delivered).
        #expect(await broker.drainPendingDeliveries(for: .smith).isEmpty)
        await broker.submit(n)
        #expect(await broker.drainPendingDeliveries(for: .smith).isEmpty)
    }

    @Test("a queued-but-undrained notification is not re-enqueued on re-post")
    func noDoubleEnqueue() async {
        let broker = NotificationBroker(runtime: NoopRuntime())
        await broker.registerHandler(type: "reminder", DeliverHandler(text: "x"))
        await broker.registerPullRecipient(.smith)

        let n = reminder("dup")
        await broker.submit(n)
        await broker.submit(n)   // same id, still queued → ignored

        #expect(await broker.drainPendingDeliveries(for: .smith).count == 1)
    }

    @Test("the nudge fires when something is enqueued for a pull recipient")
    func nudgeFires() async {
        let broker = NotificationBroker(runtime: NoopRuntime())
        await broker.registerHandler(type: "reminder", DeliverHandler(text: "x"))
        await broker.registerPullRecipient(.smith)

        let box = NudgeBox()
        await broker.setOnPendingEnqueued { kind in Task { await box.record(kind) } }
        await broker.submit(reminder("n"))
        // Give the detached nudge task a moment.
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await box.kinds.contains(.smith))
    }

    @Test("the pending queue persists and re-seeds across a restart")
    func persistsAndSeeds() async {
        let disk = PendingDisk()
        let broker1 = NotificationBroker(runtime: NoopRuntime(), persistPendingDelivery: { await disk.write($0) })
        await broker1.registerHandler(type: "reminder", DeliverHandler(text: "survive"))
        await broker1.registerPullRecipient(.smith)
        await broker1.submit(reminder("persisted"))
        #expect(await disk.snapshot.count == 1, "enqueue flushed to the pending file")

        // Restart: a fresh broker seeded from disk still has the undrained item.
        let broker2 = NotificationBroker(runtime: NoopRuntime(), persistPendingDelivery: { await disk.write($0) })
        await broker2.registerHandler(type: "reminder", DeliverHandler(text: "survive"))
        await broker2.registerPullRecipient(.smith)
        await broker2.seedPendingDeliveries(await disk.read())

        let drained = await broker2.drainPendingDeliveries(for: .smith)
        #expect(drained.map(\.text) == ["survive"], "the undelivered reminder survived the restart")
    }

    private actor NudgeBox {
        private(set) var kinds: [RecipientKind] = []
        func record(_ kind: RecipientKind) { kinds.append(kind) }
    }

    private actor PendingDisk {
        private(set) var snapshot: [QueuedDelivery] = []
        func write(_ items: [QueuedDelivery]) { snapshot = items }
        func read() -> [QueuedDelivery] { snapshot }
    }
}
