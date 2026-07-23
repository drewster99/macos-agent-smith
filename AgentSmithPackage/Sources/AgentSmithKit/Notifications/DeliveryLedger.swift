import Foundation

/// The delivery outcome for a notification id, for `deliveryStatus` queries and audit.
public enum DeliveryStatus: Sendable, Codable, Equatable {
    case pending
    case delivered(Date)
    case dropped(reason: DropReason)

    public enum DropReason: String, Sendable, Codable {
        case expired            // past `expiresAt` before delivery
        case noHandler          // unknown type — no registered handler (safe no-op)
        case noRecipientTarget  // `.deliver` outcome but no target registered for the recipient kind
        case handlerError       // malformed data for a type we own
    }
}

/// The effectively-once floor: a bounded, persistable record of which notification ids have already
/// been delivered (or dropped). Applied UNIFORMLY to every notification — one rule, no per-type
/// carve-out. Keyed on the deterministic `NotificationID`, so a crash-gap re-post collides here.
///
/// Owned and mutated inside `NotificationBroker`'s actor isolation (not itself an actor); a
/// persistence hook lets the broker flush changes to disk without this type importing the
/// persistence layer.
public struct DeliveryLedger: Sendable {
    private var statuses: [NotificationID: DeliveryStatus] = [:]
    /// Insertion order for age-based pruning (oldest first).
    private var order: [NotificationID] = []
    private let capacity: Int

    public init(capacity: Int = 5_000) {
        self.capacity = capacity
    }

    /// Seed from persisted state at cold boot so a re-fire after restart is still recognized.
    public mutating func seed(_ persisted: [NotificationID: DeliveryStatus]) {
        for (id, status) in persisted where statuses[id] == nil {
            statuses[id] = status
            order.append(id)
        }
        prune()
    }

    /// A settled id (delivered or dropped) must not be delivered again. `pending` and absent both
    /// mean "not yet settled — deliver it".
    public func isSettled(_ id: NotificationID) -> Bool {
        switch statuses[id] {
        case .delivered, .dropped: return true
        case .pending, nil: return false
        }
    }

    public func status(_ id: NotificationID) -> DeliveryStatus {
        statuses[id] ?? .pending
    }

    public mutating func markDelivered(_ id: NotificationID, at date: Date) {
        record(id, .delivered(date))
    }

    public mutating func markDropped(_ id: NotificationID, reason: DeliveryStatus.DropReason) {
        record(id, .dropped(reason: reason))
    }

    /// A snapshot for persistence.
    public func snapshot() -> [NotificationID: DeliveryStatus] {
        statuses
    }

    private mutating func record(_ id: NotificationID, _ status: DeliveryStatus) {
        if statuses[id] == nil { order.append(id) }
        statuses[id] = status
        prune()
    }

    /// Bounded by count (oldest-first). Age-based pruning against the largest recurrence period is
    /// a follow-up; the count bound is the safety floor so the set can't grow without limit.
    private mutating func prune() {
        guard order.count > capacity else { return }
        let dropCount = order.count - capacity
        for id in order.prefix(dropCount) { statuses[id] = nil }
        order.removeFirst(dropCount)
    }
}
