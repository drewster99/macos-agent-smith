import Foundation
import os

/// A predicate over notifications, for observer subscriptions.
public struct NotificationFilter: Sendable {
    let matches: @Sendable (AgentNotification) -> Bool

    public init(_ matches: @escaping @Sendable (AgentNotification) -> Bool) {
        self.matches = matches
    }

    public static let all = NotificationFilter { _ in true }
    public static func type(_ type: String) -> NotificationFilter { .init { $0.payload.type == type } }
    public static func recipient(_ kind: RecipientKind) -> NotificationFilter { .init { $0.recipient.kind == kind } }
}

/// Handle returned by `observe`; pass it to `removeObserver` to stop watching.
public struct ObserverToken: Hashable, Sendable {
    let id: UUID
}

/// Handle a source uses to post event-driven notifications. Namespaces the id by the source's
/// trigger so two sources' idempotency keys can never collide.
public struct SourceHandle: Sendable {
    private let broker: NotificationBroker

    init(broker: NotificationBroker) {
        self.broker = broker
    }

    /// Post a notification. The `idempotencyKey` MUST be deterministic from durable state (so a
    /// re-post after a crash yields the same id). Returns the derived id.
    @discardableResult
    public func post(
        triggerSource: TriggerSource,
        recipient: Recipient,
        payload: Payload,
        title: String,
        idempotencyKey: String,
        expiresAt: Date? = nil
    ) async -> NotificationID {
        await broker.post(
            triggerSource: triggerSource,
            recipient: recipient,
            payload: payload,
            title: title,
            idempotencyKey: idempotencyKey,
            expiresAt: expiresAt
        )
    }
}

