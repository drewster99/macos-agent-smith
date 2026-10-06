import Foundation
import SwiftLLMKit

/// Why a role's model can't be used at all — an account or model problem only a person can fix,
/// as opposed to a fault in one request. Read from the typed failure (HTTP status, the Codex
/// backend's typed limit), never from the provider's prose.
public enum ProviderUnavailableKind: String, Sendable, Codable, Equatable {
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
        case 403: return .forbidden
        case 404: return .modelNotFound
        default: return nil
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
        }
    }
}

/// A role's model reported unusable (`ProviderUnavailableKind`). While one stands for the worker
/// role, no task starts on that model; tasks it stopped are paused, not failed, and resume when the
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
