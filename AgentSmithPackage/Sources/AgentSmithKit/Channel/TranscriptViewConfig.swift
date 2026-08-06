import Foundation

/// Groups every `ChannelMessageKind` into the toggleable categories the bottom transcript pane's
/// filter popover exposes ("turn tool calls off", "hide memory noise", …). This is the authoritative
/// grouping — `TranscriptViewConfigTests` guards that every non-chat kind belongs to exactly ONE
/// group, so a newly-added kind can never silently vanish from the popover (it fails the build until
/// it's grouped).
///
/// `chat` is special: it covers NO kind. It governs KINDLESS messages — plain user↔Smith conversation,
/// which carry no `messageKind` — via `governsKindless`.
public enum TranscriptKindGroup: String, CaseIterable, Codable, Sendable, Identifiable {
    case chat
    case toolCalls
    case securityReviews
    case taskLifecycle
    case validation
    case memory
    case system

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .chat: return "Chat"
        case .toolCalls: return "Tool calls"
        case .securityReviews: return "Security reviews"
        case .taskLifecycle: return "Task lifecycle"
        case .validation: return "Validation"
        case .memory: return "Memory"
        case .system: return "System"
        }
    }

    /// One-line explanation shown under the toggle.
    public var detail: String {
        switch self {
        case .chat: return "Plain conversation with no structural kind"
        case .toolCalls: return "Tool requests and their output"
        case .securityReviews: return "Security Agent verdicts, auto-approvals, and review errors"
        case .taskLifecycle: return "Task created / updated / completed, help, worker messages"
        case .validation: return "Acceptance-criteria verdicts and escalations"
        case .memory: return "Memory saves and searches"
        case .system: return "Timers, context management, agent lifecycle, MCP status, advisories"
        }
    }

    /// The kinds this group covers. `chat` covers none (it governs kindless messages — see
    /// `governsKindless`). Retired kinds are grouped alongside their live siblings so historical
    /// transcripts filter the same as current ones.
    public var kinds: Set<ChannelMessageKind> {
        switch self {
        case .chat:
            return []
        case .toolCalls:
            return [.toolRequest, .toolOutput]
        case .securityReviews:
            return [.securityReview]
        case .taskLifecycle:
            return [.taskCreated, .taskAcknowledged, .taskContinuing, .taskComplete, .taskCompleted,
                    .taskFailed, .taskUpdate, .taskUpdateGuidance, .taskSummarized, .taskActionScheduled,
                    .taskQueuedAtCapacity, .taskLifecycle, .scheduledRunDeferred, .orchestratorMessage,
                    .taskAmendment, .helpRequested, .helpProvided, .taskInterrupted]
        case .validation:
            return [.changesRequested, .criteriaUpdated, .validationReport, .validationFailed,
                    .validationEscalation, .submissionAutoRejected, .validationBlocked,
                    .validationBlockedWorkerNotice, .validationWaitNotice, .validationOverride]
        case .memory:
            return [.memorySaved, .memorySearched]
        case .system:
            return [.inboundUserMessage, .contextManagement, .timerActivity, .mcpStatus,
                    .restartChrome, .preparing, .agentOnline,
                    .agentLifecycle, .agentRecovery, .rateLimit, .statusUpdate, .advisory]
        }
    }

    /// Whether this group governs kindless (plain-chat) messages. Only `.chat` does.
    public var governsKindless: Bool { self == .chat }
}

/// A persisted, user-editable description of what the bottom transcript pane shows: which message
/// kinds are visible (every `ChannelMessageKind` individually), which senders, and public/private.
/// Turned into an off-main `TranscriptFilter` by `makeFilter`. Persisted per session in
/// `SessionState.transcriptViewConfig`.
public struct TranscriptViewConfig: Codable, Sendable, Equatable {
    /// The kinds that are HIDDEN — the single source of truth for the kind axis. Empty = every
    /// kind shows. Stored inverted for the same reason the group set was: a kind added in a later
    /// build defaults to VISIBLE in every already-saved config, instead of silently vanishing.
    /// `TranscriptKindGroup` is a UI convenience layered over this set (see `groupVisibility(of:)`),
    /// never a second source of truth.
    public var hiddenKinds: Set<ChannelMessageKind>
    /// Whether KINDLESS messages — plain user↔Smith conversation, which carry no `messageKind` —
    /// are shown. The per-kind set cannot express this (there is no kind to hide), so it is its
    /// own switch; the popover presents it as the "Chat" row.
    public var showsChat: Bool
    /// Which senders are shown. `nil` = every sender (the common case); a non-nil set is an allow-list.
    public var allowedSenders: Set<ChannelMessage.Sender>?
    /// Which recipients are shown. `nil` = every recipient; a non-nil set filters PRIVATE (addressed)
    /// messages (a public message always passes). This is what lets the default hide everything addressed
    /// TO a worker — the sender axis can't (a Security-Agent-to-Brown message has an allowed sender).
    public var allowedRecipients: Set<MessageRecipient>?
    /// Public / private / all.
    public var visibility: TranscriptFilter.Visibility
    /// When true, only messages with NO associated task (the Smith↔user orchestration layer) show — the
    /// per-task chatter of individual workers is hidden. This is the primary knob that makes the default
    /// the conversation rather than the firehose.
    public var hideTaskScoped: Bool
    /// When false, error messages (`metadata["isError"]`) are hidden.
    public var showErrors: Bool

