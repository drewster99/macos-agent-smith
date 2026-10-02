import Foundation

/// A pure, value-typed description of which channel messages a transcript view shows.
///
/// `Sendable` + `Equatable` so it is evaluated OFF the main actor inside `TranscriptStore` (the whole
/// point of the transcript architecture: filtering and fan-out never touch the UI thread) and compared
/// cheaply when a view reconfigures its pane. Every axis defaults to "pass everything"; the axes are
/// AND-composed, so `.all` (all defaults) matches every message.
///
/// The axes cover what the two panes need — a task-scoped top pane (`taskScope`) and a
/// Smith↔user-plus-configurables bottom pane (`hiddenParticipants` + `kindsBySender`). The filter is
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

    /// Participants whose messages are hidden — every message FROM one (`ChannelMessage.author`),
    /// and every message addressed TO one (`ChannelMessage.addressee`). Empty = everyone shows.
    ///
    /// One axis for both directions because that is what "hide Brown" means to a reader: a
    /// Security-Agent verdict addressed to Brown is Brown's business even though Brown didn't send
    /// it. This replaced separate sender and recipient allow-lists (plus a public/private switch)
    /// that had to be kept in step by hand to express exactly this. Stored as the HIDDEN set so a
    /// sender this build doesn't list is visible rather than silently filtered out.
    public var hiddenParticipants: Set<ChannelMessage.Sender>
    /// The DEFAULT kind rule — applies to any sender without an entry in `kindsBySender`.
    public var kinds: KindRule
    /// Per-sender kind rules. A sender with an entry uses ITS rule instead of `kinds`; a sender
    /// without one falls through to the default, so a sender case added later is governed by the
    /// default rather than silently unfiltered (or silently hidden). This is what lets a view show
    /// tool output from Smith while hiding it from Brown.
    public var kindsBySender: [ChannelMessage.Sender: KindRule]
    public var taskScope: TaskScope
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
    /// Per-author hidden classes of Security Agent verdict (accept / warn / block) — a sub-axis of
    /// the `.securityReview` kind, the way `hiddenToolNamesBySender` is of the tool kinds.
    public var hiddenVerdictClassesBySender: [ChannelMessage.Sender: Set<SecurityVerdictClass>]

    public init(
        hiddenParticipants: Set<ChannelMessage.Sender> = [],
        kinds: KindRule = .all,
        kindsBySender: [ChannelMessage.Sender: KindRule] = [:],
        taskScope: TaskScope = .any,
        hideErrors: Bool = false,
        alwaysShowAtOrAbove: MessageSeverity? = .warning,
        hiddenToolNames: Set<String> = [],
        hiddenToolNamesBySender: [ChannelMessage.Sender: Set<String>] = [:],
        hiddenVerdictClassesBySender: [ChannelMessage.Sender: Set<SecurityVerdictClass>] = [:]
    ) {
        self.hiddenParticipants = hiddenParticipants
        self.kinds = kinds
        self.kindsBySender = kindsBySender
        self.taskScope = taskScope
        self.hideErrors = hideErrors
        self.alwaysShowAtOrAbove = alwaysShowAtOrAbove
        self.hiddenToolNames = hiddenToolNames
        self.hiddenToolNamesBySender = hiddenToolNamesBySender
        self.hiddenVerdictClassesBySender = hiddenVerdictClassesBySender
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

        // SCOPE, checked BEFORE the floor — it decides whether the message belongs to this pane at
        // all, and the floor must never override it. A pane showing one task would otherwise
        // display another task's errors; `.matchNone`, which exists to show NOTHING until a task
        // is picked, would show them too. "Surface anything bad" means where it belongs.
        guard isInScope(message) else { return false }

        // The floor. Everything below is a NOISE exclusion — a category the user chose not to
        // read — so returning true here is the only way a message those axes hide still lands.
        if let alwaysShowAtOrAbove, severity >= alwaysShowAtOrAbove { return true }

        // Identity is the AUTHOR, not the poster: a Security Agent verdict is posted by the system
        // but belongs to the Security Agent — and is addressed to the agent whose call it judged.
        let author = message.author
        if !hiddenParticipants.isEmpty {
            if hiddenParticipants.contains(author) { return false }
            if let addressee = message.addressee, hiddenParticipants.contains(addressee) { return false }
        }
        // Covers BOTH the request and the output row: each carries the same `tool` name, so hiding
        // a tool hides the whole exchange rather than leaving an orphaned output under a request
        // that is no longer shown.
        let hiddenTools = hiddenToolNamesBySender[author] ?? hiddenToolNames
        if !hiddenTools.isEmpty, let toolName = message.toolName, hiddenTools.contains(toolName) {
            return false
        }

        if let verdictClass = message.securityVerdictClass,
           hiddenVerdictClassesBySender[author]?.contains(verdictClass) == true {
            return false
        }

        switch kindsBySender[author] ?? kinds {
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

    /// The scope axis alone: does this message belong to this pane at all?
    private func isInScope(_ message: ChannelMessage) -> Bool {
        switch taskScope {
        case .any:
            return true
        case .task(let id):
            return message.taskID == id
        case .orchestration:
            // A user's task action is a notice TO Smith, so it belongs to the orchestration layer
            // even though it names its task (the task id is what its inline Resume/Undelete acts on).
            return message.taskID == nil || message.kind == .userTaskAction
        case .matchNone:
            return false
        }
    }
}

extension MessageRecipient {
    /// The participant this recipient names, in sender terms — the identity the participant axis
    /// keys on, so "hide Brown" catches messages addressed to Brown as well as Brown's own.
    public var participant: ChannelMessage.Sender {
        switch self {
        case .user: return .user
        case .agent(let role): return .agent(role)
        }
    }
}
