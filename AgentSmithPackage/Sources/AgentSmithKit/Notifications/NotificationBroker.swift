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
    /// Flushes the ledger snapshot to disk after each settle. Nil = in-memory only (tests).
    private let persistLedger: (@Sendable ([NotificationID: DeliveryStatus]) async -> Void)?
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
    /// Per-recipient LEASE: ids handed out on the recipient's LAST drain but not yet acked. They stay
    /// in `pendingDelivery` (durable) until the recipient's NEXT drain confirms it came back around
    /// and consumed them — the ack. This is what makes pull delivery at-LEAST-once: a crash after a
    /// drain but before the acking next-drain leaves the items in the outbox, so a restart re-delivers
    /// them (never a lost reminder). In-memory only: on restart the lease is empty and the still-
    /// present outbox items are re-delivered, which is exactly the intended recovery.
    private var leased: [RecipientKind: Set<NotificationID>] = [:]
    /// Durable outbox writer. Unlike the ledger's single-flight flush (whose fast-path returns
    /// BEFORE the write lands — fine for a dedup ledger), pending-delivery is the reminder-durability
    /// FLOOR: `SerialPersistenceWriter.flush()` parks the caller until its snapshot has actually been
    /// written, so an enqueue is durable BEFORE the nudge fires and before the scheduler removes the
    /// wake. Nil = in-memory only (tests).
    private let pendingWriter: SerialPersistenceWriter<[QueuedDelivery]>?
    /// Fired (best-effort) when something is enqueued for a pull recipient, so an idle recipient can
    /// wake and drain instead of waiting for its next scheduled tick.
    private var onPendingEnqueued: (@Sendable (RecipientKind) -> Void)?
    /// Recipient kinds with a drain in flight. `drainPendingDeliveries` awaits a disk flush, leaving
    /// the actor open; a SECOND concurrent drain for the same kind would ack the batch the first has
    /// leased-but-not-yet-returned, silently breaking at-least-once. Today the sole caller (Smith's
    /// single run loop) can't overlap, but this makes the public method safe by construction.
    private var draining: Set<RecipientKind> = []

    private static let logger = Logger(subsystem: "com.agentsmith", category: "Notifications")

    public init(
        runtime: any NotificationRuntime,
        ledgerCapacity: Int = 5_000,
        persistLedger: (@Sendable ([NotificationID: DeliveryStatus]) async -> Void)? = nil,
        persistPendingDelivery: (@Sendable ([QueuedDelivery]) async -> Void)? = nil
    ) {
        self.runtime = runtime
        self.ledger = DeliveryLedger(capacity: ledgerCapacity)
        self.persistLedger = persistLedger
        self.pendingWriter = persistPendingDelivery.map { persist in
            SerialPersistenceWriter(label: "notification.pending", write: { snapshot in await persist(snapshot) })
        }
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

    /// Drops a pull recipient's outstanding lease. MUST be called whenever that recipient is
    /// re-created (e.g. Smith re-spawned by `restartForNewTask`) — the broker (and this in-memory
    /// lease) is memoized and outlives the recipient, but the lease's ack semantics are tied to the
    /// RECIPIENT's lifetime, not the broker's. Without this, a fresh recipient's first drain would
    /// ack away the PRIOR recipient's still-undelivered batch (remove it from the outbox + mark it
    /// delivered) and lose it. Clearing the lease makes the new recipient re-deliver the outbox
    /// instead — the intended at-least-once recovery.
    public func resetLease(for kind: RecipientKind) {
        leased[kind] = nil
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
    public func submit(_ notification: AgentNotification) async {
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

    public func deliveryStatus(_ id: NotificationID) -> DeliveryStatus {
        ledger.status(id)
    }

    // MARK: - Core routing

    /// The one path every notification flows through. Dedups on id, fans out to observers, then
    /// routes to the type handler and (for `.deliver`) the recipient target.
    private func deliver(_ notification: AgentNotification) async {
        let id = notification.id
        // Claim synchronously — before any await — so a concurrent duplicate can't also pass. A
        // notification already queued for a pull recipient is also a duplicate (don't re-enqueue).
        guard !ledger.isSettled(id), !inFlight.contains(id),
              !pendingDelivery.contains(where: { $0.notification.id == id }) else { return }
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
            await settle(id, .dropped(reason: .expired))
            return
        }

        guard let handler = handlers[notification.payload.type] else {
            // Unknown type: not an error. Persisted + observed, never acted on. Forward-compat.
            await settle(id, .dropped(reason: .noHandler))
            return
        }

        do {
            switch try await handler.handle(notification, runtime: runtime) {
            case .acted:
                await settle(id, .delivered(now))
            case .deliver(let text):
                let kind = notification.recipient.kind
                if let target = targets[kind] {
                    // PUSH recipient (outward bridge). A false return leaves the id unsettled; log
                    // it so a lost commitment is visible rather than silent.
                    if await target.deliver(text, for: notification) {
                        await settle(id, .delivered(now))
                    } else {
                        Self.logger.error("Push delivery for recipient \(String(describing: kind), privacy: .public) returned false — notification \(id.description, privacy: .public) left unsettled.")
                    }
                } else if pullRecipients.contains(kind) {
                    // PULL recipient: hold it in the durable pending queue until the recipient
                    // drains. NOT settled here — it becomes `.delivered` on drain. This is the
                    // persistence-until-delivery floor; a momentarily-absent recipient loses nothing.
                    pendingDelivery.append(QueuedDelivery(notification: notification, text: text))
                    await flushPendingDelivery()
                    onPendingEnqueued?(kind)
                } else {
                    Self.logger.error("No target or pull registration for recipient \(String(describing: kind), privacy: .public) — dropping notification \(id.description, privacy: .public).")
                    await settle(id, .dropped(reason: .noRecipientTarget))
                }
            }
        } catch {
            // Malformed data for a type we own — surface loudly, do NOT mark delivered.
            Self.logger.error("Notification handler for '\(notification.payload.type, privacy: .public)' threw: \(String(describing: error), privacy: .public)")
            await settle(id, .dropped(reason: .handlerError))
        }
    }

    private func settle(_ id: NotificationID, _ status: DeliveryStatus) async {
        switch status {
        case .delivered(let date): ledger.markDelivered(id, at: date)
        case .dropped(let reason): ledger.markDropped(id, reason: reason)
        case .pending: return
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
            await persistLedger(ledger.snapshot())
        } while ledgerDirty
    }

    // MARK: - Pull delivery (persistence until delivery)

    /// Hands the recipient its queued notifications with AT-LEAST-ONCE durability, via lease/ack:
    ///
    ///   1. ACK the previous lease — the ids handed out on the LAST drain. The recipient has come
    ///      back around to this drain, so it consumed them: remove from the durable outbox and mark
    ///      them `.delivered`. This is the acknowledgement.
    ///   2. LEASE and return the current batch — hand it to the recipient but KEEP it in the outbox
    ///      until the NEXT drain acks it.
    ///
    /// So a crash after a drain but before the acking next-drain leaves the batch in the persisted
    /// outbox → a restart re-delivers it (never a lost reminder). The cost is at-least-once: a kill
    /// between the recipient processing a batch and its next drain can re-deliver that batch once.
    /// The `pendingDelivery.contains` guard in `deliver` prevents a leased id from being re-enqueued
    /// while it's outstanding.
    public func drainPendingDeliveries(for kind: RecipientKind) async -> [QueuedDelivery] {
        // Enforce one in-flight drain per kind (the method awaits flushes mid-body, opening the
        // actor): a concurrent same-kind drain returns empty rather than acking the other's batch.
        guard !draining.contains(kind) else { return [] }
        draining.insert(kind)
        defer { draining.remove(kind) }

        let now = Date()
        var acked = false
        if let previous = leased[kind], !previous.isEmpty {
            pendingDelivery.removeAll { previous.contains($0.notification.id) }
            for id in previous { ledger.markDelivered(id, at: now) }
            leased[kind] = nil
            acked = true
        }

        let batch = pendingDelivery.filter { $0.notification.recipient.kind == kind }
        if !batch.isEmpty {
            leased[kind] = Set(batch.map(\.notification.id))
        }
        // Persist only when the ack actually removed items — the lease itself is in-memory (a
        // restart re-delivers, which is the point).
        if acked {
            await flushPendingDelivery()
            await flushLedger()
        }
        return batch
    }

    /// Durably persists the CURRENT pending-delivery queue and does not return until that snapshot
    /// (or a later one that supersedes it) has been written. The `SerialPersistenceWriter` coalesces
    /// bursts and preserves write order like the ledger flusher, but — critically — its `flush()`
    /// waits on a sequence watermark, so a caller can't proceed (nudge / remove the source wake)
    /// before its enqueue is on disk.
    private func flushPendingDelivery() async {
        guard let pendingWriter else { return }
        await pendingWriter.enqueue(pendingDelivery)
        await pendingWriter.flush()
    }
}
