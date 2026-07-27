import Foundation
import SwiftLLMKit

/// The `messageKind` discriminator carried in `ChannelMessage.metadata`.
///
/// Every channel message that means something structural — a tool call, a task lifecycle event,
/// a validation verdict — is tagged with one of these. Readers key display AND control flow off
/// the tag, so it is a contract between the site that posts a message and every site that
/// interprets one. Never write or compare the raw string; use a case.
///
/// ## Completeness is a correctness requirement
///
/// This is a closed enum, so `init(rawValue:)` returns nil for anything not listed here, and a
/// missing case makes `ChannelMessage.kind` nil — every reader comparing against it would then
/// silently take the wrong branch. Kinds are PERSISTED in `channel_log.jsonl`, so the set that
/// matters is not "what the current code emits" but "what has ever been written to disk".
///
/// Those are different sets, and the gap is not small. Deriving the list by grepping the sources
/// — the obvious approach, and what a prior test did — misses:
///
/// - kinds referenced in collections that never mention `messageKind` (`taskLifecycle` lives in
///   a `Set` literal), and
/// - RETIRED kinds, which no longer appear in any source file but are still sitting in the logs
///   in quantity. `agentOnline` alone occurs about 4,000 times.
///
/// So this list was built by scanning the actual persisted corpus (~520 MB of `channel_log.jsonl`
/// / `.json` / `.old` plus the backup and removed-session directories) on 2026-07-27, unioned
/// with the kinds the current sources emit. `ChannelMessageKindTests` pins both halves.
///
/// ## Adding a kind
///
/// Add a case here and use it. Never write the raw string at a post or read site — the guard
/// tests in `ChannelMessageKindTests` fail the build on new bare `messageKind` literals.
///
/// ## Removing a kind
///
/// Don't. Retiring a kind from the code does NOT retire it from the logs. Move its case under
/// the "Retired" section instead, so historical messages keep decoding.
public enum ChannelMessageKind: String, Codable, Sendable, Hashable, CaseIterable {

    // MARK: Tool calls
    /// A tool call being issued. Posted by workers, the Security Agent, and validators alike.
    case toolRequest = "tool_request"
    /// The result of a tool call. Pairs with a `toolRequest` by `requestID`.
    case toolOutput = "tool_output"

    // MARK: Task lifecycle
    case taskCreated = "task_created"
    case taskAcknowledged = "task_acknowledged"
    case taskContinuing = "task_continuing"
    /// A worker submitting its work (`task_complete` the TOOL). Distinct from `taskCompleted`.
    case taskComplete = "task_complete"
    /// A task reaching the completed STATE. Distinct from `taskComplete`.
    case taskCompleted = "task_completed"
    case taskFailed = "task_failed"
    case taskUpdate = "task_update"
    case taskUpdateGuidance = "task_update_guidance"
    case taskSummarized = "task_summarized"
    case taskActionScheduled = "task_action_scheduled"
    case taskQueuedAtCapacity = "task_queued_at_capacity"
    /// Informational lifecycle chatter. Deliberately does NOT wake an idle agent.
    case taskLifecycle = "task_lifecycle"
    case scheduledRunDeferred = "scheduled_run_deferred"

    // MARK: Validation
    case changesRequested = "changes_requested"
    case criteriaUpdated = "criteria_updated"
    case validationReport = "validation_report"
    case validationFailed = "validation_failed"
    case validationEscalation = "validation_escalation"
    case submissionAutoRejected = "submission_auto_rejected"
    /// The PUBLIC banner announcing that validation is blocked on a missing Validator model.
    case validationBlocked = "validation_blocked"
    /// The PRIVATE notice telling a worker its submission is parked for the same reason.
    ///
    /// Load-bearing for control flow: `AgentActor.resumesParkedWorker` exempts this kind, and it
    /// is the only private-to-worker message that must NOT pull a worker out of
    /// `awaitingTaskReview`. Everything else addressed to a worker means "here is work back".
    case validationBlockedWorkerNotice = "validation_blocked_worker_notice"

    // MARK: Help
    case helpRequested = "help_requested"
    case helpProvided = "help_provided"

    // MARK: Memory
    case memorySaved = "memory_saved"
    case memorySearched = "memory_searched"

    // MARK: System / advisory
    case inboundUserMessage = "inbound_user_message"
    case contextManagement = "context_management"
    case timerActivity = "timer_activity"
    case mcpStatus = "mcp_status"
    case restartChrome = "restart_chrome"
    case preparing = "preparing"

    // MARK: Retired
    //
    // No longer emitted by any source file, but present in persisted logs — in the case of
    // `agentOnline`, thousands of times. These cases exist so historical messages still decode
    // to a kind rather than to nil. Do not delete them; the logs outlive the code that wrote them.

    /// Agent-startup announcement from an older build.
    case agentOnline = "agent_online"
    /// Predecessor of the current validation park notices.
    case validationWaitNotice = "validation_wait_notice"
    /// Recorded a user overriding a validation verdict, before the current escalation actions.
    case validationOverride = "validation_override"
    /// Task interruption notice from an older lifecycle model.
    case taskInterrupted = "task_interrupted"
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
