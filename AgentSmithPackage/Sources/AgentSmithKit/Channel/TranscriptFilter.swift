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
        /// Only messages NOT tied to a task (`taskID == nil`) — Smith planning/replying overhead —
        /// plus user task-action notices, which are addressed to Smith though they name a task.
        case orchestration
        /// Nothing matches. The empty-selection state for a pane that shows one task at a time — its
        /// provider stays subscribed but delivers no rows until a task is picked.
        case matchNone
    }

    /// Public (channel-wide) vs private (addressed to a specific agent) messages.
    public enum Visibility: String, Sendable, Equatable, Codable, CaseIterable {
        case all
        case publicOnly
        case privateOnly
    }

    /// Which senders pass. `nil` = every sender. A non-nil set matches a message iff its `sender` is a
    /// member — `ChannelMessage.Sender` is `Hashable`, so `.agent(.smith)`, `.user`, etc. are set members.
    public var allowedSenders: Set<ChannelMessage.Sender>?
    /// Which recipients pass. `nil` = every recipient. A non-nil set filters PRIVATE (addressed) messages
    /// by their `recipient`; a PUBLIC message (no recipient) always passes. This is the axis that lets a
    /// view hide everything addressed TO a worker, which the sender axis can't (a Security-Agent-to-Brown
    /// message has an ALLOWED sender).
    public var allowedRecipients: Set<MessageRecipient>?
    /// The DEFAULT kind rule — applies to any sender without an entry in `kindsBySender`.
    public var kinds: KindRule
    /// Per-sender kind rules. A sender with an entry uses ITS rule instead of `kinds`; a sender
    /// without one falls through to the default, so a sender case added later is governed by the
    /// default rather than silently unfiltered (or silently hidden). This is what lets a view show
    /// tool output from Smith while hiding it from Brown.
    public var kindsBySender: [ChannelMessage.Sender: KindRule]
    public var taskScope: TaskScope
    public var visibility: Visibility
    /// When true, messages at `.error` severity are hidden. Errors are a cross-cutting axis, not a
    /// kind. Default false — errors show.
    ///
    /// Note this only ever SUBTRACTS, like every other axis here. It cannot re-admit a message that
    /// another axis excluded, which is what `alwaysShowAtOrAbove` is for.
    public var hideErrors: Bool
    /// The severity FLOOR: a message at or above this level is shown no matter what any other axis
    /// says. `nil` disables the floor entirely.
    ///
    /// Every other property on this type is an exclusion, and `matches` is a chain of vetoes — so
    /// before this existed there was no way to express "whatever else I've hidden, always show me
    /// anything bad". That gap was not theoretical: hiding `tool_output` to quiet the transcript
    /// also hid seven consecutive `create_task` FAILURES on 2026-09-20, the user saw nothing, and
    /// the request they had made was silently dropped. A noise filter must never be a failure
    /// filter.
    ///
    /// Defaults to `.warning`, so the safe behavior is what you get without asking. `hideErrors`
    /// deliberately still wins over the floor — it is an explicit "I do not want to see errors in
    /// THIS pane", and a user who says that outright should be obeyed; the floor exists for the
    /// far commoner case of errors hidden as a SIDE EFFECT of filtering something else.
    public var alwaysShowAtOrAbove: MessageSeverity?
    /// Tool names whose request and output rows are hidden. Empty = every tool shows.
    ///
    /// Its own axis rather than part of the kind rule: the kind axis can only say "all tool calls or
    /// none", and `.toolRequest` / `.toolOutput` are the same two kinds whichever tool produced them.
    ///
    /// Stored as the HIDDEN set, like `TranscriptKindSelection.hiddenKinds`, so a tool that does not
    /// exist yet — a new built-in, or any MCP tool — is visible in every already-saved config rather
    /// than silently filtered out. Matching is by name because that is what a tool HAS; an MCP tool's
    /// name is defined by its server and no enum here could enumerate it.
    public var hiddenToolNames: Set<String>
    /// Per-sender hidden tool names, mirroring `kindsBySender`. A sender with an entry uses ITS set
    /// instead of the default, so "hide bash from Brown but not from Smith" is expressible — which
    /// is the same shape the kind axis already has, and the reason this is not a single global set.
    public var hiddenToolNamesBySender: [ChannelMessage.Sender: Set<String>]

    public init(
        allowedSenders: Set<ChannelMessage.Sender>? = nil,
        allowedRecipients: Set<MessageRecipient>? = nil,
        kinds: KindRule = .all,
        kindsBySender: [ChannelMessage.Sender: KindRule] = [:],
        taskScope: TaskScope = .any,
        visibility: Visibility = .all,
        hideErrors: Bool = false,
        alwaysShowAtOrAbove: MessageSeverity? = .warning,
        hiddenToolNames: Set<String> = [],
        hiddenToolNamesBySender: [ChannelMessage.Sender: Set<String>] = [:]
    ) {
        self.allowedSenders = allowedSenders
        self.allowedRecipients = allowedRecipients
        self.kinds = kinds
        self.kindsBySender = kindsBySender
        self.taskScope = taskScope
        self.visibility = visibility
        self.hideErrors = hideErrors
        self.alwaysShowAtOrAbove = alwaysShowAtOrAbove
        self.hiddenToolNames = hiddenToolNames
        self.hiddenToolNamesBySender = hiddenToolNamesBySender
    }

    /// The pass-everything filter — the single-pane / firehose default.
    public static let all = TranscriptFilter()

    /// Whether `message` belongs in a pane governed by this filter. Pure and side-effect-free; safe to
    /// call from any isolation domain (it reads only the message's own value).
    public func matches(_ message: ChannelMessage) -> Bool {
        let severity = message.severity
        // `hideErrors` is the one NOISE axis allowed to veto a message the floor would admit: it
        // is an explicit request not to see errors here, whereas the floor exists to defeat
        // filters that hide errors INCIDENTALLY. Checked first so the two cannot disagree.
        if hideErrors, severity >= .error { return false }

        // SCOPE axes, checked BEFORE the floor — these decide whether the message belongs to this
        // pane at all, and the floor must never override them. A pane showing one task would
        // otherwise display another task's errors; `.matchNone`, which exists to show NOTHING
        // until a task is picked, would show them too. "Surface anything bad" means surfacing it
        // where it belongs, not everywhere.
        switch taskScope {
        case .any:
            break
        case .task(let id):
            if message.taskID != id { return false }
        case .orchestration:
            // A user's task action is a notice TO Smith, so it belongs to the orchestration layer
            // even though it names its task (the task id is what its inline Resume/Undelete acts on).
            if message.taskID != nil, message.kind != .userTaskAction { return false }
        case .matchNone:
            return false
        }
        switch visibility {
        case .all:
            break
        case .publicOnly:
            if message.isPrivate { return false }
        case .privateOnly:
            if !message.isPrivate { return false }
        }

        // The floor. Everything below is a NOISE exclusion — a category the user chose not to
        // read — so returning true here is the only way a message those axes hide still lands.
        if let alwaysShowAtOrAbove, severity >= alwaysShowAtOrAbove { return true }

        if let allowedSenders, !allowedSenders.contains(message.sender) { return false }
        // Recipient axis filters PRIVATE messages; a public message (no recipient) always passes.
        if let allowedRecipients, let recipient = message.recipient, !allowedRecipients.contains(recipient) {
            return false
        }
        // Covers BOTH the request and the output row: each carries the same `tool` name, so hiding
        // a tool hides the whole exchange rather than leaving an orphaned output under a request
        // that is no longer shown.
        let hiddenTools = hiddenToolNamesBySender[message.sender] ?? hiddenToolNames
        if !hiddenTools.isEmpty, let toolName = message.toolName, hiddenTools.contains(toolName) {
            return false
        }

        switch kindsBySender[message.sender] ?? kinds {
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

        return true
    }
}
