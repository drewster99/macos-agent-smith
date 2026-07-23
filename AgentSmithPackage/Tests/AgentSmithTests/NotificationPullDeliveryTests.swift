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

        // Not settled — pending until the acking drain.
        #expect(await broker.deliveryStatus(n.id) == .pending)

        // Drain 1 LEASES: returns it, but it stays pending (in the outbox) for at-least-once.
        let d1 = await broker.drainPendingDeliveries(for: .smith)
        #expect(d1.map(\.text) == ["hello"])
        #expect(await broker.deliveryStatus(n.id) == .pending, "leased, not yet acked")

        // Drain 2 ACKs: the prior lease is now delivered + removed; no new batch.
        let d2 = await broker.drainPendingDeliveries(for: .smith)
        #expect(d2.isEmpty)
        if case .delivered = await broker.deliveryStatus(n.id) {} else { Issue.record("expected delivered after ack") }

        // A re-submit after delivery is deduped.
        await broker.submit(n)
        #expect(await broker.drainPendingDeliveries(for: .smith).isEmpty)
    }

    @Test("at-least-once: a leased-but-unacked drain re-delivers after a restart (never lost)")
    func atLeastOnceAcrossRestart() async {
        let disk = PendingDisk()
        let broker1 = NotificationBroker(runtime: NoopRuntime(), persistPendingDelivery: { await disk.write($0) })
        await broker1.registerHandler(type: "reminder", DeliverHandler(text: "important"))
        await broker1.registerPullRecipient(.smith)
        await broker1.submit(reminder("once"))

        // Drain 1 leases + returns it — but there is NO second drain (simulating a kill right after
        // the recipient consumed it), so it is never acked/removed from the outbox.
        #expect(await broker1.drainPendingDeliveries(for: .smith).count == 1)
        #expect(await disk.snapshot.count == 1, "still in the durable outbox — not acked")

        // Restart: a fresh broker seeded from disk re-delivers it rather than losing it.
        let broker2 = NotificationBroker(runtime: NoopRuntime(), persistPendingDelivery: { await disk.write($0) })
        await broker2.registerHandler(type: "reminder", DeliverHandler(text: "important"))
        await broker2.registerPullRecipient(.smith)
        await broker2.seedPendingDeliveries(await disk.read())
        #expect(await broker2.drainPendingDeliveries(for: .smith).map(\.text) == ["important"], "re-delivered, never lost")
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
