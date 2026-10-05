import Foundation
import SwiftLLMKit

/// Why an LLM caller is sleeping before its next attempt. Derived from the TYPED failure
/// (status code, the Codex limit discriminator, the kit's memory-exhaustion code, the URL error
/// domain) by `LLMRetryPolicy.waitReason(for:)` — never from error prose.
public enum ProviderWaitReason: String, Sendable, Equatable, CaseIterable {
    /// A subscription usage window is spent and the provider said when it reopens (Codex
    /// `usage_limit_reached`). Typically hours or days.
    case usageLimitReached = "usage_limit_reached"
    /// HTTP 429 — an ordinary throttle, or a quota the provider did not name.
    case rateLimited = "rate_limited"
    /// The server stated a delay on a non-429 response (a 503/408 with Retry-After).
    case serverRequestedDelay = "server_requested_delay"
    /// The server refused for lack of memory (its own typed error code).
    case serverOutOfMemory = "server_out_of_memory"
    /// HTTP 5xx with no stated delay.
    case serverError = "server_error"
    /// The request never got an HTTP answer (timeout, connection reset, DNS).
    case networkError = "network_error"
    /// Any other failure the retry policy classifies as transient.
    case transientError = "transient_error"
}

/// What the waiting caller was doing. The inspector names the wait by this, and it is what ties a
/// security review's wait to the worker whose tool call it is holding.
public enum ProviderWaitPurpose: Sendable, Hashable {
    /// An agent's own LLM turn (Smith, a Brown).
    case agentTurn
    /// A Security Agent review of one tool call, made on behalf of `reviewedAgentID`.
    case securityReview(toolName: String, reviewedAgentID: UUID?)
    /// A Security Agent tool-scoping pass at task start.
    case toolScoping
    /// A validator judging one acceptance criterion.
    case criterionValidation
    /// The summarizer writing a finished task's summary.
    case taskSummary
    /// The summarizer reconciling a memory against an existing one.
    case memoryReconciliation
    /// The summarizer extracting an answer from fetched web content.
    case webContentExtraction
}

/// Who is waiting.
public struct ProviderWaitHolder: Sendable, Hashable {
    /// The role whose model is being called — the role a model switch for that role wakes.
    public let role: AgentRole
    /// The live agent instance that is waiting, for an agent turn. Nil for evaluations.
    public let agentID: UUID?
    public let taskID: UUID?
    public let purpose: ProviderWaitPurpose

    public init(role: AgentRole, agentID: UUID? = nil, taskID: UUID? = nil, purpose: ProviderWaitPurpose) {
        self.role = role
        self.agentID = agentID
        self.taskID = taskID
        self.purpose = purpose
    }
}

/// One caller sleeping on a provider before retrying. Published by `ProviderWaitBoard` for the
/// whole of the sleep, so "waiting for the provider" is a state the UI can show instead of a
/// "Thinking" or "Idle" that is not true.
public struct ProviderWait: Sendable, Equatable, Identifiable {
    /// Unique per sleep.
    public let id: UUID
    public let holder: ProviderWaitHolder
    public let reason: ProviderWaitReason
    /// Nil only when the caller's model has no configuration to name it by.
    public let providerID: String?
    public let modelID: String?
    /// When the current streak of failures began — the wait's age as the user experiences it,
    /// not just this sleep's.
    public let streakStartedAt: Date
    /// When the next attempt is due.
    public let resumesAt: Date
    /// 1-based count of failed attempts so far in this streak.
    public let attempt: Int

    public init(
        id: UUID = UUID(),
        holder: ProviderWaitHolder,
        reason: ProviderWaitReason,
        providerID: String?,
        modelID: String?,
        streakStartedAt: Date,
        resumesAt: Date,
        attempt: Int
    ) {
        self.id = id
        self.holder = holder
        self.reason = reason
        self.providerID = providerID
        self.modelID = modelID
        self.streakStartedAt = streakStartedAt
        self.resumesAt = resumesAt
        self.attempt = attempt
    }
}

extension ProviderWaitReason {
    /// The reason in a few words, for transcript lines and the inspector alike.
    public var displayDescription: String {
        switch self {
        case .usageLimitReached: return "usage limit reached"
        case .rateLimited: return "rate limited"
        case .serverRequestedDelay: return "server asked to wait"
        case .serverOutOfMemory: return "server out of memory"
        case .serverError: return "server error"
        case .networkError: return "network error"
        case .transientError: return "temporary error"
        }
    }
}

extension ProviderWaitPurpose {
    /// The agent whose progress this wait is holding up, when that is an agent other than the
    /// waiter — a Security Agent review holds the turn of the worker whose call it reviews.
    public var heldAgentID: UUID? {
        if case .securityReview(_, let reviewedAgentID) = self { return reviewedAgentID }
        return nil
    }
}

extension ProviderWait {
    /// Whether a waiter that has no transcript announcement of its own should post this one.
    /// A wait the server stated, or one that is clearly not a blip, is news on its first
    /// occurrence; anything else only once it has persisted for five attempts — the same
    /// threshold the agent run loop uses — so a brief hiccup never spams the transcript.
    public var warrantsAnnouncement: Bool {
        switch reason {
        case .usageLimitReached, .rateLimited, .serverRequestedDelay, .serverOutOfMemory:
            return attempt == 1
        case .serverError, .networkError, .transientError:
            return attempt == 5
        }
    }

    /// When the next attempt is due, as the transcript states it: "4:16 PM", or "4:16 PM on Fri
    /// Oct 9" when that is not today.
    public var resumeClockDescription: String {
        AgentActor.formatRetryClock(resumesAt)
    }

    /// "waiting for gpt-6.1-sol (usage limit reached) — retrying in 4.8 days (at 4:16 PM on Fri Oct 9)"
    public var waitingClause: String {
        let delay = max(resumesAt.timeIntervalSinceNow, 0)
        return "waiting for \(modelID ?? "its model") (\(reason.displayDescription)) — retrying in \(AgentActor.formatRetryDelay(delay)) (at \(resumeClockDescription))"
    }
}

/// What a stateless caller's retry sleeps are published as — handed to it by whoever owns the
/// board and knows who is calling (the validation coordinator, for the evaluation runner).
public struct ProviderWaitContext: Sendable {
    public let board: ProviderWaitBoard?
    public let holder: ProviderWaitHolder
    public let providerID: String?
    public let modelID: String?

    public init(board: ProviderWaitBoard?, holder: ProviderWaitHolder, providerID: String?, modelID: String?) {
        self.board = board
        self.holder = holder
        self.providerID = providerID
        self.modelID = modelID
    }
}
