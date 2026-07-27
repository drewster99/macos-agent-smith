import Foundation
import SwiftLLMKit

/// The `messageKind` discriminator carried in `ChannelMessage.metadata`.
///
/// Every channel message that means something structural — a tool call, a task lifecycle event,
/// a validation verdict — is tagged with one of these. Readers key display AND control flow off
/// the tag, so it is a contract between the site that posts a message and every site that
/// interprets one.
///
/// ## Why a RawRepresentable struct and not `enum Kind: String`
///
/// The obvious move is a closed `String`-backed enum. It is the wrong one here, for a reason
/// that is specific to this type rather than a general preference:
///
/// A closed enum's `init(rawValue:)` returns nil for anything it doesn't know. Kinds are
/// PERSISTED — every message in `channel_log.jsonl` carries its kind, and those logs are large
/// and long-lived. Any kind absent from the enum would decode as "no kind at all", and every
/// reader comparing against it would silently take the wrong branch on real historical data.
/// That failure is invisible: nothing throws, nothing logs, a row just quietly renders as
/// something else or a gate quietly stops matching.
///
/// And the enumeration genuinely cannot be trusted to be complete. This type was introduced
/// after a grep-derived list missed `taskLifecycle` (it lives in a `Set` that never mentions
/// `messageKind`), and after finding that `InspectorRecomputeCacheTests` — a test whose entire
/// stated purpose is to "pin down the messageKind string surface" — enumerated 18 kinds when
/// there were more than thirty. A design whose correctness depends on a grep being exhaustive
/// is a design that will be wrong again.
///
/// So: unknown values round-trip losslessly and compare by raw value, exactly as the bare
/// strings did, while every known kind gets a compile-checked static member. Nothing here is
/// switched over exhaustively — kinds are compared and set-tested — so a closed enum would have
/// bought no exhaustiveness guarantee to trade against that risk. This is the same shape Apple
/// uses for `Notification.Name` and `NSAttributedString.Key`, and for the same reason.
///
/// ## Adding a kind
///
/// Add a static member here and use it. Never write the raw string at a post or read site —
/// `ChannelMessageKindLiteralGuardTests` fails the build on new bare `"messageKind"` literals.
public struct ChannelMessageKind: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    // MARK: Tool calls
    /// A tool call being issued. Posted by workers, the Security Agent, and validators alike.
    public static let toolRequest = ChannelMessageKind(rawValue: "tool_request")
    /// The result of a tool call. Pairs with a `toolRequest` by `requestID`.
    public static let toolOutput = ChannelMessageKind(rawValue: "tool_output")

    // MARK: Task lifecycle
    public static let taskCreated = ChannelMessageKind(rawValue: "task_created")
    public static let taskAcknowledged = ChannelMessageKind(rawValue: "task_acknowledged")
    public static let taskContinuing = ChannelMessageKind(rawValue: "task_continuing")
    /// A worker submitting its work (`task_complete` the TOOL). Distinct from `taskCompleted`.
    public static let taskComplete = ChannelMessageKind(rawValue: "task_complete")
    /// A task reaching the completed STATE. Distinct from `taskComplete`.
    public static let taskCompleted = ChannelMessageKind(rawValue: "task_completed")
    public static let taskFailed = ChannelMessageKind(rawValue: "task_failed")
    public static let taskUpdate = ChannelMessageKind(rawValue: "task_update")
    public static let taskUpdateGuidance = ChannelMessageKind(rawValue: "task_update_guidance")
    public static let taskSummarized = ChannelMessageKind(rawValue: "task_summarized")
    public static let taskActionScheduled = ChannelMessageKind(rawValue: "task_action_scheduled")
    public static let taskQueuedAtCapacity = ChannelMessageKind(rawValue: "task_queued_at_capacity")
    /// Informational lifecycle chatter. Deliberately does NOT wake an idle agent.
    public static let taskLifecycle = ChannelMessageKind(rawValue: "task_lifecycle")
    public static let scheduledRunDeferred = ChannelMessageKind(rawValue: "scheduled_run_deferred")

    // MARK: Validation
    public static let changesRequested = ChannelMessageKind(rawValue: "changes_requested")
    public static let criteriaUpdated = ChannelMessageKind(rawValue: "criteria_updated")
    public static let validationReport = ChannelMessageKind(rawValue: "validation_report")
    public static let validationFailed = ChannelMessageKind(rawValue: "validation_failed")
    public static let validationEscalation = ChannelMessageKind(rawValue: "validation_escalation")
    public static let submissionAutoRejected = ChannelMessageKind(rawValue: "submission_auto_rejected")
    /// The PUBLIC banner announcing that validation is blocked on a missing Validator model.
    public static let validationBlocked = ChannelMessageKind(rawValue: "validation_blocked")
    /// The PRIVATE notice telling a worker its submission is parked for the same reason.
    ///
    /// Load-bearing for control flow: `AgentActor.resumesParkedWorker` exempts this kind, and it
    /// is the only private-to-worker message that must NOT pull a worker out of
    /// `awaitingTaskReview`. Everything else addressed to a worker means "here is work back".
    public static let validationBlockedWorkerNotice = ChannelMessageKind(rawValue: "validation_blocked_worker_notice")

    // MARK: Help
    public static let helpRequested = ChannelMessageKind(rawValue: "help_requested")
    public static let helpProvided = ChannelMessageKind(rawValue: "help_provided")

    // MARK: Memory
    public static let memorySaved = ChannelMessageKind(rawValue: "memory_saved")
    public static let memorySearched = ChannelMessageKind(rawValue: "memory_searched")

    // MARK: System / advisory
    public static let inboundUserMessage = ChannelMessageKind(rawValue: "inbound_user_message")
    public static let contextManagement = ChannelMessageKind(rawValue: "context_management")
    public static let timerActivity = ChannelMessageKind(rawValue: "timer_activity")
    public static let mcpStatus = ChannelMessageKind(rawValue: "mcp_status")
    public static let restartChrome = ChannelMessageKind(rawValue: "restart_chrome")
    public static let preparing = ChannelMessageKind(rawValue: "preparing")
}

extension ChannelMessageKind: CustomStringConvertible {
    public var description: String { rawValue }
}

public extension AnyCodable {
    /// Wraps a message kind for the `metadata["messageKind"]` slot, so a post site names the kind
    /// rather than spelling its wire string: `"messageKind": .kind(.toolRequest)`.
    static func kind(_ kind: ChannelMessageKind) -> AnyCodable {
        .string(kind.rawValue)
    }
}
