import Foundation

/// Where a `.deliver(text)` outcome lands. Registered by `RecipientKind` (one target per kind);
/// the specific recipient (e.g. which task's worker) rides on the notification passed to `deliver`.
///
/// A new destination — Smith's conversation, a task worker, an outward iMessage/Slack bridge — is
/// a new `RecipientTarget`, added without touching any handler.
public protocol RecipientTarget: Sendable {
    /// Deliver `text` for `notification`. Return true once the text has reached the recipient OR
    /// been durably queued for it (the ledger then marks the notification delivered). Return false
    /// only for an unrecoverable failure — but note there is no durable retry outbox yet, so a
    /// false return effectively drops the occurrence until its source re-produces it. A target
    /// that wants guaranteed delivery to a not-currently-alive recipient (e.g. `.taskWorker`)
    /// should queue the work durably and return true, NOT return false.
    func deliver(_ text: String, for notification: AgentNotification) async -> Bool
}
