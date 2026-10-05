import Foundation

/// One ability a task's worker needs, stated in terms of what it must DO ("Compile the Xcode
/// project", "Read the user's calendar"), never as a tool name.
///
/// Its own field rather than prose at the bottom of the description (decided 2026-10-05, user):
/// the Security Agent's tool scoping is told to pay special attention to it, and when a running
/// worker turns out to lack something, Smith ADDS the unmet need here — with the reason — instead
/// of granting a tool. A later addition stays visibly marked as one everywhere the list is shown.
public struct RequiredCapability: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var text: String
    /// Who wrote this item.
    public let addedBy: TaskAuthorship
    public let addedAt: Date
    /// Whether this item was part of the task as written or was added after the task existed.
    public var origin: Origin
    /// Why this item was added. Smith always gives one for a later addition; nil when the author
    /// gave none (the items a task is written with, or one the user added in the editor).
    public let reason: String?

    public enum Origin: String, Codable, Sendable {
        /// Part of the task as written: `create_task`, the editor's Create, or carried into a
        /// template instance when it was created.
        case asWritten
        /// Added after the task existed — the unmet need of a running worker, typically.
        case addedLater

        /// Forward compatibility: an origin this build doesn't know is shown as a later addition,
        /// the reading that asks the most of a reader's attention, rather than failing the decode
        /// of the whole task.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Origin(rawValue: raw) ?? .addedLater
        }
    }

    public init(
        id: UUID = UUID(),
        text: String,
        addedBy: TaskAuthorship,
        addedAt: Date = Date(),
        origin: Origin,
        reason: String? = nil
    ) {
        self.id = id
        self.text = text
        self.addedBy = addedBy
        self.addedAt = addedAt
        self.origin = origin
        self.reason = reason
    }

    /// The item as every agent-facing reader shows it: the text, and for a later addition who
    /// added it, when, and why.
    public var renderedLine: String {
        switch origin {
        case .asWritten:
            return text
        case .addedLater:
            let why = reason.map { ": \($0)" } ?? ""
            return "\(text) [added later by \(addedBy.displayName), \(addedAt.formatted(.iso8601))\(why)]"
        }
    }

    /// The comparison key for "is this already listed": case- and whitespace-insensitive, so a
    /// re-sent addition doesn't stack a near-identical line.
    var normalizedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }
}

extension TaskAuthorship {
    /// How an author is named where a later addition is attributed ("added later by Smith").
    public var displayName: String {
        switch self {
        case .user: return "the user"
        case .smith: return "Smith"
        case .worker: return "the worker"
        case .system: return "the system"
        }
    }
}

/// What `TaskStore.addRequiredCapability` did. "Already listed" is distinct from "added" because
/// only an addition changes what the worker's tools are scoped against.
public enum RequiredCapabilityAddition: Sendable, Equatable {
    case added(RequiredCapability)
    case alreadyListed(RequiredCapability)
    case refused(String)
}
