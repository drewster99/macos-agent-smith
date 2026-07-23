import Foundation

/// A notification the broker is holding for a PULL recipient (e.g. Smith) until that recipient
/// drains it. This is the broker's "persistence until delivery" record: the notification manager
/// owns it, persists it, and hands it back on `drain` — so a recipient that is momentarily absent
/// (respawning) never loses a notification. Carries the handler-framed `text` so a drain needs no
/// re-render, and the full `notification` so the ledger id and recipient survive a restart.
public struct QueuedDelivery: Sendable, Codable, Equatable {
    public let notification: AgentNotification
    public let text: String

    public init(notification: AgentNotification, text: String) {
        self.notification = notification
        self.text = text
    }
}
