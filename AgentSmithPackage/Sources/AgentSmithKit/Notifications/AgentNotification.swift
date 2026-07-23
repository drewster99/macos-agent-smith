import Foundation
import SwiftLLMKit

/// The deterministic dedup key for a notification occurrence. Derived from the producing
/// source's namespace plus the source-supplied idempotency key, so the SAME occurrence
/// re-posted after a crash yields the SAME id and the delivery ledger recognizes the duplicate.
/// A caller-minted random id would defeat that, so this is never random.
public struct NotificationID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let raw: String

    public init(namespace: String, key: String) {
        self.raw = "\(namespace)|\(key)"
    }

    /// Only for decoding / tests — prefer `init(namespace:key:)` so ids stay deterministic.
    public init(raw: String) {
        self.raw = raw
    }

    public var description: String { raw }
}

/// Which SUBSYSTEM produced a notification — for audit and route-back. This is NOT the semantic
/// source (`payload.data["source"]` carries "iMessage"/"Slack" for a `user_message`). The
/// `namespace` is what the id derivation uses; associated values are audit detail.
public enum TriggerSource: Sendable, Codable, Equatable {
    case timer(scheduleID: UUID, occurrence: Date)
    case inboundMessageObserver
    /// Forward-compat: a trigger written by a NEWER build decodes here rather than throwing.
    /// Sources are added freely, so an old build must tolerate an unrecognized trigger without
    /// bricking the decode of a whole persisted array — hence the custom `Codable` below, NOT the
    /// synthesized one (which throws on an unknown case).
    case unknown

    /// Stable id-namespace, insensitive to associated values. Two occurrences of the same timer
    /// differ only by their idempotency key, never by namespace.
    public var namespace: String {
        switch self {
        case .timer: return "timer"
        case .inboundMessageObserver: return "inbox"
        case .unknown: return "unknown"
        }
    }

    private enum Kind: String, Codable { case timer, inboundMessageObserver, unknown }
    private enum CodingKeys: String, CodingKey { case kind, scheduleID, occurrence }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // An unrecognized (or absent) kind → `.unknown`, never a throw. A `try?` here is justified:
        // the alternative is a hard failure that discards every co-persisted notification.
        let kind = (try? container.decode(Kind.self, forKey: .kind)) ?? .unknown
        switch kind {
        case .timer:
            self = .timer(
                scheduleID: try container.decode(UUID.self, forKey: .scheduleID),
                occurrence: try container.decode(Date.self, forKey: .occurrence)
            )
        case .inboundMessageObserver:
            self = .inboundMessageObserver
        case .unknown:
            self = .unknown
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .timer(let scheduleID, let occurrence):
            try container.encode(Kind.timer, forKey: .kind)
            try container.encode(scheduleID, forKey: .scheduleID)
            try container.encode(occurrence, forKey: .occurrence)
        case .inboundMessageObserver:
            try container.encode(Kind.inboundMessageObserver, forKey: .kind)
        case .unknown:
            try container.encode(Kind.unknown, forKey: .kind)
        }
    }
}

/// A notification's routing target. Typed and CLOSED — the broker must resolve it exhaustively,
/// which is why it never lives inside the open `data`. `RecipientKind` is the target-registration
/// key (kind without the per-notification payload).
public enum Recipient: Sendable, Codable, Equatable {
    /// No conversation — handled mechanically by the runtime (only `.acted` outcomes carry this).
    case runtime
    /// The long-lived orchestrator.
    case smith
    /// The worker (Brown) assigned to a task. Delivery may queue until the task's next spawn.
    case taskWorker(taskID: UUID)
    /// An outward bridge (e.g. deliver back out to iMessage/Slack), named by target key.
    case external(String)

    public var kind: RecipientKind {
        switch self {
        case .runtime: return .runtime
        case .smith: return .smith
        case .taskWorker: return .taskWorker
        case .external(let name): return .external(name)
        }
    }
}

/// The registration key for a `RecipientTarget` — a recipient's kind without its per-notification
/// payload (a `.taskWorker` target handles every task's worker; the specific `taskID` rides on the
/// notification).
public enum RecipientKind: Sendable, Hashable {
    case runtime
    case smith
    case taskWorker
    case external(String)
}

/// The open, self-describing content of a notification. Stored and serialized as-is; decoded into a
/// typed struct only at the handler boundary. The broker/ledger never reach inside `data`.
public struct Payload: Sendable, Codable, Equatable {
    /// Stable CONTRACT identifier — e.g. "task_action", "user_message". Authored as identity,
    /// versioned, single-source. The broker's handler-registry key.
    public var type: String
    /// Schema version for `type`; default 1. Per-type `data` migrations key on this.
    public var version: Int
    /// Type-specific content, decoded by the registered handler. `AnyCodable` matches the tool-arg
    /// currency so producers/handlers speak the same value language everywhere.
    public var data: [String: AnyCodable]

    public init(type: String, version: Int = 1, data: [String: AnyCodable] = [:]) {
        self.type = type
        self.version = version
        self.data = data
    }
}

/// A notification: a typed envelope wrapping an open payload. The envelope's fields are everything
/// the delivery core must reason about (identity, routing, audit); only `payload` is open.
public struct AgentNotification: Sendable, Codable, Identifiable, Equatable {
    /// Deterministic per occurrence — the dedup key. Never in `data`.
    public let id: NotificationID
    public var triggerSource: TriggerSource
    public var recipient: Recipient
    /// ≤80 chars. Transcript / debug chrome ONLY. Never parsed for behavior.
    public var title: String
    public var createdAt: Date
    public var deliveredAt: Date?
    /// Undelivered past this → dropped (app was off; no longer relevant). Nil = never expires.
    public var expiresAt: Date?
    public var payload: Payload

    public init(
        id: NotificationID,
        triggerSource: TriggerSource,
        recipient: Recipient,
        title: String,
        createdAt: Date,
        deliveredAt: Date? = nil,
        expiresAt: Date? = nil,
        payload: Payload
    ) {
        self.id = id
        self.triggerSource = triggerSource
        self.recipient = recipient
        self.title = String(title.prefix(Self.maxTitleCharacters))
        self.createdAt = createdAt
        self.deliveredAt = deliveredAt
        self.expiresAt = expiresAt
        self.payload = payload
    }

    /// Display-title ceiling. Titles are chrome; over-long ones are truncated at construction.
    public static let maxTitleCharacters = 80
}
