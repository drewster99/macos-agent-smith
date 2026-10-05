import Testing
import Foundation
@testable import AgentSmithKit

@Suite("NotificationBroker — pull delivery (persistence until delivery)")
struct NotificationPullDeliveryTests {

    private struct NoopRuntime: NotificationRuntime {
        func autoRunTask(_ taskID: UUID, amendment: String?) async -> AutoRunDispatchOutcome { .placed }
        func setTaskStatus(_ taskID: UUID, to status: AgentTask.Status) async -> Bool { true }
        func taskTitle(_ taskID: UUID) async -> String? { nil }
        func postSystemNotice(_ text: String, taskID: UUID?) async {}
        func startTaskForWatch(_ targetID: UUID, watchedTaskID: UUID, watchID: UUID, occurrence: Int) async -> AutoRunDispatchOutcome { .placed }
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

        // Not settled — pending until acknowledged.
        #expect(await broker.deliveryStatus(n.id) == .pending)
        let generation = await broker.resetLease(for: .smith)

        // Drain 1 LEASES: returns it, but it stays pending (in the outbox) for at-least-once.
        let d1 = await broker.drainPendingDeliveries(for: .smith)
        #expect(d1.map(\.text) == ["hello"])
        #expect(await broker.deliveryStatus(n.id) == .pending, "leased, not yet acked")

        // Drain 2 hands out nothing new: a leased item is not handed out twice.
        #expect(await broker.drainPendingDeliveries(for: .smith).isEmpty)
        #expect(await broker.deliveryStatus(n.id) == .pending, "still not acknowledged")

        // The recipient acknowledges once it has acted: delivered + removed.
        await broker.acknowledgeDeliveries([n.id], for: .smith, leaseGeneration: generation)
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

    @Test("resetLease: a re-spawned recipient re-delivers the outbox instead of acking away the prior lease")
    func resetLeaseReDelivers() async {
        let broker = NotificationBroker(runtime: NoopRuntime())
        await broker.registerHandler(type: "reminder", DeliverHandler(text: "keep"))
        await broker.registerPullRecipient(.smith)
        await broker.submit(reminder("x"))

        // Smith-A drains — leases it, still in the durable outbox.
        let oldGeneration = await broker.resetLease(for: .smith)
        #expect(await broker.drainPendingDeliveries(for: .smith).map(\.text) == ["keep"])

        // Smith-A is torn down and a NEW Smith wired: the runtime clears the lease. The new Smith's
        // first drain must RE-DELIVER the item Smith-A never acknowledged.
        let newGeneration = await broker.resetLease(for: .smith)
        #expect(await broker.drainPendingDeliveries(for: .smith).map(\.text) == ["keep"], "re-delivered after re-spawn")
        // A late acknowledgement from Smith-A is ignored — Smith-B has not acted on it yet.
        await broker.acknowledgeDeliveries([reminder("x").id], for: .smith, leaseGeneration: oldGeneration)
        #expect(await broker.deliveryStatus(reminder("x").id) == .pending, "a stale acknowledgement removes nothing")
        // Smith-B's acknowledgement settles it.
        await broker.acknowledgeDeliveries([reminder("x").id], for: .smith, leaseGeneration: newGeneration)
        if case .delivered = await broker.deliveryStatus(reminder("x").id) {} else { Issue.record("delivered after ack") }
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

    // MARK: - Task-worker recipients (coordinator notes)

    private func workerNote(_ key: String, taskID: UUID) -> AgentNotification {
        AgentNotification(
            id: NotificationID(namespace: "tasktransition", key: key),
            triggerSource: .taskTransition(taskID: UUID(), statusRevision: 1),
            recipient: .taskWorker(taskID: taskID), title: "t", createdAt: Date(),
            payload: Payload(type: "coordinator_briefing")
        )
    }

    private func workerBroker() async -> NotificationBroker {
        let broker = NotificationBroker(runtime: NoopRuntime())
        await broker.registerHandler(type: "coordinator_briefing", DeliverHandler(text: "note"))
        await broker.registerPullRecipient(.taskWorker)
        await broker.registerPullRecipient(.smith)
        return broker
    }

    @Test("each task's worker has its own queue, lease and generation")
    func workerLeasesAreIndependent() async {
        let broker = await workerBroker()
        let taskA = UUID(), taskB = UUID()
        let noteA = workerNote("a", taskID: taskA), noteB = workerNote("b", taskID: taskB)
        await broker.submit(noteA)
        await broker.submit(noteB)
        let generationA = await broker.resetLease(for: .taskWorker(taskID: taskA))
        let generationB = await broker.resetLease(for: .taskWorker(taskID: taskB))

        #expect(await broker.drainPendingDeliveries(for: .taskWorker(taskID: taskA)).map(\.notification.id) == [noteA.id])
        #expect(await broker.drainPendingDeliveries(for: .smith).isEmpty, "Smith never gets a worker's note")
        // An acknowledgement for A's note carrying B's generation names the wrong lease: ignored.
        await broker.acknowledgeDeliveries([noteA.id], for: .taskWorker(taskID: taskA), leaseGeneration: generationB + 100)
        #expect(await broker.deliveryStatus(noteA.id) == .pending)
        // Resetting A's lease re-hands only A's note; B's is untouched and still un-handed.
        await broker.resetLease(for: .taskWorker(taskID: taskA))
        #expect(await broker.queuedDeliveries(for: .taskWorker(taskID: taskA)).map(\.isLeased) == [false])
        #expect(await broker.drainPendingDeliveries(for: .taskWorker(taskID: taskB)).map(\.notification.id) == [noteB.id])
        await broker.acknowledgeDeliveries([noteB.id], for: .taskWorker(taskID: taskB), leaseGeneration: generationB)
        if case .delivered = await broker.deliveryStatus(noteB.id) {} else { Issue.record("B's note was not delivered on ack") }
        _ = generationA
    }

    @Test("the nudge names the exact recipient")
    func nudgeNamesWorker() async {
        let broker = await workerBroker()
        let box = NudgeBox()
        await broker.setOnPendingEnqueued { recipient in Task { await box.record(recipient) } }
        let taskID = UUID()
        await broker.submit(workerNote("n", taskID: taskID))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await box.kinds == [.taskWorker(taskID: taskID)])
    }

