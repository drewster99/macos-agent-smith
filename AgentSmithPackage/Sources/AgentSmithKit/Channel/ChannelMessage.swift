import Foundation
import SwiftLLMKit

/// Who a private channel message is addressed to.
public enum MessageRecipient: Sendable, Equatable, Hashable {
    case agent(AgentRole)
    case user

    /// Display name shown in the channel log (e.g. "Smith", or the user's nickname).
    public var displayName: String {
        switch self {
        case .agent(let role): return role.displayName
        case .user:
            let nickname = AgentRole.userNickname
            return nickname.isEmpty ? "User" : nickname
        }
    }
}

extension MessageRecipient: Codable {
    private enum CodingKeys: String, CodingKey { case type, role }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "user":
            self = .user
        case "agent":
            let role = try container.decode(AgentRole.self, forKey: .role)
            self = .agent(role)
        default:
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "Unknown MessageRecipient type: \(type)")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .user:
            try container.encode("user", forKey: .type)
        case .agent(let role):
            try container.encode("agent", forKey: .type)
            try container.encode(role, forKey: .role)
        }
    }
}

/// A message posted to the shared communication channel.
///
/// Custom `Codable` conformance is provided to tolerate older on-disk JSON shapes:
///   - `attachments` may be missing (older messages had no attachment slot — defaults to `[]`).
///   - `recipient` may be present under the legacy key name `recipientRole` (a bare
///     `AgentRole` enum value rather than the current `MessageRecipient` envelope).
/// Without these fallbacks, a single legacy entry in `channel_log.json` would fail the
/// whole-array decode in `PersistenceManager.loadChannelLog()` and silently lose the log.
public struct ChannelMessage: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var timestamp: Date
    public var sender: Sender
    /// The intended recipient. `nil` means the message is public (visible to all agents).
    public var recipientID: UUID?
    /// Who this private message is addressed to, for display purposes.
    public var recipient: MessageRecipient?
    public var content: String
    /// File attachments (images, documents, any media).
    public var attachments: [Attachment]
    /// Optional structured metadata (e.g., tool call details).
    public var metadata: [String: AnyCodable]?

    // MARK: - Context stamping
    // Populated at post time from the sending/receiving agent's current state.

    /// Task this message was posted in service of, if any. System messages and
    /// unrelated chatter remain nil.
    public var taskID: UUID?
    /// Session ID of the orchestration run during which this message was posted.
    /// Auto-stamped by `MessageChannel.post` if nil at call time.
    public var sessionID: UUID?
    /// Provider ID of the model context this message is associated with. For agent
    /// messages this is the sending agent's current providerID; for user messages it
    /// is the receiving agent's; for system/tool-result messages it is the
    /// originating agent's. Nil when there's no meaningful attribution.
    public var providerID: String?
    /// Wire model ID associated with this message (mirror of `providerID` semantics).
    public var modelID: String?
    /// Full ModelConfiguration snapshot associated with this message. Like on
    /// `UsageRecord`, embedded directly so context-size/temperature/cache settings
    /// survive even if the source config is later deleted or edited.
    public var configuration: ModelConfiguration?

    /// Whether this message targets a specific agent rather than the public channel.
    public var isPrivate: Bool { recipientID != nil }

    /// This message's `messageKind` discriminator. See `ChannelMessageKind`.
    ///
    /// `nil` means exactly one thing: this message carries no `messageKind` at all — plenty of
    /// messages don't (plain chat, most system notices). It does NOT mean "a kind we couldn't
    /// place", because an unrecognized kind traps instead of returning nil.
    ///
    /// One derived kind: a message with no `messageKind` but a `securityDisposition` metadata
    /// entry answers `.securityReview`. Security-review rows were posted kindless for months
    /// before the kind existed, so the persisted corpus is full of them; `securityDisposition`
    /// is a typed key written only by the security-review posters, which makes it a reliable
    /// discriminator for exactly those rows. Deriving it HERE (the single accessor) rather than
    /// at read sites keeps historical and current rows indistinguishable to every consumer.
    ///
    /// Trapping is the point. The alternative — quietly answering nil — is a silent default of
    /// the worst sort: every `message.kind == .something` comparison downstream evaluates false,
    /// so a tool row renders as plain chat, a gate stops matching, a filter stops filtering, and
    /// nothing anywhere reports a problem. That is precisely the failure mode this type was
    /// introduced to end, and it would have been reintroduced by the enum's own nil-on-unknown
    /// behavior. A missing case is a bug in this file, not a data condition to tolerate.
    ///
    /// This should be unreachable from first-party writes: a post site can only name a case
    /// (the compiler enforces that), and `ChannelMessageKindLiteralGuardTests` fails the build
    /// on any hand-written `messageKind` string that could sneak past it. It fires for data
    /// written by a build whose enum knew a kind this one doesn't, or hand-edited JSON.
    public var kind: ChannelMessageKind? {
        guard let stored = metadata?["messageKind"] else {
            // Legacy security-review rows (posted before the kind existed) are recognizable by
            // the `securityDisposition` key their producers have always stamped — see the doc
            // comment above. Everything else without the key genuinely has no kind.
            if metadata?["securityDisposition"] != nil { return .securityReview }
            return nil
        }
        // Present but not a string. Folding this into the nil above would conflate "no kind"
        // with "the kind is corrupt" — two conditions that demand opposite responses, one of
        // them silently. Whatever wrote a non-string here is broken and should be found.
        guard case .string(let raw) = stored else {
            fatalError("""
                messageKind on ChannelMessage \(id) is \(stored), not a string.

                The slot is written exclusively by `.kind(_:)`, which always stores `.string`. \
                A different type here means something bypassed it — find that writer.
                """)
        }
        guard let kind = ChannelMessageKind(rawValue: raw) else {
            fatalError("""
                Unknown messageKind "\(raw)" on ChannelMessage \(id).

                Every kind must have a case in ChannelMessageKind — a missing one makes this \
                accessor nil and silently sends every reader down the wrong branch.

                Fix: add `case \(Self.suggestedCaseName(for: raw)) = "\(raw)"` to ChannelMessageKind, \
                add it to `expectedWireStrings` in ChannelMessageKindTests, and if this kind is no \
                longer emitted by any source file, put it under the `// MARK: Retired` section.

                If this appeared after loading old logs, re-run the corpus scan described in \
                ChannelMessageKind's doc comment — the case list is derived from persisted data, \
                not from grepping the sources.
                """)
        }
        return kind
    }

    /// Converts a wire string to the camelCase case name the enum would use, so the trap above
    /// can print a line the developer can paste rather than a rule they have to apply.
    ///
    /// Total by construction: an empty or all-underscore input yields an empty string, which is
    /// visibly wrong in the trap message rather than quietly substituted with something plausible.
    private static func suggestedCaseName(for rawValue: String) -> String {
        let parts = rawValue.split(separator: "_").map(String.init)
        return (parts.first ?? "") + parts.dropFirst().map { $0.capitalized }.joined()
    }

    public enum Sender: Codable, Sendable, Hashable {
        case agent(AgentRole)
        case user
        case system
        /// An acceptance validator's own activity (e.g. its evidence tool calls). A display-only
        /// sender — validators are ephemeral evaluation functions, not configurable `AgentRole`s —
        /// kept distinct from the Security Agent that merely gates those calls.
        case validator

        /// Display name for the sender.
        public var displayName: String {
            switch self {
            case .agent(let role): return role.displayName
            case .user:
                let nickname = AgentRole.userNickname
                return nickname.isEmpty ? "User" : nickname
            case .system: return "System"
            case .validator: return "Validator"
            }
        }
    }

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        sender: Sender,
        recipientID: UUID? = nil,
        recipient: MessageRecipient? = nil,
        content: String,
        attachments: [Attachment] = [],
        metadata: [String: AnyCodable]? = nil,
        taskID: UUID? = nil,
        sessionID: UUID? = nil,
        providerID: String? = nil,
        modelID: String? = nil,
        configuration: ModelConfiguration? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.sender = sender
        self.recipientID = recipientID
        self.recipient = recipient
        self.content = content
        self.attachments = attachments
        self.metadata = metadata
        self.taskID = taskID
        self.sessionID = sessionID
        self.providerID = providerID
        self.modelID = modelID
        self.configuration = configuration
    }

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, sender, recipientID, recipient, content, attachments, metadata
        case taskID, sessionID, providerID, modelID, configuration
        // Legacy decode-only key — older messages stored the recipient as a bare
        // AgentRole under this name. New writes use `recipient` (MessageRecipient envelope).
        case recipientRole
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        sender = try c.decode(Sender.self, forKey: .sender)
        recipientID = try c.decodeIfPresent(UUID.self, forKey: .recipientID)
        if let direct = try c.decodeIfPresent(MessageRecipient.self, forKey: .recipient) {
            recipient = direct
        } else if let legacyRole = try c.decodeIfPresent(AgentRole.self, forKey: .recipientRole) {
            // Legacy on-disk shape: bare AgentRole. Promote to the agent-recipient envelope.
            recipient = .agent(legacyRole)
        } else {
            recipient = nil
        }
        content = try c.decode(String.self, forKey: .content)
        attachments = try c.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        metadata = try c.decodeIfPresent([String: AnyCodable].self, forKey: .metadata)
        taskID = try c.decodeIfPresent(UUID.self, forKey: .taskID)
        sessionID = try c.decodeIfPresent(UUID.self, forKey: .sessionID)
        providerID = try c.decodeIfPresent(String.self, forKey: .providerID)
        modelID = try c.decodeIfPresent(String.self, forKey: .modelID)
        configuration = try c.decodeIfPresent(ModelConfiguration.self, forKey: .configuration)
    }

    /// Custom encoder. Required because the synthesized one would emit every
    /// `CodingKeys` case, including the legacy decode-only `recipientRole` key —
    /// which doesn't map to a stored property and would not compile.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(sender, forKey: .sender)
        try c.encodeIfPresent(recipientID, forKey: .recipientID)
        try c.encodeIfPresent(recipient, forKey: .recipient)
        try c.encode(content, forKey: .content)
        try c.encode(attachments, forKey: .attachments)
        try c.encodeIfPresent(metadata, forKey: .metadata)
        try c.encodeIfPresent(taskID, forKey: .taskID)
        try c.encodeIfPresent(sessionID, forKey: .sessionID)
        try c.encodeIfPresent(providerID, forKey: .providerID)
        try c.encodeIfPresent(modelID, forKey: .modelID)
        try c.encodeIfPresent(configuration, forKey: .configuration)
    }
}
