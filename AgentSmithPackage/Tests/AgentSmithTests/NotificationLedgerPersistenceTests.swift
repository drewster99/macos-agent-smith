import Testing
import Foundation
@testable import AgentSmithKit

@Suite("Notification delivery ledger persistence")
struct NotificationLedgerPersistenceTests {

    private actor RuntimeSpy: NotificationRuntime {
        private(set) var autoRan: [UUID] = []
        func autoRunTask(_ taskID: UUID) async { autoRan.append(taskID) }
        func setTaskStatus(_ taskID: UUID, to status: AgentTask.Status) async -> Bool { true }
        func taskTitle(_ taskID: UUID) async -> String? { nil }
        func postSystemNotice(_ text: String, taskID: UUID?) async {}
    }

    /// A stand-in for the on-disk ledger file: the broker's `persistLedger` writes the latest
    /// snapshot here, and a "restarted" broker seeds from it — no filesystem needed to prove the
    /// round-trip logic.
    private actor LedgerDisk {
        private(set) var snapshot: [NotificationID: DeliveryStatus] = [:]
        private(set) var writeCount = 0
        func write(_ s: [NotificationID: DeliveryStatus]) { snapshot = s; writeCount += 1 }
        func read() -> [NotificationID: DeliveryStatus] { snapshot }
    }

    @Test("A delivered wake is written to the ledger; a restarted broker seeded from it dedups the re-fire")
    func ledgerSurvivesRestart() async {
        let disk = LedgerDisk()
        let runtime = RuntimeSpy()

        let broker1 = NotificationBroker(runtime: runtime, persistLedger: { await disk.write($0) })
        await broker1.registerHandler(type: "task_action", TaskActionNotificationHandler())

        let wake = ScheduledWake(wakeAt: Date(), instructions: "x", taskID: UUID(), action: .run)
        let notification = WakeNotificationFactory.notification(for: wake)
        await broker1.submit(notification)

        #expect(await runtime.autoRan.count == 1, "the wake ran once in the first lifetime")
        #expect(await disk.snapshot[notification.id] != nil, "delivery was flushed to the ledger")

        // Simulate a restart: a brand-new broker + runtime, seeded from what lifetime 1 persisted.
        let runtime2 = RuntimeSpy()
        let broker2 = NotificationBroker(runtime: runtime2, persistLedger: { await disk.write($0) })
        await broker2.registerHandler(type: "task_action", TaskActionNotificationHandler())
        await broker2.seedLedger(await disk.read())

        // The persisted scheduled_wakes.json can still carry the fired occurrence (its removal from
        // disk raced the crash). Re-submitting the SAME occurrence must be a no-op now.
        await broker2.submit(notification)
        #expect(await runtime2.autoRan.isEmpty, "the already-delivered wake must not run again after restart")
    }

    @Test("PersistenceManager round-trips the ledger through disk, preserving id and status")
    func persistenceManagerRoundTrip() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentsmith-ledger-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manager = PersistenceManager(testingRoot: tempDir)

        // Empty when nothing has been written yet.
        #expect(try await manager.loadDeliveryLedger().isEmpty)

        let deliveredID = NotificationID(namespace: "timer", key: "abc")
        let droppedID = NotificationID(namespace: "inbox", key: "def")
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let ledger: [NotificationID: DeliveryStatus] = [
            deliveredID: .delivered(stamp),
            droppedID: .dropped(reason: .expired),
        ]

        try await manager.saveDeliveryLedger(ledger)
        let loaded = try await manager.loadDeliveryLedger()

        #expect(loaded.count == 2)
        #expect(loaded[deliveredID] == .delivered(stamp))
        #expect(loaded[droppedID] == .dropped(reason: .expired))
    }

    @Test("A seeded dropped id is also honored — an expired-then-dropped wake does not resurrect")
    func seededDroppedIsHonored() async {
        let runtime = RuntimeSpy()
        let broker = NotificationBroker(runtime: runtime)
        await broker.registerHandler(type: "task_action", TaskActionNotificationHandler())

        let wake = ScheduledWake(wakeAt: Date(), instructions: "x", taskID: UUID(), action: .run)
        let notification = WakeNotificationFactory.notification(for: wake)
        await broker.seedLedger([notification.id: .dropped(reason: .expired)])

        await broker.submit(notification)
        #expect(await runtime.autoRan.isEmpty, "a settled(dropped) id is not re-delivered")
    }
}
