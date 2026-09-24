import Foundation

/// A provider call that ended WITHOUT an `LLMResponse` — a transport error, an HTTP rejection, a
/// cancellation.
///
/// Deliberately not an `LLMTurnRecord`: a turn asserts that the model answered, and fabricating an
/// empty response for a failed attempt would render as a model that said nothing. Keeping the two
/// shapes distinct is what lets the inspector show failed attempts without lying about them.
public struct LLMCallFailureRecord: Identifiable, Sendable, Equatable {
    /// How the failure bears on retrying, per `LLMRetryPolicy`.
    public enum Disposition: Sendable, Equatable {
        /// Worth retrying (network, 429, 5xx, unknown).
        case transient
        /// Retrying cannot help (bad key, exhausted credits, malformed request).
        case permanent
        /// The caller stopped the call.
        case cancelled
    }

    public let id: UUID
    public let timestamp: Date
    /// Wall-clock time from issuing the call until it threw.
    public let latencyMs: Int
    public let modelID: String
    public let providerID: String?
    public let disposition: Disposition
    /// The handled error's description.
    public let errorDescription: String
    public let annotation: LLMCallAnnotation?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        latencyMs: Int,
        modelID: String,
        providerID: String?,
        disposition: Disposition,
        errorDescription: String,
        annotation: LLMCallAnnotation? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.latencyMs = latencyMs
        self.modelID = modelID
        self.providerID = providerID
        self.disposition = disposition
        self.errorDescription = errorDescription
        self.annotation = annotation
    }

    /// Builds a record from a thrown error, classifying it with the one shared retry policy.
    public init(
        error: Error,
        startedAt: Date,
        modelID: String,
        providerID: String?,
        annotation: LLMCallAnnotation? = nil,
        now: Date = Date()
    ) {
        let disposition: Disposition
        if error is CancellationError {
            disposition = .cancelled
        } else {
            switch LLMRetryPolicy.classify(error) {
            case .transient: disposition = .transient
            case .permanent: disposition = .permanent
            }
        }
        self.init(
            timestamp: now,
            latencyMs: max(0, Int(now.timeIntervalSince(startedAt) * 1000)),
            modelID: modelID,
            providerID: providerID,
            disposition: disposition,
            errorDescription: error.localizedDescription,
            annotation: annotation
        )
    }
}

/// One provider call as reported to observers: either the model answered, or the call failed
/// before it could.
public enum LLMCallEvent: Sendable, Equatable {
    case completed(LLMTurnRecord)
    case failed(LLMCallFailureRecord)
}
