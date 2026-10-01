import Foundation

/// A notification store that could not be loaded or saved. Reported by the broker (saves) and the
/// runtime (loads) so the failure reaches the user instead of only the log.
public struct NotificationPersistenceFailure: Sendable, Equatable {
    public enum Store: Sendable, Equatable {
        /// The delivered/dropped record that dedups a notification across restarts.
        case deliveryLedger
        /// The durable outbox of notifications queued for Smith.
        case pendingDelivery
    }

    public enum Operation: Sendable, Equatable {
        case load
        case save
    }

    public let store: Store
    public let operation: Operation
    public let reason: String

    public init(store: Store, operation: Operation, reason: String) {
        self.store = store
        self.operation = operation
        self.reason = reason
    }

    /// What the user is told, including what the failure costs them.
    public var userFacingDescription: String {
        switch (store, operation) {
        case (.deliveryLedger, .save):
            return "Couldn't save the notification delivery record (\(reason)). If the app restarts before a later save succeeds, a notification that was already delivered may be delivered again."
        case (.pendingDelivery, .save):
            return "Couldn't save the queue of notifications waiting for Smith (\(reason)). If the app restarts before a later save succeeds, a notification Smith hasn't read yet may be lost."
        case (.deliveryLedger, .load):
            return "Couldn't read the notification delivery record (\(reason)). It is left untouched on disk and this launch keeps it in memory only, so a notification delivered before the restart may be delivered again."
        case (.pendingDelivery, .load):
            return "Couldn't read the queue of notifications waiting for Smith (\(reason)). It is left untouched on disk and this launch keeps the queue in memory only, so notifications queued before the restart won't be delivered this launch."
        }
    }
}