/// The notification hub. Producers register to send; consumers register a per-type handler and a
/// per-recipient-kind target to receive (effectful, exactly-once); observers subscribe with a
/// predicate to watch (fan-out, no effect). The broker is an actor, which serializes all
/// notification-state mutation — that is the CONCURRENCY answer. DURABILITY (crash between produce
/// and commit) is separate: the deterministic id + `DeliveryLedger` give effectively-once.
public actor NotificationBroker {
    private var handlers: [String: any NotificationHandler] = [:]
    private var targets: [RecipientKind: any RecipientTarget] = [:]
    private var observers: [ObserverToken: (filter: NotificationFilter, sink: @Sendable (AgentNotification) async -> Void)] = [:]
    private var sources: [any NotificationSource] = []
    private var ledger: DeliveryLedger
    /// Ids currently being delivered — claimed synchronously before any `await`, so two concurrent
    /// `deliver` calls for the same id can't both pass the settled check and double-deliver.
    private var inFlight: Set<NotificationID> = []
    private let runtime: any NotificationRuntime
    /// Flushes the ledger snapshot to disk after each settle. Nil = in-memory only (tests, or a
    /// launch whose ledger file could not be read and must not be overwritten).
    private let persistLedger: (@Sendable ([NotificationID: DeliveryStatus]) async throws -> Void)?
    /// Told when a save fails, once per failure streak per store (a failing disk fails every flush;
    /// repeating the report would bury it). A later success ends the streak.
    private var onPersistenceFailure: (@Sendable (NotificationPersistenceFailure) -> Void)?
    /// Told how every notification finally ended, with a reason the producer can show. Called
    /// synchronously in the settling actor step; it must only enqueue.
    private var onSettled: (@Sendable (AgentNotification, NotificationSettlement) -> Void)?
    /// Push deliveries a target asked to retry: attempts so far. Cleared when the id settles.
    private var pushRetryAttempts: [NotificationID: Int] = [:]
    /// The notification each pending push retry will deliver, so it can be withdrawn.
    private var pushRetryNotifications: [NotificationID: AgentNotification] = [:]
    /// Withdrawals asked for while the id was mid-delivery: honored the moment that attempt comes
    /// back unsettled (a retry is due), so a cancelled push is never retried into delivery.
    private var withdrawalsPending: [NotificationID: String] = [:]
    /// Push attempts before a `.retryable` delivery is settled as refused (decision R3).
    static let maxPushAttempts = 5
    private var failingStores: Set<PersistedStore> = []

    private enum PersistedStore: Hashable {
        case ledger
        case pendingDelivery
    }
    /// Single-flight coalescing for `persistLedger` — see `flushLedger`. Only one write is in
    /// flight at a time; concurrent settles set `ledgerDirty` and the flusher re-snapshots.
    private var ledgerFlushInFlight = false
    private var ledgerDirty = false

    /// Recipient kinds that PULL rather than push: a `.deliver` for one of these is held in
    /// `pendingDelivery` until the recipient calls `drainPendingDeliveries`. Smith is the canonical
    /// pull recipient — his run loop drains his queue — so a fired notification is never pushed into
    /// him (no reentrancy) and survives his momentary absence (persistence until delivery).
    private var pullRecipients: Set<RecipientKind> = []
    /// `.deliver` notifications queued for a pull recipient, held until drained. THIS is the durable
    /// outbox — persisted via `persistPendingDelivery`, so an undelivered notification survives a
    /// restart and is handed out on the next drain rather than lost.
    private var pendingDelivery: [QueuedDelivery] = []
    /// Per-recipient LEASE: ids handed out but not yet acknowledged. They stay in `pendingDelivery`
    /// (durable) until the recipient acknowledges them (`acknowledgeDeliveries`), and are not handed
    /// out again meanwhile. A crash before the acknowledgement leaves them in the outbox, so a restart
    /// re-delivers them (never a lost reminder). In-memory only: on restart the lease is empty and the
    /// still-present outbox items are re-delivered, which is exactly the intended recovery.
    private var leased: [RecipientKind: Set<NotificationID>] = [:]
    /// Bumped by every `resetLease`, so an acknowledgement from a torn-down recipient (carrying the
    /// OLD generation) can't remove an item its successor has been re-handed and not yet acted on.
    private var leaseGeneration: [RecipientKind: Int] = [:]
    /// Durable outbox writer. Unlike the ledger's single-flight flush (whose fast-path returns
    /// BEFORE the write lands — fine for a dedup ledger), pending-delivery is the reminder-durability
    /// FLOOR: `SerialPersistenceWriter.flush()` parks the caller until its snapshot has actually been
    /// written, so an enqueue is durable BEFORE the nudge fires and before the scheduler removes the
    /// wake. Nil = in-memory only (tests).
    private let pendingWriter: SerialPersistenceWriter<[QueuedDelivery]>?
    /// Fired (best-effort) when something is enqueued for a pull recipient, so an idle recipient can
    /// wake and drain instead of waiting for its next scheduled tick.
    private var onPendingEnqueued: (@Sendable (RecipientKind) -> Void)?

    private static let logger = Logger(subsystem: "com.agentsmith", category: "Notifications")

    public init(
        runtime: any NotificationRuntime,
        ledgerCapacity: Int = 5_000,
        persistLedger: (@Sendable ([NotificationID: DeliveryStatus]) async throws -> Void)? = nil,
        persistPendingDelivery: (@Sendable ([QueuedDelivery]) async throws -> Void)? = nil
    ) {
        self.runtime = runtime
        self.ledger = DeliveryLedger(capacity: ledgerCapacity)
        self.persistLedger = persistLedger
        self.pendingWriter = persistPendingDelivery.map { persist in
            SerialPersistenceWriter(label: "notification.pending", write: { snapshot in try await persist(snapshot) })
        }
    }

    /// Wire the settlement report (see `onSettled`).
    public func setOnSettled(_ handler: @escaping @Sendable (AgentNotification, NotificationSettlement) -> Void) {
        onSettled = handler
    }

    /// The first-party notification types with no registered handler. Must be empty once the
    /// runtime has registered its handlers: a type with no handler is dropped on arrival.
    public func typesMissingHandlers(_ types: [String]) -> [String] {
        types.filter { handlers[$0] == nil }
    }

    /// Wire the save-failure report (see `onPersistenceFailure`).
    public func setOnPersistenceFailure(_ handler: @escaping @Sendable (NotificationPersistenceFailure) -> Void) {
        onPersistenceFailure = handler
    }

    /// Records a save outcome for `store`, reporting the first failure of a streak.
    private func recordSaveOutcome(_ store: PersistedStore, failure: String?) {
        guard let failure else {
            failingStores.remove(store)
            return
        }
        guard failingStores.insert(store).inserted else { return }
        let reported: NotificationPersistenceFailure.Store = switch store {
        case .ledger: .deliveryLedger
        case .pendingDelivery: .pendingDelivery
        }
        onPersistenceFailure?(NotificationPersistenceFailure(store: reported, operation: .save, reason: failure))
    }

    // MARK: - Registration

    /// Register the handler for a payload `type`. Keyed on the raw String — the broker stays
    /// payload-agnostic, so a new type needs no broker change. Last registration wins.
    ///
    /// INTEGRATION RULE: register EVERY first-party handler and recipient target BEFORE any source
    /// produces (before the first `tick`, `post`, or `seedLedger`-then-drain). A notification whose
    /// type has no handler is settled `.dropped(noHandler)` and never retried — so a valid
    /// notification racing an unregistered handler at startup would be permanently lost.
    public func registerHandler(type: String, _ handler: any NotificationHandler) {
        handlers[type] = handler
    }

    /// Register where `.deliver` text lands for a recipient kind (PUSH delivery — an outward bridge).
    public func registerRecipientTarget(_ kind: RecipientKind, _ target: any RecipientTarget) {
        targets[kind] = target
    }

    /// Register a recipient kind as PULL: a `.deliver` for it is queued (and persisted) until the
    /// recipient calls `drainPendingDeliveries`. Use for in-process recipients that drain on their
    /// own loop (Smith), so nothing is pushed into them and nothing is lost to a transient absence.
    public func registerPullRecipient(_ kind: RecipientKind) {
        pullRecipients.insert(kind)
    }

    /// Wire the idle-wake nudge for pull recipients (see `onPendingEnqueued`).
    public func setOnPendingEnqueued(_ handler: @escaping @Sendable (RecipientKind) -> Void) {
        onPendingEnqueued = handler
    }

    /// Drops a pull recipient's outstanding lease and returns the new lease generation. MUST be
    /// called whenever that recipient is re-created (e.g. Smith re-spawned) — the broker outlives the
    /// recipient, but a lease belongs to the recipient that was handed the items. Clearing it makes
    /// the new recipient re-deliver whatever the old one never acknowledged. The new recipient passes
    /// the returned generation with its acknowledgements.
    @discardableResult
    public func resetLease(for kind: RecipientKind) -> Int {
        leased[kind] = nil
        let generation = (leaseGeneration[kind] ?? 0) + 1
        leaseGeneration[kind] = generation
        return generation
    }

    /// Seed the pending-delivery queue from persisted state at cold boot, so notifications that were
    /// queued-but-not-yet-drained before a restart are handed out on the next drain. Skips ids the
    /// ledger already records as delivered (a drain that raced the crash).
    public func seedPendingDeliveries(_ items: [QueuedDelivery]) {
        for item in items
        where !ledger.isSettled(item.notification.id)
            && !pendingDelivery.contains(where: { $0.notification.id == item.notification.id }) {
            pendingDelivery.append(item)
        }
    }

    /// Register a pollable source (drained on `tick` and at cold boot).
    public func registerSource(_ source: any NotificationSource) {
        sources.append(source)
    }

    /// A handle for event-driven posting (inbound message, webhook).
    public func makeSourceHandle() -> SourceHandle {
        SourceHandle(broker: self)
    }

    /// Subscribe an observer. Fan-out, never affects delivery.
    @discardableResult
    public func observe(where filter: NotificationFilter, _ sink: @escaping @Sendable (AgentNotification) async -> Void) -> ObserverToken {
        let token = ObserverToken(id: UUID())
        observers[token] = (filter, sink)
        return token
    }

    public func removeObserver(_ token: ObserverToken) {
        observers[token] = nil
    }

    /// Seed the delivered-set from persisted state so a re-fire after restart is recognized.
    public func seedLedger(_ persisted: [NotificationID: DeliveryStatus]) {
        ledger.seed(persisted)
    }

    // MARK: - Producing

    /// Build a notification (deterministic id) and deliver it.
    @discardableResult
    public func post(
        triggerSource: TriggerSource,
        recipient: Recipient,
        payload: Payload,
        title: String,
        idempotencyKey: String,
        expiresAt: Date? = nil
    ) async -> NotificationID {
        let id = NotificationID(namespace: triggerSource.namespace, key: idempotencyKey)
        let notification = AgentNotification(
            id: id,
            triggerSource: triggerSource,
            recipient: recipient,
            title: title,
            createdAt: Date(),
            expiresAt: expiresAt,
            payload: payload
        )
        await deliver(notification)
        return id
    }

    /// Submit a pre-built notification (e.g. one produced from a fired wake by
    /// `WakeNotificationFactory`, whose deterministic id makes it dedup-safe). Dedups + routes it.
    ///
    /// Returns whether the broker now OWNS the notification durably — it is settled in the ledger,
    /// or durably queued for its pull recipient. `false` means the producer must keep its own record
    /// and submit again later: the pull queue could not be saved, a push is waiting on a retry, or
    /// the same id is mid-delivery. Resubmitting is always safe (the id dedups).
    @discardableResult
    public func submit(_ notification: AgentNotification) async -> Bool {
        await deliver(notification)
    }

    /// Drain every registered pollable source and deliver what's ready. Called on a timer tick and
    /// at cold boot.
    public func tick(now: Date = Date()) async {
        for source in sources {
            for notification in await source.drainReady(now: now) {
                await deliver(notification)
            }
        }
    }

    /// Takes back notifications that have not reached their recipient: queued for a pull recipient
    /// but not yet handed out, or waiting on a push retry. Each is settled `.dropped(.withdrawn)`.
    /// One already handed to its recipient, or mid-delivery, cannot be recalled and is left alone.
    /// Returns the ids actually withdrawn.
    @discardableResult
    public func withdraw(_ ids: [NotificationID], reason: String) async -> [NotificationID] {
        // Claim EVERY eligible id before the first suspension: settling awaits a ledger write, and a
        // later id in the batch must not be leased to Smith or enter push delivery meanwhile.
        var claimed: [AgentNotification] = []
        for id in ids where !ledger.isSettled(id) {
            if inFlight.contains(id) {
                withdrawalsPending[id] = reason
                continue
            }
            let leasedNow = leased.values.contains { $0.contains(id) }
            if let queued = pendingDelivery.first(where: { $0.notification.id == id }), !leasedNow {
                pendingDelivery.removeAll { $0.notification.id == id }
                claimed.append(queued.notification)
            } else if let notification = pushRetryNotifications[id], pushRetryAttempts[id] != nil {
                // Clearing the retry state now stops the scheduled retry (it checks for it).
                pushRetryAttempts[id] = nil
                pushRetryNotifications[id] = nil
                claimed.append(notification)
            }
        }
        for notification in claimed {
            await settle(notification, .dropped(reason: .withdrawn), reason: reason)
        }
        if !claimed.isEmpty { await flushPendingDelivery() }
        return claimed.map(\.id)
    }

    /// Whether the broker is still holding `id` — queued for a pull recipient, being delivered, or
    /// waiting on a push retry.
    public func isHoldingForDelivery(_ id: NotificationID) -> Bool {
        inFlight.contains(id) || pushRetryAttempts[id] != nil || pendingDelivery.contains { $0.notification.id == id }
    }

    public func deliveryStatus(_ id: NotificationID) -> DeliveryStatus {
        ledger.status(id)
    }

    // MARK: - Core routing

    /// The one path every notification flows through. Dedups on id, fans out to observers, then
    /// routes to the type handler and (for `.deliver`) the recipient target.
    ///
    /// Returns whether the broker durably owns it afterwards (see `submit`). `isPushRetry` is set
    /// only by the broker's own push-retry timer, which is the one caller allowed past the
    /// waiting-on-retry check.
    @discardableResult
    private func deliver(_ notification: AgentNotification, isPushRetry: Bool = false) async -> Bool {
        let id = notification.id
        // Claim synchronously — before any await — so a concurrent duplicate can't also pass. A
        // notification already queued for a pull recipient is also a duplicate (don't re-enqueue),
        // but its queue save may have failed: try again, and report whether it is durable now.
        if ledger.isSettled(id) { return true }
        if inFlight.contains(id) { return false }
        if !isPushRetry, pushRetryAttempts[id] != nil { return false }
        if pendingDelivery.contains(where: { $0.notification.id == id }) {
            return await flushPendingDelivery()
        }
        inFlight.insert(id)
        defer { inFlight.remove(id) }

        // Observers see every non-duplicate notification, whatever its fate — but NEVER gate the
        // effectful path. Each matching sink runs in its own detached task, so a slow or stalled
        // observer (UI, metrics, audit) cannot block the handler, hold the id in-flight, or let a
        // notification sit until it expires. Observers are best-effort by contract.
        for (_, observer) in observers where observer.filter.matches(notification) {
            let sink = observer.sink
            Task { await sink(notification) }
        }

        let now = Date()
        if let expiresAt = notification.expiresAt, expiresAt <= now {
            await settle(notification, .dropped(reason: .expired), reason: "it expired before it could be delivered")
            return true
        }

        guard let handler = handlers[notification.payload.type] else {
            // Unknown type: not an error. Persisted + observed, never acted on. Forward-compat.
            await settle(notification, .dropped(reason: .noHandler), reason: "nothing handles notifications of type '\(notification.payload.type)'")
            return true
        }

        var owned = true
        do {
            switch try await handler.handle(notification, runtime: runtime) {
            case .acted:
                await settle(notification, .delivered(now), reason: nil)
            case .refused(let reason):
                // A legitimate "couldn't do it", not a bug: settle it so nothing retries a spent
                // one-shot, but as DROPPED — recording a refused effect as `.delivered` is what let
                // a silently-discarded scheduled run look like a success in the ledger. The reason
                // reaches the producer through `onSettled`.
                Self.logger.error("Notification handler for '\(notification.payload.type, privacy: .public)' refused: \(reason, privacy: .public)")
                await settle(notification, .dropped(reason: .runtimeRefused), reason: reason)
            case .deliver(let text):
                let kind = notification.recipient.kind
                if let target = targets[kind] {
                    owned = await push(text, for: notification, to: target, now: now)
                } else if pullRecipients.contains(kind) {
                    // PULL recipient: hold it in the durable pending queue until the recipient
                    // acknowledges it. NOT settled here — it becomes `.delivered` on acknowledgement.
                    // This is the persistence-until-delivery floor; a momentarily-absent recipient
                    // loses nothing.
                    if let withdrawal = withdrawalsPending.removeValue(forKey: id) {
                        // Withdrawn while its handler ran: never queue it.
                        await settle(notification, .dropped(reason: .withdrawn), reason: withdrawal)
                    } else {
                        pendingDelivery.append(QueuedDelivery(notification: notification, text: text))
                        owned = await flushPendingDelivery()
                        onPendingEnqueued?(kind)
                    }
                } else {
                    Self.logger.error("No target or pull registration for recipient \(String(describing: kind), privacy: .public) — dropping notification \(id.description, privacy: .public).")
                    await settle(notification, .dropped(reason: .noRecipientTarget), reason: "nothing is set up to deliver to \(String(describing: kind))")
                }
            }
        } catch {
            // Malformed data for a type we own — surface loudly, do NOT mark delivered.
            Self.logger.error("Notification handler for '\(notification.payload.type, privacy: .public)' threw: \(String(describing: error), privacy: .public)")
            await settle(notification, .dropped(reason: .handlerError), reason: "its data was malformed: \(error)")
        }
        return owned
    }

    /// Hands `text` to a push target and settles by its answer. A `.retryable` answer is retried
    /// with backoff (1s, 2s, 4s, …) up to `maxPushAttempts`, then settled refused with the last
    /// reason — never left unsettled forever, never silently dropped.
    /// Returns whether it settled (false while a retry is pending).
    private func push(_ text: String, for notification: AgentNotification, to target: any RecipientTarget, now: Date) async -> Bool {
        switch await target.deliver(text, for: notification) {
        case .delivered:
            await settle(notification, .delivered(now), reason: nil)
            return true
        case .refused(let reason):
            await settle(notification, .dropped(reason: .recipientRefused), reason: reason)
            return true
        case .retryable(let reason):
            if let withdrawal = withdrawalsPending.removeValue(forKey: notification.id) {
                await settle(notification, .dropped(reason: .withdrawn), reason: withdrawal)
                return true
            }
            let attempts = (pushRetryAttempts[notification.id] ?? 0) + 1
            pushRetryAttempts[notification.id] = attempts
            pushRetryNotifications[notification.id] = notification
            guard attempts < Self.maxPushAttempts else {
                await settle(notification, .dropped(reason: .recipientRefused), reason: "delivery kept failing (\(reason))")
                return true
            }
            Self.logger.notice("Push delivery of \(notification.id.description, privacy: .public) will be retried (attempt \(attempts, privacy: .public)): \(reason, privacy: .public)")
            let delay = Duration.seconds(1 << (attempts - 1))
            Task { [weak self] in
                try? await Task.sleep(for: delay)
                await self?.retryDelivery(notification)
            }
            return false
        }
    }

    private func retryDelivery(_ notification: AgentNotification) async {
        // Withdrawn (or otherwise settled) while it waited: nothing to retry.
        guard pushRetryAttempts[notification.id] != nil else { return }
        await deliver(notification, isPushRetry: true)
    }

    private func settle(_ notification: AgentNotification, _ status: DeliveryStatus, reason: String?) async {
        let id = notification.id
        pushRetryAttempts[id] = nil
        pushRetryNotifications[id] = nil
        withdrawalsPending[id] = nil
        switch status {
        case .delivered(let date):
            ledger.markDelivered(id, at: date)
            onSettled?(notification, .delivered(date))
        case .dropped(let code):
            ledger.markDropped(id, reason: code)
            onSettled?(notification, .refused(reason: reason ?? code.rawValue))
        case .pending:
            return
        }
        await flushLedger()
    }

    /// Persists the ledger with a COALESCED single-flight: while one flush is awaiting the async
    /// write, concurrent settles just mark the ledger dirty; the in-flight flush loops and
    /// re-snapshots the CURRENT (latest) state. This prevents the reordering hazard of independent
    /// snapshot-then-await writes — where a slow write of an OLDER snapshot could land last and
    /// clobber a newer one on disk, resurrecting an already-delivered notification after restart.
    /// The last write is always the newest state, applied in order.
    private func flushLedger() async {
        guard let persistLedger else { return }
        guard !ledgerFlushInFlight else { ledgerDirty = true; return }
        ledgerFlushInFlight = true
        defer { ledgerFlushInFlight = false }
        repeat {
            ledgerDirty = false
            do {
                try await persistLedger(ledger.snapshot())
                recordSaveOutcome(.ledger, failure: nil)
            } catch {
                Self.logger.error("Notification ledger save failed: \(error.localizedDescription, privacy: .public)")
                recordSaveOutcome(.ledger, failure: error.localizedDescription)
            }
        } while ledgerDirty
    }

    // MARK: - Pull delivery (persistence until delivery)

    /// Hands the recipient the queued notifications it has not been handed yet, LEASING them: they
    /// stay in the durable outbox — and are not handed out again — until the recipient ACKNOWLEDGES
    /// them (`acknowledgeDeliveries`) once it has finished acting on them.
    ///
    /// A crash (or a recipient torn down) between the hand-out and the acknowledgement leaves them in
    /// the persisted outbox, so they are re-delivered to the next recipient (`resetLease`) or after a
    /// restart — never lost. Acknowledging only after the recipient has ACTED (not on its next drain,
    /// as this used to) shrinks the redelivery window to "crashed while acting on it": a note that was
    /// fully acted on is not handed out again.
    public func drainPendingDeliveries(for kind: RecipientKind) -> [QueuedDelivery] {
        let alreadyLeased = leased[kind] ?? []
        let batch = pendingDelivery.filter { $0.notification.recipient.kind == kind && !alreadyLeased.contains($0.notification.id) }
        if !batch.isEmpty {
            leased[kind, default: []].formUnion(batch.map(\.notification.id))
        }
        return batch
    }

    /// The recipient has finished acting on these deliveries: remove them from the durable outbox and
    /// record them delivered. `leaseGeneration` is the value `resetLease` returned when this recipient
    /// was wired; an acknowledgement from an older generation (a torn-down recipient) is ignored, as
    /// are ids not currently leased.
    public func acknowledgeDeliveries(_ ids: [NotificationID], for kind: RecipientKind, leaseGeneration generation: Int) async {
        guard generation == (leaseGeneration[kind] ?? 0) else { return }
        let acknowledged = Set(ids).intersection(leased[kind] ?? [])
        guard !acknowledged.isEmpty else { return }
        let now = Date()
        let settled = pendingDelivery.filter { acknowledged.contains($0.notification.id) }
        pendingDelivery.removeAll { acknowledged.contains($0.notification.id) }
        for id in acknowledged { ledger.markDelivered(id, at: now) }
        for item in settled { onSettled?(item.notification, .delivered(now)) }
        leased[kind]?.subtract(acknowledged)
        await flushPendingDelivery()
        await flushLedger()
    }

    /// Durably persists the CURRENT pending-delivery queue and does not return until that snapshot
    /// (or a later one that supersedes it) has been written. The `SerialPersistenceWriter` coalesces
    /// bursts and preserves write order like the ledger flusher, but — critically — its `flush()`
    /// waits on a sequence watermark, so a caller can't proceed (nudge / remove the source wake)
    /// before its enqueue is on disk.
    ///
    /// A failed write is reported (the writer has logged it); the queue is still intact in memory,
    /// so delivery this launch is unaffected — only a restart before the next successful save can
    /// lose it, which is exactly what the report tells the user.
    /// Returns whether the queue is on disk (true when there is no disk: memory is the storage).
    @discardableResult
    private func flushPendingDelivery() async -> Bool {
        guard let pendingWriter else { return true }
        await pendingWriter.enqueue(pendingDelivery)
        let durable = await pendingWriter.flush()
        recordSaveOutcome(.pendingDelivery, failure: durable ? nil : "the write to disk failed")
        return durable
    }
}