    public init(
        hiddenKinds: Set<ChannelMessageKind> = [],
        showsChat: Bool = true,
        allowedSenders: Set<ChannelMessage.Sender>? = nil,
        allowedRecipients: Set<MessageRecipient>? = nil,
        visibility: TranscriptFilter.Visibility = .all,
        hideTaskScoped: Bool = false,
        showErrors: Bool = true
    ) {
        self.hiddenKinds = hiddenKinds
        self.showsChat = showsChat
        self.allowedSenders = allowedSenders
        self.allowedRecipients = allowedRecipients
        self.visibility = visibility
        self.hideTaskScoped = hideTaskScoped
        self.showErrors = showErrors
    }

    // MARK: Group + kind accessors (the popover's surface over the per-kind truth)

    /// Group-level visibility DERIVED from the per-kind set — a display state, never stored.
    public enum GroupVisibility: Sendable, Equatable {
        case all, none, mixed
    }

    /// Where a group's kinds stand in the hidden set. `.chat` reports `showsChat` (it has no kinds).
    public func groupVisibility(of group: TranscriptKindGroup) -> GroupVisibility {
        if group.governsKindless { return showsChat ? .all : .none }
        let hidden = group.kinds.intersection(hiddenKinds).count
        if hidden == 0 { return .all }
        return hidden == group.kinds.count ? .none : .mixed
    }

    /// Shows or hides every kind in a group at once — the group checkbox. `.chat` flips `showsChat`.
    public mutating func setGroup(_ group: TranscriptKindGroup, visible: Bool) {
        if group.governsKindless {
            showsChat = visible
        } else if visible {
            hiddenKinds.subtract(group.kinds)
        } else {
            hiddenKinds.formUnion(group.kinds)
        }
    }

    public func isKindVisible(_ kind: ChannelMessageKind) -> Bool {
        !hiddenKinds.contains(kind)
    }

    public mutating func setKind(_ kind: ChannelMessageKind, visible: Bool) {
        if visible { hiddenKinds.remove(kind) } else { hiddenKinds.insert(kind) }
    }

    private enum CodingKeys: String, CodingKey {
        case hiddenKinds, showsChat, visibleGroups, hiddenGroups,
             allowedSenders, allowedRecipients, visibility, hideTaskScoped, showErrors
    }

