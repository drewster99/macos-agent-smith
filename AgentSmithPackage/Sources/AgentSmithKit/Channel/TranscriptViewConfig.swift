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

/// One scope's answer to "which message kinds show?" — a hidden-kind set plus the kindless (chat)
/// switch, with the group conveniences the popover's checklist edits. `TranscriptViewConfig` holds
/// one of these as the DEFAULT and a sparse per-sender override map, so the same checklist UI can
/// edit any scope.
public struct TranscriptKindSelection: Codable, Sendable, Equatable {
    /// The kinds that are HIDDEN — the single source of truth for this scope's kind axis. Empty =
    /// every kind shows. Stored inverted for the same reason the group set was: a kind added in a
    /// later build defaults to VISIBLE in every already-saved config, instead of silently
    /// vanishing. `TranscriptKindGroup` is a UI convenience layered over this set (see
    /// `groupVisibility(of:)`), never a second source of truth.
    public var hiddenKinds: Set<ChannelMessageKind>
    /// Whether KINDLESS messages — plain user↔Smith conversation, which carry no `messageKind` —
    /// are shown. The per-kind set cannot express this (there is no kind to hide), so it is its
    /// own switch; the popover presents it as the "Chat" row.
    public var showsChat: Bool

    public init(hiddenKinds: Set<ChannelMessageKind> = [], showsChat: Bool = true) {
        self.hiddenKinds = hiddenKinds
        self.showsChat = showsChat
    }

    /// The everything-shows selection — the default scope's starting state, and the base a
    /// per-sender override is copied from when none exists yet.
    public static let allVisible = TranscriptKindSelection()

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

    /// This selection as a filter kind rule. Collapses to `.all` when nothing is hidden (cheapest).
    public var kindRule: TranscriptFilter.KindRule {
        if hiddenKinds.isEmpty && showsChat { return .all }
        return .only(Set(ChannelMessageKind.allCases).subtracting(hiddenKinds),
                     includingKindless: showsChat)
    }
}

