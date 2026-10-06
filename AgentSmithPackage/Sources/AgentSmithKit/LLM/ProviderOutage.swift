import Foundation
import SwiftLLMKit

/// Why a role's model can't be used at all — an account or model problem only a person can fix,
/// as opposed to a fault in one request. Read from the typed failure (HTTP status, the Codex
/// backend's typed limit), never from the provider's prose.
public enum ProviderUnavailableKind: Sendable, Equatable {
    /// HTTP 402, or the Codex backend's depleted-credits limit: the balance or plan doesn't cover
    /// this model (Ollama answers 402 for a model outside the account's plan).
    case paymentRequired
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
            case .creditsDepleted: return .paymentRequired
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
        case .paymentRequired, .spendLimitReached, .unauthorized, .forbidden, .modelNotFound: return "after fixing the account"
        }
    }

    /// A few words for messages.
    public var displayDescription: String {
        switch self {
        case .paymentRequired: return "payment required — out of credits, or the model isn't in the account's plan"
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
