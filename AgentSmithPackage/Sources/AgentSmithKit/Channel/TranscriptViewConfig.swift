import Foundation

/// Groups every `ChannelMessageKind` into the activity categories the transcript filter exposes
/// ("tool calls", "memory", …). This is the authoritative grouping — `TranscriptViewConfigTests`
/// guards that every kind belongs to exactly ONE group, so a newly-added kind can never silently
/// vanish from the filter (it fails the build until it's grouped).
///
/// `chat` is special: it covers NO kind. It governs KINDLESS messages — plain user↔Smith
/// conversation and most notes, which carry no `messageKind` — via `governsKindless`.
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
        case .taskLifecycle: return "Task activity"
        case .validation: return "Validation"
        case .memory: return "Memory"
        case .system: return "System"
        }
    }

    /// One short line describing what the category contains.
    public var detail: String {
        switch self {
        case .chat: return "Conversation and notes"
        case .toolCalls: return "Tool requests and their output"
        case .securityReviews: return "Security Agent verdicts"
        case .taskLifecycle: return "Created, updated, completed, help"
        case .validation: return "Acceptance verdicts and escalations"
        case .memory: return "Memory saves and searches"
        case .system: return "Timers, context, agent and MCP status"
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
                    .taskQueuedAtCapacity, .taskLifecycle, .scheduledRunDeferred, .scheduledRunRefused,
                    .orchestratorMessage,
                    .taskAmendment, .userTaskAction, .helpRequested, .helpProvided, .taskInterrupted,
                    .taskWatchFired, .taskWatchRefused]
        case .validation:
            return [.changesRequested, .criteriaUpdated, .validationReport, .validationFailed,
                    .validationEscalation, .userAcceptanceRequested, .submissionAutoRejected, .validationBlocked,
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

    /// The group's filter targets, in a stable order (wire order clusters families like `task_*`) —
    /// except tool calls, where a request reads before the output it produced.
    public var targets: [TranscriptFilterTarget] {
        switch self {
        case .chat: return [.chat]
        case .toolCalls: return [.kind(.toolRequest), .kind(.toolOutput)]
        default: return kinds.sorted { $0.rawValue < $1.rawValue }.map(TranscriptFilterTarget.kind)
        }
    }
}

/// One thing a filter row can switch on or off: kindless chat, one message kind, or one tool's
/// request/output rows. Every row in the filter UI — a whole category, a single kind, a tool
/// family, a single tool — is a set of these, which is what lets one aggregate (`visibility`) and
/// one mutation (`setVisible`) serve every row at every level.
public enum TranscriptFilterTarget: Hashable, Sendable {
    case chat
    case kind(ChannelMessageKind)
    case tool(String)
}

/// One participant's answer to "which activity shows?" — hidden kinds, the kindless (chat) switch,
/// and hidden tools.
public struct TranscriptKindSelection: Sendable, Equatable {
    /// The kinds that are HIDDEN. Empty = every kind shows. Stored inverted so a kind added in a
    /// later build defaults to VISIBLE in every already-saved config, instead of silently vanishing.
    public var hiddenKinds: Set<ChannelMessageKind>
    /// Whether KINDLESS messages are shown. The per-kind set cannot express this (there is no kind
    /// to hide), so it is its own switch; the filter presents it as the "Chat" row.
    public var showsChat: Bool
    /// Tool names hidden. Empty = every tool shows. Hidden rather than shown so a tool this build has
    /// never seen — including any MCP tool — is VISIBLE in a config saved before it existed.
    public var hiddenToolNames: Set<String>

    public init(hiddenKinds: Set<ChannelMessageKind> = [], showsChat: Bool = true,
                hiddenToolNames: Set<String> = []) {
        self.hiddenKinds = hiddenKinds
        self.showsChat = showsChat
        self.hiddenToolNames = hiddenToolNames
    }

    /// The everything-shows selection — what a participant without an entry follows.
    public static let allVisible = TranscriptKindSelection()

    /// A visibility aggregated over several targets (and, in the config, several participants).
    public enum GroupVisibility: Sendable, Equatable {
        case all, none, mixed
    }

    public func isVisible(_ target: TranscriptFilterTarget) -> Bool {
        switch target {
        case .chat: return showsChat
        case .kind(let kind): return !hiddenKinds.contains(kind)
        case .tool(let name): return !hiddenToolNames.contains(name)
        }
    }

    public mutating func setVisible(_ visible: Bool, _ target: TranscriptFilterTarget) {
        switch target {
        case .chat:
            showsChat = visible
        case .kind(let kind):
            if visible { hiddenKinds.remove(kind) } else { hiddenKinds.insert(kind) }
        case .tool(let name):
            if visible { hiddenToolNames.remove(name) } else { hiddenToolNames.insert(name) }
        }
    }

    /// Tool-call rows are governed by the kinds first: with both tool kinds hidden there are no tool
    /// rows left to narrow, so the per-tool set is irrelevant and handing it to the filter is noise.
    public var effectiveHiddenToolNames: Set<String> {
        hiddenKinds.isSuperset(of: TranscriptKindGroup.toolCalls.kinds) ? [] : hiddenToolNames
    }

    /// This selection as a filter kind rule. Collapses to `.all` when nothing is hidden (cheapest).
    public var kindRule: TranscriptFilter.KindRule {
        if hiddenKinds.isEmpty && showsChat { return .all }
        return .only(Set(ChannelMessageKind.allCases).subtracting(hiddenKinds),
                     includingKindless: showsChat)
    }
}

/// How problems (warnings and errors) relate to every other filter in a pane. One choice rather than
/// the two controls it replaced — a "show errors" switch and a separate severity floor, whose
/// combinations (errors hidden yet "always shown") had no sensible reading.
public enum TranscriptProblemPolicy: String, CaseIterable, Sendable {
    /// Warnings and errors show even when their participant or activity is hidden. The default:
    /// a noise filter must never be a failure filter (2026-09-20, seven hidden `create_task` failures).
    case alwaysShowWarningsAndErrors
    /// Errors show regardless; warnings follow the other filters.
    case alwaysShowErrors
    /// Problems follow the other filters like any message.
    case filterNormally
    /// Errors are hidden in this pane, outright.
    case hideErrors

    public var displayName: String {
        switch self {
        case .alwaysShowWarningsAndErrors: return "Always show errors and warnings"
        case .alwaysShowErrors: return "Always show errors"
        case .filterNormally: return "Filter like other messages"
        case .hideErrors: return "Hide errors"
        }
    }

    /// What the choice means, in one sentence.
    public var explanation: String {
        switch self {
        case .alwaysShowWarningsAndErrors: return "Shown even when their participant or activity is hidden."
        case .alwaysShowErrors: return "Errors are shown even when hidden above; warnings follow the filters."
        case .filterNormally: return "Problems are shown or hidden like any other message."
        case .hideErrors: return "Errors never appear in this pane."
        }
    }

    /// The filter's severity floor.
    public var floor: MessageSeverity? {
        switch self {
        case .alwaysShowWarningsAndErrors: return .warning
        case .alwaysShowErrors: return .error
        case .filterNormally, .hideErrors: return nil
        }
    }

    public var hidesErrors: Bool { self == .hideErrors }
}

/// A persisted, user-editable description of what a transcript pane shows. Turned into an off-main
/// `TranscriptFilter` by `makeFilter`. Persisted per session in `SessionState` (one per pane).
///
/// The model is one relation — participant × activity — plus scope and the problem policy:
/// a message shows when it is in scope, involves no hidden participant, and its sender's
/// selection shows its activity; or when the problem policy says to show it anyway.
public struct TranscriptViewConfig: Codable, Sendable, Equatable {
    /// Participants hidden outright — messages from them and private messages to them.
    public var hiddenParticipants: Set<ChannelMessage.Sender>
    /// Per-participant activity selections. Sparse: a participant without an entry shows
    /// everything, and `setSelection` drops an entry that returns to `.allVisible`, so two configs
    /// that show the same thing are `==` (which is what preset matching relies on).
    public private(set) var selections: [ChannelMessage.Sender: TranscriptKindSelection]
    /// When true, only messages with NO associated task (the Smith↔user orchestration layer) show.
    /// Meaningful only in the session pane — the task pane is always scoped to its task.
    public var hideTaskScoped: Bool
    public var problems: TranscriptProblemPolicy

    public init(
        hiddenParticipants: Set<ChannelMessage.Sender> = [],
        selections: [ChannelMessage.Sender: TranscriptKindSelection] = [:],
        hideTaskScoped: Bool = false,
        problems: TranscriptProblemPolicy = .alwaysShowWarningsAndErrors
    ) {
        self.hiddenParticipants = hiddenParticipants
        self.selections = selections.filter { $0.value != .allVisible }
        self.hideTaskScoped = hideTaskScoped
        self.problems = problems
    }

    /// The participants the filter offers, in display order. Validators post as the display-only
    /// `.validator` sender (never `.agent(.validator)`), so that is the case listed here.
    public static let participants: [ChannelMessage.Sender] = [
        .user, .agent(.smith), .agent(.brown), .agent(.securityAgent), .agent(.summarizer),
        .validator, .system
    ]

    // MARK: Participant × activity

    public func selection(for participant: ChannelMessage.Sender) -> TranscriptKindSelection {
        selections[participant] ?? .allVisible
    }

    public mutating func setSelection(_ selection: TranscriptKindSelection, for participant: ChannelMessage.Sender) {
        selections[participant] = selection == .allVisible ? nil : selection
    }

    public func isParticipantShown(_ participant: ChannelMessage.Sender) -> Bool {
        !hiddenParticipants.contains(participant)
    }

    public mutating func setParticipant(_ participant: ChannelMessage.Sender, shown: Bool) {
        if shown { hiddenParticipants.remove(participant) } else { hiddenParticipants.insert(participant) }
    }

    /// How `targets` stand across `participants`: shown for all, none, or a mix. An empty product
    /// (no targets) reads as `.all` — there is nothing hidden.
    public func visibility(of targets: [TranscriptFilterTarget],
                           for participants: [ChannelMessage.Sender]) -> TranscriptKindSelection.GroupVisibility {
        var shown = 0
        var total = 0
        for participant in participants {
            let selection = selection(for: participant)
            for target in targets {
                total += 1
                if selection.isVisible(target) { shown += 1 }
            }
        }
        if shown == total { return .all }
        return shown == 0 ? .none : .mixed
    }

    /// Shows or hides every target for every listed participant — the one mutation behind every
    /// checkbox, whether it is a whole category for everyone or one tool for one participant.
    public mutating func setVisible(_ visible: Bool, targets: [TranscriptFilterTarget],
                                    for participants: [ChannelMessage.Sender]) {
        for participant in participants {
            var selection = selection(for: participant)
            for target in targets { selection.setVisible(visible, target) }
            setSelection(selection, for: participant)
        }
    }

    /// Whether every participant follows the same activity selection — the "Everyone" layout can
    /// represent this config without a single mixed row caused by participants disagreeing.
    public var isUniformAcrossParticipants: Bool {
        let first = selection(for: Self.participants[0])
        return Self.participants.allSatisfy { selection(for: $0) == first }
    }

    // MARK: Filter

    /// The off-main `TranscriptFilter` this config represents. `taskScope`, when given, is an explicit
    /// override (the task pane); otherwise `hideTaskScoped` decides.
    public func makeFilter(taskScope: TranscriptFilter.TaskScope? = nil) -> TranscriptFilter {
        TranscriptFilter(
            hiddenParticipants: hiddenParticipants,
            kindsBySender: selections.mapValues(\.kindRule),
            taskScope: taskScope ?? (hideTaskScoped ? .orchestration : .any),
            hideErrors: problems.hidesErrors,
            alwaysShowAtOrAbove: problems.floor,
            hiddenToolNamesBySender: selections.mapValues(\.effectiveHiddenToolNames)
        )
    }

    // MARK: Presets

    /// The session pane's default — the Smith↔user ORCHESTRATION conversation: nothing from or to a
    /// worker (Brown), nothing scoped to a specific task (the task pane shows that), and none of the
    /// tool or security-review plumbing.
    ///
    /// ## Why tool calls and security reviews are off (audited 2026-09-20)
    ///
    /// The task scope does not catch them: Smith's tool rows carry no `taskID`. Measured on one real
    /// session, what survived the scope alone was 25% `tool_request`, 23% `tool_output`, 25%
    /// `security_review` against 12% conversation. Hiding them is safe ONLY because of the problem
    /// policy: a failed call or a WARN/UNSAFE verdict still comes through. Do not turn these back on
    /// to "make errors visible" — that is the problem policy's job.
    public static let conversation: TranscriptViewConfig = {
        var config = TranscriptViewConfig(hiddenParticipants: [.agent(.brown)], hideTaskScoped: true)
        config.setVisible(false, targets: TranscriptKindGroup.toolCalls.targets, for: participants)
        config.setVisible(false, targets: TranscriptKindGroup.securityReviews.targets, for: participants)
        return config
    }()

    /// The unfiltered firehose — everything in scope shows.
    public static let everything = TranscriptViewConfig()

    /// Everything except bulk: tool output and security reviews are hidden, tool REQUESTS stay —
    /// you see each step the worker took without the wall of output under it.
    public static let condensed: TranscriptViewConfig = {
        var config = TranscriptViewConfig()
        config.setVisible(false, targets: [.kind(.toolOutput)], for: participants)
        config.setVisible(false, targets: TranscriptKindGroup.securityReviews.targets, for: participants)
        return config
    }()

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        // Current generation.
        case hiddenParticipants, participantSelections, hideTaskScoped, problems
        // Legacy generations, read for migration only.
        case hiddenKinds, showsChat, hiddenToolNames, senderKindOverrides, visibleGroups,
             hiddenGroups, allowedSenders, allowedRecipients, visibility, showErrors,
             alwaysShowAtOrAbove
    }

    /// One persisted participant selection. An ARRAY of these (sorted) rather than a dictionary,
    /// because Swift encodes a non-String-keyed dictionary in iteration order — nondeterministic, so
    /// every save would churn the JSON.
    private struct ParticipantSelectionRow: Codable {
        let participant: ChannelMessage.Sender
        let hiddenKinds: [String]
        let showsChat: Bool
        var hiddenToolNames: [String]?
    }

    /// A per-sender override row as the previous generation wrote it.
    private struct LegacySenderOverrideRow: Decodable {
        let sender: ChannelMessage.Sender
        let hiddenKinds: [String]
        let showsChat: Bool
        var hiddenToolNames: [String]?
    }

    /// Reads the current generation, or migrates any earlier one. Every unknown value — a kind,
    /// sender, or policy written by a NEWER build — is dropped alone and fails OPEN (that thing
    /// shows), instead of throwing and taking the whole `SessionState` decode down with it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.contains(.problems) else {
            self = try Self.migrateLegacy(from: c)
            return
        }
        var decodedSelections: [ChannelMessage.Sender: TranscriptKindSelection] = [:]
        for row in Self.decodeLenientArray(ParticipantSelectionRow.self, from: c, forKey: .participantSelections) {
            decodedSelections[row.participant] = Self.selection(
                hiddenKinds: row.hiddenKinds, showsChat: row.showsChat, hiddenTools: row.hiddenToolNames)
        }
        // Through the memberwise init so the sparse-map normalization has one home.
        self.init(
            hiddenParticipants: Self.decodeLenientSet(ChannelMessage.Sender.self, from: c, forKey: .hiddenParticipants) ?? [],
            selections: decodedSelections,
            hideTaskScoped: try c.decodeIfPresent(Bool.self, forKey: .hideTaskScoped) ?? false,
            // An unknown policy from a newer build falls back to the widest — fails toward visible.
            problems: (try? c.decodeIfPresent(String.self, forKey: .problems))
                .flatMap(TranscriptProblemPolicy.init(rawValue:)) ?? .alwaysShowWarningsAndErrors
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hiddenParticipants.sorted { Self.sortKey($0) < Self.sortKey($1) }, forKey: .hiddenParticipants)
        let rows = selections
            .map { participant, selection in
                ParticipantSelectionRow(
                    participant: participant,
                    hiddenKinds: selection.hiddenKinds.map(\.rawValue).sorted(),
                    showsChat: selection.showsChat,
                    hiddenToolNames: selection.hiddenToolNames.isEmpty ? nil : selection.hiddenToolNames.sorted())
            }
            .sorted { Self.sortKey($0.participant) < Self.sortKey($1.participant) }
        try c.encode(rows, forKey: .participantSelections)
        try c.encode(hideTaskScoped, forKey: .hideTaskScoped)
        try c.encode(problems.rawValue, forKey: .problems)
    }

    /// Migrates every earlier generation: a default kind selection (flat keys, or one of two
    /// group-level forms before that) plus sparse per-sender overrides, sender and recipient
    /// allow-lists, a public/private switch, and a separate errors switch and severity floor.
    ///
    /// - Each participant gets its override if it had one, else the old default — so what each
    ///   sender showed is preserved exactly.
    /// - A participant is hidden iff the old sender allow-list excluded it. A recipient-only
    ///   exclusion has no equivalent and fails open.
    /// - Public/private is dropped (fails open); no saved config ever narrowed it.
    private static func migrateLegacy(from c: KeyedDecodingContainer<CodingKeys>) throws -> TranscriptViewConfig {
        var config = TranscriptViewConfig()
        let defaultSelection = try legacyDefaultSelection(from: c)
        var overrides: [ChannelMessage.Sender: TranscriptKindSelection] = [:]
        for row in decodeLenientArray(LegacySenderOverrideRow.self, from: c, forKey: .senderKindOverrides) {
            overrides[row.sender] = selection(hiddenKinds: row.hiddenKinds, showsChat: row.showsChat,
                                              hiddenTools: row.hiddenToolNames)
        }
        for participant in participants {
            config.setSelection(overrides[participant] ?? defaultSelection, for: participant)
        }
        if let allowed = decodeLenientSet(ChannelMessage.Sender.self, from: c, forKey: .allowedSenders) {
            config.hiddenParticipants = Set(participants.filter { !allowed.contains($0) })
        }
        config.hideTaskScoped = try c.decodeIfPresent(Bool.self, forKey: .hideTaskScoped) ?? false
        config.problems = try legacyProblemPolicy(from: c)
        return config
    }

    private static func legacyDefaultSelection(from c: KeyedDecodingContainer<CodingKeys>) throws -> TranscriptKindSelection {
        let hiddenTools = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenToolNames) ?? []
        if let hiddenNames = try c.decodeIfPresent([String].self, forKey: .hiddenKinds) {
            return selection(hiddenKinds: hiddenNames,
                             showsChat: try c.decodeIfPresent(Bool.self, forKey: .showsChat) ?? true,
                             hiddenTools: Array(hiddenTools))
        }
        if let hiddenGroupNames = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenGroups) {
            // The group-persisted generation: a hidden group's kinds ARE what that config hid.
            let hidden = Set(hiddenGroupNames.compactMap(TranscriptKindGroup.init(rawValue:)))
            return TranscriptKindSelection(
                hiddenKinds: hidden.reduce(into: Set<ChannelMessageKind>()) { $0.formUnion($1.kinds) },
                showsChat: !hidden.contains(.chat))
        }
        if let legacyVisibleNames = try c.decodeIfPresent(Set<String>.self, forKey: .visibleGroups) {
            // The VISIBLE-group generation, which predates `securityReviews`: those rows were
            // kindless then, so the Chat toggle governed them — inheriting Chat's state preserves
            // exactly what this config showed.
            let legacyVisible = Set(legacyVisibleNames.compactMap(TranscriptKindGroup.init(rawValue:)))
            let visible = legacyVisible.contains(.chat) ? legacyVisible.union([.securityReviews]) : legacyVisible
            let hidden = Set(TranscriptKindGroup.allCases).subtracting(visible)
            return TranscriptKindSelection(
                hiddenKinds: hidden.reduce(into: Set<ChannelMessageKind>()) { $0.formUnion($1.kinds) },
                showsChat: visible.contains(.chat))
        }
        return .allVisible
    }

    /// An ABSENT floor key and an explicit NULL meant opposite things: absent = written before the
    /// floor existed (exactly the configs that were hiding failures, so they adopt the default);
    /// null = the user turned the floor off.
    private static func legacyProblemPolicy(from c: KeyedDecodingContainer<CodingKeys>) throws -> TranscriptProblemPolicy {
        if try c.decodeIfPresent(Bool.self, forKey: .showErrors) == false { return .hideErrors }
        guard c.contains(.alwaysShowAtOrAbove) else { return .alwaysShowWarningsAndErrors }
        switch try c.decodeIfPresent(MessageSeverity.self, forKey: .alwaysShowAtOrAbove) {
        case .none: return .filterNormally
        case .error: return .alwaysShowErrors
        // `.info` was never offered; it showed everything, so the widest policy is the closest.
        case .warning, .info: return .alwaysShowWarningsAndErrors
        }
    }

    /// A selection from persisted raw names. Raw strings, so a kind written by a newer build is
    /// ignored (that kind shows) instead of throwing.
    private static func selection(hiddenKinds: [String], showsChat: Bool, hiddenTools: [String]?) -> TranscriptKindSelection {
        TranscriptKindSelection(
            hiddenKinds: Set(hiddenKinds.compactMap(ChannelMessageKind.init(rawValue:))),
            showsChat: showsChat,
            hiddenToolNames: Set(hiddenTools ?? []))
    }

    private static func sortKey(_ sender: ChannelMessage.Sender) -> String {
        String(describing: sender)
    }

    /// Decodes an array one element at a time, dropping any element this build can't represent.
    private static func decodeLenientArray<Element: Decodable>(
        _ type: Element.Type,
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> [Element] {
        guard var elements = try? container.nestedUnkeyedContainer(forKey: key) else { return [] }
        var decoded: [Element] = []
        while !elements.isAtEnd {
            if let element = try? elements.decode(Element.self) {
                decoded.append(element)
            } else {
                // A failed `decode` does not advance the container; skip the bad element
                // explicitly or the loop never terminates.
                _ = try? elements.decode(AnyDecodableBlob.self)
            }
        }
        return decoded
    }

    /// Decodes a set leniently. Returns nil when the key is absent or null, or when a NON-EMPTY
    /// stored array lost every member: a list this build can't honor at all fails open.
    private static func decodeLenientSet<Element: Decodable & Hashable>(
        _ type: Element.Type,
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Set<Element>? {
        guard (try? container.nestedUnkeyedContainer(forKey: key)) != nil else { return nil }
        let rawCount = (try? container.nestedUnkeyedContainer(forKey: key))?.count ?? 0
        let decoded = Set(decodeLenientArray(type, from: container, forKey: key))
        return rawCount > 0 && decoded.isEmpty ? nil : decoded
    }

    /// Swallows one arbitrary JSON value — the skip vehicle for a lenient unkeyed decode.
    private struct AnyDecodableBlob: Decodable {
        init(from decoder: Decoder) throws {
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
}