    /// Custom decode, for two reasons. (1) A config persisted BEFORE the recipient / task-scope / error
    /// axes existed still reads back — the synthesized decoder emits a hard `decode` for every
    /// non-optional key and would throw `keyNotFound` on the missing ones, taking the whole
    /// `SessionState` decode down with it. Each field falls back to the same default as the memberwise
    /// init. (2) Kind visibility is stored INVERTED, as `hiddenKinds` — see `encode(to:)` — and two
    /// generations of GROUP-level persistence migrate here by expanding each hidden group to its kinds:
    /// the group's kinds ARE what that config hid, so the expansion shows exactly what it showed.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let hiddenNames = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenKinds) {
            // Decoded as raw strings, not `Set<ChannelMessageKind>`, so a kind written by a NEWER
            // build doesn't throw here. Ignoring an unknown hidden name fails open — that kind's
            // messages show — which beats failing the whole `SessionState` decode.
            hiddenKinds = Set(hiddenNames.compactMap(ChannelMessageKind.init(rawValue:)))
            showsChat = try c.decodeIfPresent(Bool.self, forKey: .showsChat) ?? true
        } else if let hiddenGroupNames = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenGroups) {
            // The group-persisted generation (same inverted philosophy, coarser grain).
            let hidden = Set(hiddenGroupNames.compactMap(TranscriptKindGroup.init(rawValue:)))
            hiddenKinds = hidden.reduce(into: Set<ChannelMessageKind>()) { $0.formUnion($1.kinds) }
            showsChat = !hidden.contains(.chat)
        } else if let legacyVisible = try c.decodeIfPresent(Set<TranscriptKindGroup>.self, forKey: .visibleGroups) {
            // Written by a build that stored the VISIBLE group set and predates `securityReviews`.
            // Security-review rows were kindless then, so the Chat toggle governed them —
            // inheriting Chat's state preserves exactly what this config showed before the upgrade.
            let visible = legacyVisible.contains(.chat)
                ? legacyVisible.union([.securityReviews])
                : legacyVisible
            let hidden = Set(TranscriptKindGroup.allCases).subtracting(visible)
            hiddenKinds = hidden.reduce(into: Set<ChannelMessageKind>()) { $0.formUnion($1.kinds) }
            showsChat = visible.contains(.chat)
        } else {
            hiddenKinds = []
            showsChat = true
        }
        allowedSenders = try c.decodeIfPresent(Set<ChannelMessage.Sender>.self, forKey: .allowedSenders)
        allowedRecipients = try c.decodeIfPresent(Set<MessageRecipient>.self, forKey: .allowedRecipients)
        visibility = try c.decodeIfPresent(TranscriptFilter.Visibility.self, forKey: .visibility) ?? .all
        hideTaskScoped = try c.decodeIfPresent(Bool.self, forKey: .hideTaskScoped) ?? false
        showErrors = try c.decodeIfPresent(Bool.self, forKey: .showErrors) ?? true
    }

    /// Kind visibility is persisted as the HIDDEN set, not the visible one, so a kind added in a
    /// later build defaults to visible in every already-saved config. Storing the visible set had
    /// the opposite failure mode: a config saved with "everything on" silently excluded kind N+1
    /// the moment one existed, hiding a whole message category with nothing reporting it — which
    /// is exactly how `securityReviews` would have vanished from every existing session when it
    /// was a group. Raw values sorted so the persisted JSON is diff-stable.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hiddenKinds.map(\.rawValue).sorted(), forKey: .hiddenKinds)
        try c.encode(showsChat, forKey: .showsChat)
        try c.encodeIfPresent(allowedSenders, forKey: .allowedSenders)
        try c.encodeIfPresent(allowedRecipients, forKey: .allowedRecipients)
        try c.encode(visibility, forKey: .visibility)
        try c.encode(hideTaskScoped, forKey: .hideTaskScoped)
        try c.encode(showErrors, forKey: .showErrors)
    }

    /// The default bottom-pane view — the Smith↔user ORCHESTRATION conversation: nothing to OR from a
    /// worker (Brown), and nothing scoped to a specific task (that history lives in the top pane per
    /// task). Every kind group is on, but the task-scope + no-Brown filters carry the weight, so what
    /// remains is the user's conversation with Smith plus orchestration-level notices.
    public static let conversation = TranscriptViewConfig(
        allowedSenders: Set(selectableSenders.filter { $0 != .agent(.brown) }),
        allowedRecipients: Set(selectableRecipients.filter { $0 != .agent(.brown) }),
        hideTaskScoped: true
    )

    /// The unfiltered firehose — every group, sender, recipient; task-scoped included; errors shown.
    /// Equals `TranscriptFilter.all`.
    public static let everything = TranscriptViewConfig()

    /// The senders the popover offers as toggles, in display order. Validators post as the display-only
    /// `.validator` sender (never `.agent(.validator)`), so that is the case listed here.
    public static let selectableSenders: [ChannelMessage.Sender] = [
        .user, .agent(.smith), .agent(.brown), .agent(.securityAgent), .agent(.summarizer),
        .validator, .system
    ]

    /// The recipients the popover offers as toggles. Messages are addressed to `.user` or an `.agent`.
    public static let selectableRecipients: [MessageRecipient] = [
        .user, .agent(.smith), .agent(.brown), .agent(.securityAgent), .agent(.summarizer)
    ]

    /// The off-main `TranscriptFilter` this config represents. `taskScope`, when given, is an explicit
    /// override (a task-scoped pane); otherwise the config's `hideTaskScoped` switch decides. When
    /// nothing is hidden the kind axis collapses to `.all` (cheapest); otherwise it names exactly the
    /// visible kinds and passes kindless messages iff Chat is on.
    public func makeFilter(taskScope: TranscriptFilter.TaskScope? = nil) -> TranscriptFilter {
        let kinds: TranscriptFilter.KindRule
        if hiddenKinds.isEmpty && showsChat {
            kinds = .all
        } else {
            kinds = .only(Set(ChannelMessageKind.allCases).subtracting(hiddenKinds),
                          includingKindless: showsChat)
        }
        return TranscriptFilter(
            allowedSenders: allowedSenders,
            allowedRecipients: allowedRecipients,
            kinds: kinds,
            taskScope: taskScope ?? (hideTaskScoped ? .orchestration : .any),
            visibility: visibility,
            hideErrors: !showErrors
        )
    }
}
