import Foundation

/// A pure, value-typed description of which channel messages a transcript view shows.
///
/// `Sendable` + `Equatable` so it is evaluated OFF the main actor inside `TranscriptStore` (the whole
/// point of the transcript architecture: filtering and fan-out never touch the UI thread) and compared
/// cheaply when a view reconfigures its pane. Every axis defaults to "pass everything"; the axes are
/// AND-composed, so `.all` (all defaults) matches every message.
///
/// The axes cover what the two panes need — a task-scoped top pane (`taskScope`) and a
/// Smith↔user-plus-configurables bottom pane (`allowedSenders` + `kinds` + `visibility`). The filter is
/// deliberately a plain value with a single `matches(_:)` predicate: no state, no I/O, no ordering — a
/// message either passes or it doesn't, independent of every other message, which is what lets a new
/// message be tested against a subscriber's filter in O(1) instead of re-scanning the whole transcript.
public struct TranscriptFilter: Sendable, Equatable {

    /// How the message-kind axis narrows the set. `kindless` = a message carrying no `messageKind`
    /// discriminator at all (plain chat, most system notices) — see `ChannelMessage.kind`.
    public enum KindRule: Sendable, Equatable {
        /// Every kind passes (and kindless passes).
        case all
        /// Only the named kinds pass; kindless passes iff `includingKindless`.
        case only(Set<ChannelMessageKind>, includingKindless: Bool)
        /// Everything passes EXCEPT the named kinds; kindless always passes (an exclusion list only
        /// removes named kinds — it never removes plain chat).
        case allExcept(Set<ChannelMessageKind>)
    }

    /// Which task a message must belong to.
    public enum TaskScope: Sendable, Equatable {
        /// Any task, or none — the message's `taskID` is not consulted.
        case any
        /// Only messages stamped with this task's id.
        case task(UUID)
        /// Only messages NOT tied to a task (`taskID == nil`) — Smith planning/replying overhead.
        case orchestration
    }

    /// Public (channel-wide) vs private (addressed to a specific agent) messages.
    public enum Visibility: Sendable, Equatable {
        case all
        case publicOnly
        case privateOnly
    }

    /// Which senders pass. `nil` = every sender. A non-nil set matches a message iff its `sender` is a
    /// member — `ChannelMessage.Sender` is `Hashable`, so `.agent(.smith)`, `.user`, etc. are set members.
    public var allowedSenders: Set<ChannelMessage.Sender>?
    public var kinds: KindRule
    public var taskScope: TaskScope
    public var visibility: Visibility

    public init(
        allowedSenders: Set<ChannelMessage.Sender>? = nil,
        kinds: KindRule = .all,
        taskScope: TaskScope = .any,
        visibility: Visibility = .all
    ) {
        self.allowedSenders = allowedSenders
        self.kinds = kinds
        self.taskScope = taskScope
        self.visibility = visibility
    }

    /// The pass-everything filter — the single-pane / firehose default.
    public static let all = TranscriptFilter()

    /// Whether `message` belongs in a pane governed by this filter. Pure and side-effect-free; safe to
    /// call from any isolation domain (it reads only the message's own value).
    public func matches(_ message: ChannelMessage) -> Bool {
        if let allowedSenders, !allowedSenders.contains(message.sender) { return false }

        switch kinds {
        case .all:
            break
        case .only(let set, let includingKindless):
            if let kind = message.kind {
                if !set.contains(kind) { return false }
            } else if !includingKindless {
                return false
            }
        case .allExcept(let set):
            if let kind = message.kind, set.contains(kind) { return false }
        }

        switch taskScope {
        case .any:
            break
        case .task(let id):
            if message.taskID != id { return false }
        case .orchestration:
            if message.taskID != nil { return false }
        }

        switch visibility {
        case .all:
            break
        case .publicOnly:
            if message.isPrivate { return false }
        case .privateOnly:
            if !message.isPrivate { return false }
        }

        return true
    }
}