/// A persisted, user-editable description of what the bottom transcript pane shows: which message
/// kinds are visible (every `ChannelMessageKind` individually, per sender when wanted), which
/// senders, and public/private. Turned into an off-main `TranscriptFilter` by `makeFilter`.
/// Persisted per session in `SessionState.transcriptViewConfig`.
public struct TranscriptViewConfig: Codable, Sendable, Equatable {
    /// The kind selection for every sender that has no entry in `senderKindOverrides` — the "All
    /// senders" scope in the popover.
    public var defaultKinds: TranscriptKindSelection
    /// Sparse per-sender kind selections. A sender with an entry uses IT instead of `defaultKinds`;
    /// a sender without one follows the default — including senders added in later builds, which is
    /// why this is an override map and not a per-sender matrix with a row for everyone. Kept sparse
    /// on disk too, so "hide X everywhere" stays one edit to the default, not seven copies.
    public var senderKindOverrides: [ChannelMessage.Sender: TranscriptKindSelection]
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
        defaultKinds: TranscriptKindSelection = .allVisible,
        senderKindOverrides: [ChannelMessage.Sender: TranscriptKindSelection] = [:],
        allowedSenders: Set<ChannelMessage.Sender>? = nil,
        allowedRecipients: Set<MessageRecipient>? = nil,
        visibility: TranscriptFilter.Visibility = .all,
        hideTaskScoped: Bool = false,
        showErrors: Bool = true
    ) {
        self.defaultKinds = defaultKinds
        self.senderKindOverrides = senderKindOverrides
        self.allowedSenders = allowedSenders
        self.allowedRecipients = allowedRecipients
        self.visibility = visibility
        self.hideTaskScoped = hideTaskScoped
        self.showErrors = showErrors
    }

    // MARK: Scope accessors (the popover's surface)

    /// The selection governing `sender` — its override, or the default when it has none.
    /// `nil` asks for the default scope itself.
    public func kindSelection(forSender sender: ChannelMessage.Sender?) -> TranscriptKindSelection {
        guard let sender else { return defaultKinds }
        return senderKindOverrides[sender] ?? defaultKinds
    }

    /// Writes a scope's selection. `nil` = the default scope; a sender writes (or creates) its
    /// override — use `removeKindOverride` to return a sender to following the default.
    public mutating func setKindSelection(_ selection: TranscriptKindSelection,
                                          forSender sender: ChannelMessage.Sender?) {
        if let sender {
            senderKindOverrides[sender] = selection
        } else {
            defaultKinds = selection
        }
    }

    public func hasKindOverride(forSender sender: ChannelMessage.Sender) -> Bool {
        senderKindOverrides[sender] != nil
    }

    public mutating func removeKindOverride(forSender sender: ChannelMessage.Sender) {
        senderKindOverrides[sender] = nil
    }

    private enum CodingKeys: String, CodingKey {
        case hiddenKinds, showsChat, senderKindOverrides, visibleGroups, hiddenGroups,
             allowedSenders, allowedRecipients, visibility, hideTaskScoped, showErrors
    }

    /// One persisted per-sender override row. An ARRAY of these (sorted by sender description)
    /// rather than a dictionary, because Swift encodes a non-String-keyed dictionary as a flat
    /// key/value array in ITERATION order — nondeterministic, so every save would churn the JSON.
    private struct SenderKindOverrideRow: Codable {
        let sender: ChannelMessage.Sender
        let hiddenKinds: [String]
        let showsChat: Bool
    }

    /// Custom decode, for two reasons. (1) A config persisted BEFORE the recipient / task-scope / error
    /// axes existed still reads back — the synthesized decoder emits a hard `decode` for every
    /// non-optional key and would throw `keyNotFound` on the missing ones, taking the whole
    /// `SessionState` decode down with it. Each field falls back to the same default as the memberwise
    /// init. (2) Kind visibility is stored INVERTED, as `hiddenKinds` — see `encode(to:)` — and two
    /// generations of GROUP-level persistence migrate here by expanding each hidden group to its kinds:
    /// the group's kinds ARE what that config hid, so the expansion shows exactly what it showed.
    /// Group-generation configs predate per-sender selection, so they migrate to the DEFAULT scope
    /// with no overrides.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let hiddenNames = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenKinds) {
            // Decoded as raw strings, not `Set<ChannelMessageKind>`, so a kind written by a NEWER
            // build doesn't throw here. Ignoring an unknown hidden name fails open — that kind's
            // messages show — which beats failing the whole `SessionState` decode.
            defaultKinds = TranscriptKindSelection(
                hiddenKinds: Set(hiddenNames.compactMap(ChannelMessageKind.init(rawValue:))),
                showsChat: try c.decodeIfPresent(Bool.self, forKey: .showsChat) ?? true)
        } else if let hiddenGroupNames = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenGroups) {
            // The group-persisted generation (same inverted philosophy, coarser grain).
            let hidden = Set(hiddenGroupNames.compactMap(TranscriptKindGroup.init(rawValue:)))
            defaultKinds = TranscriptKindSelection(
                hiddenKinds: hidden.reduce(into: Set<ChannelMessageKind>()) { $0.formUnion($1.kinds) },
                showsChat: !hidden.contains(.chat))
        } else if let legacyVisible = try c.decodeIfPresent(Set<TranscriptKindGroup>.self, forKey: .visibleGroups) {
            // Written by a build that stored the VISIBLE group set and predates `securityReviews`.
            // Security-review rows were kindless then, so the Chat toggle governed them —
            // inheriting Chat's state preserves exactly what this config showed before the upgrade.
            let visible = legacyVisible.contains(.chat)
                ? legacyVisible.union([.securityReviews])
                : legacyVisible
            let hidden = Set(TranscriptKindGroup.allCases).subtracting(visible)
            defaultKinds = TranscriptKindSelection(
                hiddenKinds: hidden.reduce(into: Set<ChannelMessageKind>()) { $0.formUnion($1.kinds) },
                showsChat: visible.contains(.chat))
        } else {
            defaultKinds = .allVisible
        }
        // Per-row lenient: a row whose sender was written by a NEWER build fails ITS decode and is
        // dropped (that sender follows the default — fails open), instead of failing the config.
        if var rows = try? c.nestedUnkeyedContainer(forKey: .senderKindOverrides) {
            var overrides: [ChannelMessage.Sender: TranscriptKindSelection] = [:]
            while !rows.isAtEnd {
                guard let row = try? rows.decode(SenderKindOverrideRow.self) else {
                    // A failed `decode` does not advance the container; skip the bad row explicitly
                    // or every later (valid) row is lost behind it.
                    _ = try? rows.decode(AnyDecodableBlob.self)
                    continue
                }
                overrides[row.sender] = TranscriptKindSelection(
                    hiddenKinds: Set(row.hiddenKinds.compactMap(ChannelMessageKind.init(rawValue:))),
                    showsChat: row.showsChat)
            }
            senderKindOverrides = overrides
        } else {
            senderKindOverrides = [:]
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
    /// was a group. Raw values sorted, and override rows sorted by sender, so the persisted JSON
    /// is diff-stable. The default scope keeps the FLAT `hiddenKinds`/`showsChat` keys the
    /// previous generation wrote, so a no-override config round-trips byte-identically with it.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(defaultKinds.hiddenKinds.map(\.rawValue).sorted(), forKey: .hiddenKinds)
        try c.encode(defaultKinds.showsChat, forKey: .showsChat)
        if !senderKindOverrides.isEmpty {
            let rows = senderKindOverrides
                .map { sender, selection in
                    SenderKindOverrideRow(sender: sender,
                                          hiddenKinds: selection.hiddenKinds.map(\.rawValue).sorted(),
                                          showsChat: selection.showsChat)
                }
                .sorted { String(describing: $0.sender) < String(describing: $1.sender) }
            try c.encode(rows, forKey: .senderKindOverrides)
        }
        try c.encodeIfPresent(allowedSenders, forKey: .allowedSenders)
        try c.encodeIfPresent(allowedRecipients, forKey: .allowedRecipients)
        try c.encode(visibility, forKey: .visibility)
        try c.encode(hideTaskScoped, forKey: .hideTaskScoped)
        try c.encode(showErrors, forKey: .showErrors)
    }

    /// Swallows one arbitrary JSON value — the skip vehicle for a lenient unkeyed decode.
    private struct AnyDecodableBlob: Decodable {
        init(from decoder: Decoder) throws {
            // Try every JSON shape; single values last. `Never` decode of a keyed container
            // isn't available, so probe cheapest-first and accept whichever matches.
            let single = try? decoder.singleValueContainer()
            if let single {
                if single.decodeNil() { return }
                if (try? single.decode(Bool.self)) != nil { return }
                if (try? single.decode(Double.self)) != nil { return }
                if (try? single.decode(String.self)) != nil { return }
            }
            if (try? decoder.container(keyedBy: RawKey.self)) != nil { return }
            _ = try? decoder.unkeyedContainer()
        }
        private struct RawKey: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }
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
    /// override (a task-scoped pane); otherwise the config's `hideTaskScoped` switch decides. Each
    /// scope's selection collapses to `.all` when it hides nothing (cheapest); a sender override that
    /// EQUALS the default is still emitted as that sender's rule — harmless, and dropping it here
    /// would make `makeFilter` disagree with what the popover shows as customized.
    public func makeFilter(taskScope: TranscriptFilter.TaskScope? = nil) -> TranscriptFilter {
        TranscriptFilter(
            allowedSenders: allowedSenders,
            allowedRecipients: allowedRecipients,
            kinds: defaultKinds.kindRule,
            kindsBySender: senderKindOverrides.mapValues(\.kindRule),
            taskScope: taskScope ?? (hideTaskScoped ? .orchestration : .any),
            visibility: visibility,
            hideErrors: !showErrors
        )
    }
}
