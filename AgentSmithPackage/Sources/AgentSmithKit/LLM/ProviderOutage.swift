import Foundation
import SwiftLLMKit

/// Why a role's model can't be used at all — an account or model problem only a person can fix,
/// as opposed to a fault in one request. Read from the typed failure (HTTP status, the Codex
/// backend's typed limit), never from the provider's prose.
public enum ProviderUnavailableKind: Sendable, Equatable {
    /// HTTP 402: the balance or plan doesn't cover this model (Ollama answers 402 for a model
    /// outside the account's plan).
    case paymentRequired
    /// The Codex backend's depleted-credits limit. A balance, so it may be topped up at any time:
    /// the outage is re-checked on a slow cadence (`recheckInterval`) and lifts on its own once
    /// credits are back. `userCanResolve` is false when only a workspace owner can add them.
    case creditsDepleted(userCanResolve: Bool)
    /// The Codex backend's administrative spend cap.
    case spendLimitReached
    /// HTTP 401: the key is missing, wrong, or revoked.
    case unauthorized
    /// HTTP 403: the account may not use this model.
    case forbidden
    /// HTTP 404: the provider doesn't know this model.
    case modelNotFound
    /// HTTP 429 through an agent's whole retry budget: a rate or usage limit that did not lift
    /// (Ollama's free-plan usage limit, an exhausted quota). Never returned by `of(_:)` — a single
    /// 429 is transient — only by `afterRetriesExhausted(on:)`.
    case rateLimitExhausted

    /// The kind of `error`, or nil when it is not an account/model problem. A malformed request,
    /// a content-policy refusal or a context overflow belongs to ONE conversation, not the model.
    public static func of(_ error: Error) -> ProviderUnavailableKind? {
        guard let providerError = error as? LLMProviderError,
              case .httpError(let statusCode, let body, _, _) = providerError else { return nil }
        if let limit = CodexLimit.parse(statusCode: statusCode, body: body) {
            switch limit.kind {
            case .creditsDepleted(let userCanResolve): return .creditsDepleted(userCanResolve: userCanResolve)
            case .spendControlReached: return .spendLimitReached
            case .usageWindowExhausted, .rateLimited: return nil
            }
        }
        switch statusCode {
        case 401: return .unauthorized
        case 402: return .paymentRequired
        // OpenRouter answers 403 when moderation flags the INPUT — a refusal of this conversation,
        // not of the account — and says so in typed fields of its error object.
        case 403 where isModerationRefusal(body: body): return nil
        case 403: return .forbidden
        // OpenRouter also answers 404 when a REQUEST needs what the model can't do ("No endpoints
        // found that support image input") — but equally when the model has no provider left. Only
        // the message tells them apart, so both trip the breaker: held tasks wait visibly for the
        // user, where a missed dead model would fail every task started on it in turn.
        case 404: return .modelNotFound
        default: return nil
        }
    }

    /// The kind of an agent's LAST error when its retry budget ran out, or nil when running out of
    /// retries says nothing about the model. A 429 that outlasted every retry is a limit only a
    /// person can lift; any other transient fault (a 5xx, a timeout) is not attributed to the model.
    public static func afterRetriesExhausted(on error: Error) -> ProviderUnavailableKind? {
        guard let providerError = error as? LLMProviderError,
              case .httpError(let statusCode, _, _, _) = providerError,
              statusCode == 429 else { return nil }
        return .rateLimitExhausted
    }

