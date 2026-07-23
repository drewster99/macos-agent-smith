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

    private static let logger = Logger(subsystem: "com.agentsmith", category: "Notifications")

    public init(
        runtime: any NotificationRuntime,
        ledgerCapacity: Int = 5_000,
        persistLedger: (@Sendable ([NotificationID: DeliveryStatus]) async -> Void)? = nil
    ) {
        self.runtime = runtime
        self.ledger = DeliveryLedger(capacity: ledgerCapacity)
        self.persistLedger = persistLedger
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

    /// Register where `.deliver` text lands for a recipient kind.
    public func registerRecipientTarget(_ kind: RecipientKind, _ target: any RecipientTarget) {
        targets[kind] = target
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
        // Claim synchronously — before any await — so a concurrent duplicate can't also pass.
        guard !ledger.isSettled(id), !inFlight.contains(id) else { return }
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
                guard let target = targets[notification.recipient.kind] else {
                    await settle(id, .dropped(reason: .noRecipientTarget))
                    return
                }
                if await target.deliver(text, for: notification) {
                    await settle(id, .delivered(now))
                }
                // A false return leaves the id UNSETTLED. Note: there is no durable pending
                // outbox yet (that lands with the persistence phase), so nothing re-produces an
                // unsettled notification on its own — a target that needs guaranteed delivery must
                // durably QUEUE the work and return true (e.g. the `.taskWorker` route queues on
                // the task for its next spawn). Returning false today means "not delivered, not
                // queued" — the occurrence is effectively lost until its source produces it again.
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
}