    @Test("reclaim takes leased and unleased items, settles them withdrawn, and leaves later ones alone")
    func reclaimQueued() async {
        let disk = PendingDisk()
        let broker = NotificationBroker(runtime: NoopRuntime(), persistPendingDelivery: { await disk.write($0) })
        await broker.registerHandler(type: "coordinator_briefing", DeliverHandler(text: "note"))
        await broker.registerPullRecipient(.taskWorker)
        let taskID = UUID()
        let recipient = Recipient.taskWorker(taskID: taskID)
        let leasedNote = workerNote("leased", taskID: taskID)
        let unleasedNote = workerNote("unleased", taskID: taskID)
        await broker.submit(leasedNote)
        let generation = await broker.resetLease(for: recipient)
        _ = await broker.drainPendingDeliveries(for: recipient)
        await broker.submit(unleasedNote)
        #expect(await broker.recipientsWithQueuedDeliveries() == [recipient])

        let later = workerNote("later", taskID: taskID)
        let reclaimed = await broker.reclaimQueued([leasedNote.id, unleasedNote.id], reason: "gone")
        await broker.submit(later)
        #expect(Set(reclaimed) == [leasedNote.id, unleasedNote.id])
        #expect(await broker.deliveryStatus(leasedNote.id) == .dropped(reason: .withdrawn))
        #expect(await broker.deliveryStatus(unleasedNote.id) == .dropped(reason: .withdrawn))
        #expect(await broker.queuedDeliveries(for: recipient).map(\.delivery.notification.id) == [later.id])
        #expect(await disk.snapshot.map(\.notification.id) == [later.id])
        // A late acknowledgement for a reclaimed id changes nothing.
        await broker.acknowledgeDeliveries([leasedNote.id], for: recipient, leaseGeneration: generation)
        #expect(await broker.deliveryStatus(leasedNote.id) == .dropped(reason: .withdrawn))
    }

    private actor NudgeBox {
        private(set) var kinds: [Recipient] = []
        func record(_ recipient: Recipient) { kinds.append(recipient) }
    }

    private actor PendingDisk {
        private(set) var snapshot: [QueuedDelivery] = []
        func write(_ items: [QueuedDelivery]) { snapshot = items }
        func read() -> [QueuedDelivery] { snapshot }
    }
}
