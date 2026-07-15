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
    /// True once Smith has folded this message into its LLM context. The message is then kept as a
    /// durable TOMBSTONE (not deleted) so lost-message recovery can tell "incorporated/handled" apart
    /// from "never enqueued/lost" — the exact ambiguity that previously caused both duplicate
    /// re-delivery and silent loss. The drain skips incorporated messages; old tombstones are pruned.
    public var incorporated: Bool

    public init(
        id: UUID = UUID(),
        channelMessageID: UUID = UUID(),
        text: String,
        attachments: [Attachment],
        receivedAt: Date,
        incorporated: Bool = false
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
        self.incorporated = incorporated
    }

    private enum CodingKeys: String, CodingKey {
        case id, channelMessageID, text, attachments, receivedAt, incorporated
    }

    /// Custom decode so `incorporated` defaults to `false` for buffers written by an older build (a
    /// missing key must not fail the whole load), and so decoded attachments are taken AS-IS (already
    /// byte-stripped on disk) rather than re-run through the memberwise init's stripping.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        channelMessageID = try c.decode(UUID.self, forKey: .channelMessageID)
        text = try c.decode(String.self, forKey: .text)
        attachments = try c.decode([Attachment].self, forKey: .attachments)
        receivedAt = try c.decode(Date.self, forKey: .receivedAt)
        incorporated = try c.decodeIfPresent(Bool.self, forKey: .incorporated) ?? false
    }
}
