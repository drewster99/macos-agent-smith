import Foundation

/// Where a `.deliver(text)` outcome lands. Registered by `RecipientKind` (one target per kind);
/// the specific recipient (e.g. which task's worker) rides on the notification passed to `deliver`.
///
/// A new destination — Smith's conversation, a task worker, an outward iMessage/Slack bridge — is
/// a new `RecipientTarget`, added without touching any handler.
public protocol RecipientTarget: Sendable {
    /// Deliver `text` for `notification`. Return true when delivered (the ledger then marks it
    /// delivered); false to leave it pending for a later retry (e.g. the recipient worker is not
    /// currently alive and the notification was not queued).
    func deliver(_ text: String, for notification: AgentNotification) async -> Bool
}
