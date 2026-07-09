import Foundation

/// A user message captured while Smith could not accept it (agents stopped, or mid-startup
/// during the "Preparing task — starting MCP servers…" window), held in
/// `OrchestrationRuntime.pendingUserMessages` and delivered by `drainPendingUserMessages()`
/// once Smith is running.
///
/// Persisted per-session so a message typed during a slow startup survives an app quit or
/// crash before it is delivered. `attachments` are stored with their bytes stripped
/// (`data == nil`); the bytes live in the per-session attachment store on disk and are
/// lazy-loaded through `AttachmentRegistry` at delivery time. `channelMessageID` is the id of
/// the UI-echo `ChannelMessage` posted at enqueue time — reusing it at delivery keeps the
/// consumer idempotent across a redelivery (Smith dedupes by `ChannelMessage.id`).
public struct PendingUserMessage: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let channelMessageID: UUID
    public let text: String
    public let attachments: [Attachment]
    public let receivedAt: Date

    public init(
        id: UUID = UUID(),
        channelMessageID: UUID = UUID(),
        text: String,
        attachments: [Attachment],
        receivedAt: Date
    ) {
        self.id = id
        self.channelMessageID = channelMessageID
        self.text = text
        // Strip bytes — they live on disk and are lazy-loaded at delivery. Keeping them here
        // would bloat the persisted queue and duplicate the on-disk attachment store.
        self.attachments = attachments.map { attachment in
            var stripped = attachment
            stripped.data = nil
            return stripped
        }
        self.receivedAt = receivedAt
    }
}
