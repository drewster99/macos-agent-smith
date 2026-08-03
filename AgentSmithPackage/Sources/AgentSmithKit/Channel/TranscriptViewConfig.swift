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
    case taskLifecycle
    case validation
    case memory
    case system

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .chat: return "Chat"
        case .toolCalls: return "Tool calls"
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
        case .taskLifecycle: return "Task created / updated / completed, help, worker messages"
        case .validation: return "Acceptance-criteria verdicts and escalations"
        case .memory: return "Memory saves and searches"
        case .system: return "Timers, context management, MCP status, advisories"
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
        case .taskLifecycle:
            return [.taskCreated, .taskAcknowledged, .taskContinuing, .taskComplete, .taskCompleted,
                    .taskFailed, .taskUpdate, .taskUpdateGuidance, .taskSummarized, .taskActionScheduled,
                    .taskQueuedAtCapacity, .taskLifecycle, .scheduledRunDeferred, .orchestratorMessage,
                    .helpRequested, .helpProvided, .taskInterrupted]
        case .validation:
            return [.changesRequested, .criteriaUpdated, .validationReport, .validationFailed,
                    .validationEscalation, .submissionAutoRejected, .validationBlocked,
                    .validationBlockedWorkerNotice, .validationWaitNotice, .validationOverride]
        case .memory:
            return [.memorySaved, .memorySearched]
        case .system:
            return [.inboundUserMessage, .contextManagement, .timerActivity, .mcpStatus,
                    .restartChrome, .preparing, .agentOnline]
        }
    }

    /// Whether this group governs kindless (plain-chat) messages. Only `.chat` does.
    public var governsKindless: Bool { self == .chat }
}

/// A persisted, user-editable description of what the bottom transcript pane shows: which kind-groups
/// are visible, which senders, and public/private. Turned into an off-main `TranscriptFilter` by
/// `makeFilter`. Persisted per session in `SessionState.transcriptViewConfig`.
public struct TranscriptViewConfig: Codable, Sendable, Equatable {
    /// Which kind-groups are visible. A group absent from this set is hidden.
    public var visibleGroups: Set<TranscriptKindGroup>
    /// Which senders are shown. `nil` = every sender (the common case); a non-nil set is an allow-list.
    public var allowedSenders: Set<ChannelMessage.Sender>?
    /// Public / private / all.
    public var visibility: TranscriptFilter.Visibility

    public init(
        visibleGroups: Set<TranscriptKindGroup> = Set(TranscriptKindGroup.allCases),
        allowedSenders: Set<ChannelMessage.Sender>? = nil,
        visibility: TranscriptFilter.Visibility = .all
    ) {
        self.visibleGroups = visibleGroups
        self.allowedSenders = allowedSenders
        self.visibility = visibility
    }

    /// The default bottom-pane view — the readable conversation. Chat + task lifecycle + validation +
    /// system are on; the raw tool-call stream and memory bookkeeping (the noisy groups) are off. Every
    /// sender, both visibilities. The user narrows or widens from here.
    public static let conversation = TranscriptViewConfig(
        visibleGroups: [.chat, .taskLifecycle, .validation, .system]
    )

    /// The unfiltered firehose — every group, every sender, both visibilities. Equals `TranscriptFilter.all`.
    public static let everything = TranscriptViewConfig()

    /// The senders the popover offers as toggles, in display order. Validators post as the display-only
    /// `.validator` sender (never `.agent(.validator)`), so that is the case listed here.
    public static let selectableSenders: [ChannelMessage.Sender] = [
        .user, .agent(.smith), .agent(.brown), .agent(.securityAgent), .agent(.summarizer),
        .validator, .system
    ]

    /// The off-main `TranscriptFilter` this config represents, scoped to `taskScope`. When every group
    /// is visible the kind axis collapses to `.all` (cheapest predicate); otherwise it names exactly the
    /// visible groups' kinds and passes kindless messages iff Chat is on.
    public func makeFilter(taskScope: TranscriptFilter.TaskScope = .any) -> TranscriptFilter {
        let kinds: TranscriptFilter.KindRule
        if visibleGroups == Set(TranscriptKindGroup.allCases) {
            kinds = .all
        } else {
            let named = visibleGroups.reduce(into: Set<ChannelMessageKind>()) { $0.formUnion($1.kinds) }
            kinds = .only(named, includingKindless: visibleGroups.contains(.chat))
        }
        return TranscriptFilter(
            allowedSenders: allowedSenders,
            kinds: kinds,
            taskScope: taskScope,
            visibility: visibility
        )
    }
}