    /// Whether a 403's error object carries OpenRouter's moderation metadata (`error.metadata.reasons`
    /// or `error.metadata.flagged_input`). Keyed on the field names, never the message text. A body
    /// that isn't such an object reads as not a moderation refusal.
    static func isModerationRefusal(body: String) -> Bool {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: Data(body.utf8))
        } catch {
            return false
        }
        guard let root = parsed as? [String: Any],
              let errorObject = root["error"] as? [String: Any],
              let metadata = errorObject["metadata"] as? [String: Any] else { return false }
        return metadata["reasons"] != nil || metadata["flagged_input"] != nil
    }

    /// What the user does before pressing Play, finishing "press Play on one of them …".
    public var retryCondition: String {
        switch self {
        case .rateLimitExhausted: return "once the provider's limit resets"
        case .creditsDepleted(userCanResolve: true): return "after adding credits to the account"
        case .creditsDepleted(userCanResolve: false): return "once a workspace owner has added credits"
        case .paymentRequired, .spendLimitReached, .unauthorized, .forbidden, .modelNotFound: return "after fixing the account"
        }
    }

    /// How often the runtime checks, on its own, whether this outage has lifted — nil for an
    /// outage only a person's action ends. Only depleted credits: a balance someone may top up at
    /// any time (ROADMAP, ChatGPT-subscription settled decisions, 2026-09-16). A spend cap is an
    /// administrative decision with no balance to watch, and the others need the account or the
    /// model changed, which the user does in this app.
    public var recheckInterval: TimeInterval? {
        switch self {
        case .creditsDepleted: return Self.creditsRecheckInterval
        case .paymentRequired, .spendLimitReached, .unauthorized, .forbidden, .modelNotFound, .rateLimitExhausted: return nil
        }
    }

    /// What a re-check of this outage is waiting on, for the provider wait board — nil exactly when
    /// `recheckInterval` is.
    public var recheckWaitReason: ProviderWaitReason? {
        switch self {
        case .creditsDepleted: return .creditsDepleted
        case .paymentRequired, .spendLimitReached, .unauthorized, .forbidden, .modelNotFound, .rateLimitExhausted: return nil
        }
    }

    /// How often depleted credits are re-checked: an hour, the same as
    /// `LLMRetryPolicy.ridiculousRetryAfterSeconds` but its own constant on purpose, so tuning the
    /// retry threshold can never silently change how often a paid probe call is made.
    public static let creditsRecheckInterval: TimeInterval = 3600

    /// How the work held by this outage resumes, as one sentence for the user.
    public var resumeSentence: String {
        if let recheckInterval {
            let minutes = Int(recheckInterval / 60)
            return "It is checked again every \(minutes) minutes and resumes on its own once it can be used; you can also change the worker's model in Settings, or press Play \(retryCondition)."
        }
        return "It resumes when you change the worker's model in Settings, or press Play \(retryCondition)."
    }

    /// A few words for messages.
    public var displayDescription: String {
        switch self {
        case .paymentRequired: return "payment required — out of credits, or the model isn't in the account's plan"
        case .creditsDepleted: return "the account's credits are used up"
        case .spendLimitReached: return "the account's spend limit was reached"
        case .unauthorized: return "the API key was rejected"
        case .forbidden: return "the account isn't allowed to use this model"
        case .modelNotFound: return "the provider doesn't know this model"
        case .rateLimitExhausted: return "the provider kept refusing with HTTP 429 (a rate or usage limit) through every retry"
        }
    }
}

/// What the runtime did with an agent's `ProviderOutage` report — the agent's stop line says it.
public enum ProviderOutageHandling: Sendable, Equatable {
    /// The worker's task is on hold until the worker's model can be used.
    case taskOnHold
    /// The report was about a model the worker no longer has; its task restarts on the current one.
    case taskRestarting
    /// No task was put on hold: not a worker, or its task was not running.
    case noTaskHeld
}

/// A role's model reported unusable (`ProviderUnavailableKind`). While one stands for the worker
/// role, no task starts on that model; tasks it stopped are on hold, not failed, and restart when the
/// worker's model changes or the user presses Play on one of them.
public struct ProviderOutage: Sendable, Equatable {
    public let role: AgentRole
    public let providerID: String
    public let modelID: String
    public let kind: ProviderUnavailableKind
    /// The provider's own error, for the user.
    public let detail: String
    public let since: Date

    public init(role: AgentRole, providerID: String, modelID: String, kind: ProviderUnavailableKind, detail: String, since: Date = Date()) {
        self.role = role
        self.providerID = providerID
        self.modelID = modelID
        self.kind = kind
        self.detail = detail
        self.since = since
    }
}
