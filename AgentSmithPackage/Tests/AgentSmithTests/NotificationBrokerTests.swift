import Testing
import Foundation
@testable import AgentSmithKit

@Suite("NotificationBroker")
struct NotificationBrokerTests {

    // MARK: - Test doubles

    private struct NoopRuntime: NotificationRuntime {
        func autoRunTask(_ taskID: UUID) async {}
        func setTaskStatus(_ taskID: UUID, to status: AgentTask.Status) async {}
        func taskTitle(_ taskID: UUID) async -> String? { nil }
        func postSystemNotice(_ text: String, taskID: UUID?) async {}
    }

    private actor CallLog {
        private(set) var handled: [NotificationID] = []
        private(set) var delivered: [(text: String, recipient: Recipient)] = []
        private(set) var observed: [NotificationID] = []
        func recordHandled(_ id: NotificationID) { handled.append(id) }
        func recordDelivered(_ text: String, _ recipient: Recipient) { delivered.append((text, recipient)) }
        func recordObserved(_ id: NotificationID) { observed.append(id) }
    }

    private struct RecordingHandler: NotificationHandler {
        let log: CallLog
        let outcome: HandlerOutcome
        let shouldThrow: Bool

        init(log: CallLog, outcome: HandlerOutcome = .acted, shouldThrow: Bool = false) {
            self.log = log
            self.outcome = outcome
            self.shouldThrow = shouldThrow
        }

        func handle(_ notification: AgentNotification, runtime: any NotificationRuntime) async throws -> HandlerOutcome {
            await log.recordHandled(notification.id)
            try await Task.sleep(for: .milliseconds(5))   // widen the race window for the dedup tests
            if shouldThrow { throw NotificationTestError.boom }
            return outcome
        }
    }

    private struct RecordingTarget: RecipientTarget {
        let log: CallLog
        let succeed: Bool
        func deliver(_ text: String, for notification: AgentNotification) async -> Bool {
            await log.recordDelivered(text, notification.recipient)
            return succeed
        }
    }

    private enum NotificationTestError: Error { case boom }

    private func makeBroker() -> NotificationBroker {
        NotificationBroker(runtime: NoopRuntime())
    }

    private func timerTrigger() -> TriggerSource {
        .timer(scheduleID: UUID(), occurrence: Date(timeIntervalSince1970: 1_000))
    }

    // MARK: - Tests

    @Test("A registered .acted handler marks the notification delivered")
    func actedHandlerDelivers() async {
        let log = CallLog()
        let broker = makeBroker()
        await broker.registerHandler(type: "task_action", RecordingHandler(log: log, outcome: .acted))

        let id = await broker.post(
            triggerSource: timerTrigger(), recipient: .runtime,
            payload: Payload(type: "task_action"), title: "t", idempotencyKey: "k1"
        )

        #expect(await log.handled == [id])
        if case .delivered = await broker.deliveryStatus(id) {} else { Issue.record("expected delivered") }
    }

    @Test("Same idempotency key delivers once — the second post is a no-op")
    func dedupOnIdempotencyKey() async {
        let log = CallLog()
        let broker = makeBroker()
        await broker.registerHandler(type: "reminder", RecordingHandler(log: log, outcome: .deliver("hi")))
        await broker.registerRecipientTarget(.smith, RecordingTarget(log: log, succeed: true))

        let trigger = timerTrigger()
        let id1 = await broker.post(triggerSource: trigger, recipient: .smith, payload: Payload(type: "reminder"), title: "t", idempotencyKey: "same")
        let id2 = await broker.post(triggerSource: trigger, recipient: .smith, payload: Payload(type: "reminder"), title: "t", idempotencyKey: "same")

        #expect(id1 == id2, "same namespace + key → same deterministic id")
        #expect(await log.handled.count == 1)
        #expect(await log.delivered.count == 1)
    }

    @Test("Concurrent duplicate posts deliver exactly once (in-flight guard)")
    func concurrentDuplicateDeliversOnce() async {
        let log = CallLog()
        let broker = makeBroker()
        await broker.registerHandler(type: "task_action", RecordingHandler(log: log, outcome: .acted))
        let trigger = timerTrigger()

        async let a = broker.post(triggerSource: trigger, recipient: .runtime, payload: Payload(type: "task_action"), title: "t", idempotencyKey: "race")
        async let b = broker.post(triggerSource: trigger, recipient: .runtime, payload: Payload(type: "task_action"), title: "t", idempotencyKey: "race")
        _ = await (a, b)

        #expect(await log.handled.count == 1)
    }

    @Test("An unknown type is a safe no-op — dropped(noHandler), handler never runs")
    func unknownTypeNoOps() async {
        let log = CallLog()
        let broker = makeBroker()
        // A handler for a DIFFERENT type; the posted type has none.
        await broker.registerHandler(type: "reminder", RecordingHandler(log: log))

        let id = await broker.post(triggerSource: timerTrigger(), recipient: .smith, payload: Payload(type: "type_from_a_newer_build"), title: "t", idempotencyKey: "u1")

        #expect(await log.handled.isEmpty)
        #expect(await broker.deliveryStatus(id) == .dropped(reason: .noHandler))
    }

    @Test("A .deliver outcome routes to the recipient-kind target")
    func deliverRoutesToTarget() async {
        let log = CallLog()
        let broker = makeBroker()
        await broker.registerHandler(type: "reminder", RecordingHandler(log: log, outcome: .deliver("wake up")))
        await broker.registerRecipientTarget(.smith, RecordingTarget(log: log, succeed: true))

        let id = await broker.post(triggerSource: timerTrigger(), recipient: .smith, payload: Payload(type: "reminder"), title: "t", idempotencyKey: "d1")

        #expect(await log.delivered.map(\.text) == ["wake up"])
        if case .delivered = await broker.deliveryStatus(id) {} else { Issue.record("expected delivered") }
    }

