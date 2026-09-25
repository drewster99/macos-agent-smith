import Foundation

/// Where a `.deliver(text)` outcome lands. Registered by `RecipientKind` (one target per kind);
/// the specific recipient (e.g. which task's worker) rides on the notification passed to `deliver`.
///
/// A new destination — Smith's conversation, a task worker, an outward iMessage/Slack bridge — is
/// a new `RecipientTarget`, added without touching any handler.
public protocol RecipientTarget: Sendable {
    /// Deliver `text` for `notification`, reporting what happened. `.retryable` asks the broker to
    /// try again later (a bounded number of times); `.refused` is final and its reason reaches
    /// whoever produced the notification.
    func deliver(_ text: String, for notification: AgentNotification) async -> PushDeliveryOutcome
}

/// What a push target did with a delivery.
public enum PushDeliveryOutcome: Sendable, Equatable {
    /// The text reached the recipient, or was durably queued for it.
    case delivered
    /// It can't be delivered, and trying again won't help (e.g. notifications are not permitted).
    case refused(String)
    /// It couldn't be delivered right now; the broker retries with backoff.
    case retryable(String)
}

/// How a notification finally ended, reported to the broker's settlement observer with a reason
/// the producer can show — the ledger keeps only a coarse code.
public enum NotificationSettlement: Sendable, Equatable {
    case delivered(Date)
    case refused(reason: String)
}
