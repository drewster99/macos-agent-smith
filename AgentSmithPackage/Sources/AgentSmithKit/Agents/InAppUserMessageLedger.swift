import Foundation

/// One message the user typed into the app's own input field and Smith took into its conversation.
public struct InAppUserMessageRecord: Sendable, Equatable {
    /// The channel message id — the same id the transcript shows, so an audit note can be traced.
    public let messageID: UUID
    /// When the user sent it (the buffered message's receive time, not its delivery time).
    public let authoredAt: Date
    /// The opening of the message, for the audit note. Never parsed.
    public let excerpt: String

    public init(messageID: UUID, authoredAt: Date, excerpt: String) {
        self.messageID = messageID
        self.authoredAt = authoredAt
        self.excerpt = excerpt
    }
}

/// Which in-app user messages Smith has actually SEEN in its current stretch of activity — the
/// evidence `respond_to_user_acceptance` needs that a relayed sign-off is the user's, not Smith's.
///
/// A record enters on delivery through the user-message buffer (`recordBufferDelivery`) — the ONLY
/// path the app's input field uses, so a message posted any other way (an inspector direct message,
/// another agent, a system note) can never authorize a relay. It counts only once the run loop has
/// folded it into the conversation (`markIncorporated`): delivered-but-unread is not seen. A stretch
/// ends when the agent goes idle or its history is cleared (`endStretch`), so a reply cannot be
/// carried forward into a later, unrelated turn.
struct InAppUserMessageLedger {
    /// How much of a message an audit note quotes.
    static let excerptCharacterLimit = 240

    private var delivered: [UUID: InAppUserMessageRecord] = [:]
    private var incorporatedThisStretch: [InAppUserMessageRecord] = []

    mutating func recordBufferDelivery(_ message: ChannelMessage) {
        delivered[message.id] = InAppUserMessageRecord(
            messageID: message.id,
            authoredAt: message.timestamp,
            excerpt: Self.excerpt(of: message.content)
        )
    }

    /// Promotes delivered records among `messageIDs` to seen. Ids that were not buffer deliveries
    /// are ignored.
    mutating func markIncorporated(_ messageIDs: [UUID]) {
        for messageID in messageIDs {
            guard let record = delivered.removeValue(forKey: messageID) else { continue }
            incorporatedThisStretch.append(record)
        }
    }

    /// Forgets what was seen. Delivered-but-unread records survive: they are still queued for the
    /// conversation (a history clear keeps queued channel messages too), so the next stretch reads them.
    mutating func endStretch() {
        incorporatedThisStretch.removeAll()
    }

    /// The most recently AUTHORED message seen this stretch, if any.
    var latestIncorporated: InAppUserMessageRecord? {
        incorporatedThisStretch.max { $0.authoredAt < $1.authoredAt }
    }

    static func excerpt(of content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > excerptCharacterLimit else { return trimmed }
        return String(trimmed.prefix(excerptCharacterLimit)) + "…"
    }
}