    @Test("A .deliver with no registered target drops(noRecipientTarget) and does not deliver")
    func deliverWithoutTarget() async {
        let log = CallLog()
        let broker = makeBroker()
        await broker.registerHandler(type: "reminder", RecordingHandler(log: log, outcome: .deliver("x")))
        // No recipient target registered.

        let id = await broker.post(triggerSource: timerTrigger(), recipient: .smith, payload: Payload(type: "reminder"), title: "t", idempotencyKey: "d2")

        #expect(await log.delivered.isEmpty)
        #expect(await broker.deliveryStatus(id) == .dropped(reason: .noRecipientTarget))
    }

    @Test("A target that returns false leaves the notification unsettled for retry")
    func failedDeliveryStaysPending() async {
        let log = CallLog()
        let broker = makeBroker()
        await broker.registerHandler(type: "reminder", RecordingHandler(log: log, outcome: .deliver("x")))
        await broker.registerRecipientTarget(.smith, RecordingTarget(log: log, succeed: false))

        let id = await broker.post(triggerSource: timerTrigger(), recipient: .smith, payload: Payload(type: "reminder"), title: "t", idempotencyKey: "d3")

        #expect(await broker.deliveryStatus(id) == .pending, "not settled → a later tick can retry")
    }

    @Test("An expired notification drops(expired) without running the handler")
    func expiredDrops() async {
        let log = CallLog()
        let broker = makeBroker()
        await broker.registerHandler(type: "reminder", RecordingHandler(log: log, outcome: .deliver("x")))
        await broker.registerRecipientTarget(.smith, RecordingTarget(log: log, succeed: true))

        let id = await broker.post(
            triggerSource: timerTrigger(), recipient: .smith, payload: Payload(type: "reminder"),
            title: "t", idempotencyKey: "e1", expiresAt: Date(timeIntervalSince1970: 1)
        )

        #expect(await log.handled.isEmpty)
        #expect(await broker.deliveryStatus(id) == .dropped(reason: .expired))
    }

    @Test("A throwing handler drops(handlerError) and never marks delivered")
    func handlerErrorDrops() async {
        let log = CallLog()
        let broker = makeBroker()
        await broker.registerHandler(type: "task_action", RecordingHandler(log: log, shouldThrow: true))

        let id = await broker.post(triggerSource: timerTrigger(), recipient: .runtime, payload: Payload(type: "task_action"), title: "t", idempotencyKey: "err")

        #expect(await broker.deliveryStatus(id) == .dropped(reason: .handlerError))
    }

    @Test("Observers see matching notifications; non-matching filters skip")
    func observerFanOut() async {
        let log = CallLog()
        let broker = makeBroker()
        await broker.registerHandler(type: "reminder", RecordingHandler(log: log, outcome: .deliver("x")))
        await broker.registerRecipientTarget(.smith, RecordingTarget(log: log, succeed: true))
        await broker.observe(where: .type("reminder")) { await log.recordObserved($0.id) }
        await broker.observe(where: .type("something_else")) { _ in Issue.record("non-matching observer fired") }

        let id = await broker.post(triggerSource: timerTrigger(), recipient: .smith, payload: Payload(type: "reminder"), title: "t", idempotencyKey: "o1")

        #expect(await log.observed == [id])
    }

    @Test("A seeded delivered id is recognized after restart — re-post is a no-op")
    func seededLedgerDedups() async {
        let log = CallLog()
        let broker = makeBroker()
        await broker.registerHandler(type: "task_action", RecordingHandler(log: log, outcome: .acted))
        let trigger = timerTrigger()
        let id = NotificationID(namespace: trigger.namespace, key: "seeded")
        await broker.seedLedger([id: .delivered(Date())])

        _ = await broker.post(triggerSource: trigger, recipient: .runtime, payload: Payload(type: "task_action"), title: "t", idempotencyKey: "seeded")

        #expect(await log.handled.isEmpty, "already-delivered id must not re-run the handler")
    }

    @Test("Every first-party KnownNotificationType has a distinct rawValue")
    func knownTypesAreDistinct() {
        let raws = KnownNotificationType.allCases.map(\.rawValue)
        #expect(Set(raws).count == raws.count)
        #expect(KnownNotificationType.taskAction.rawValue == "task_action")
        #expect(KnownNotificationType.userMessage.rawValue == "user_message")
    }

    @Test("TriggerSource round-trips, and an unknown kind from a newer build decodes to .unknown")
    func triggerSourceForwardCompatDecode() throws {
        // Round-trip the known cases.
        for source in [TriggerSource.timer(scheduleID: UUID(), occurrence: Date(timeIntervalSince1970: 5)), .inboundMessageObserver, .unknown] {
            let data = try JSONEncoder().encode(source)
            #expect(try JSONDecoder().decode(TriggerSource.self, from: data) == source)
        }
        // A payload a NEWER build would write for a case this build lacks must NOT throw — it
        // decodes to `.unknown`, so one element can't brick a co-persisted array.
        let futureData = try #require("{\"kind\":\"webhook\",\"subscriptionID\":\"abc\"}".data(using: .utf8))
        #expect(try JSONDecoder().decode(TriggerSource.self, from: futureData) == .unknown)
    }
}
