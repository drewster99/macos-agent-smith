import Foundation
import SwiftLLMKit

/// The single retry policy for every LLM call in the system.
///
/// Before this existed, each caller invented its own. Measured 2026-07-25 during an Ollama
/// Cloud outage, the four paths behaved four different ways against the same failure:
///
/// | caller | attempts | backoff | transient classification |
/// |---|---|---|---|
/// | `AgentActor` (Brown/Smith) | 50 | 3s → 120s / 1800s | partial — used only to decide when to *print* |
/// | `TaskSummarizer` | 3 | 5 / 15 / 45s | yes |
/// | `SecurityEvaluator.scopeTools` | 8 | 500ms × 2ⁿ | none — retried a permanent 401 eight times |
/// | `SecurityEvaluator` per-call eval | 8 | **none** | none |
/// | `EvaluationRunner` (validator) | **1** | none | none |
///
/// The consequences were not academic. The per-call evaluator burned all 8 attempts inside a
/// single ~20s outage window because it never slept, denying a tool call that a paced retry
/// would have gotten a verdict for. The validator gave up on the first blip and parked the task
/// for a human. `AgentActor` classified an out-of-credits 402 as "persistent" and then retried
/// it 50 times anyway, because the classification only gated the log message.
///
/// Everything now routes through here.
///
/// - **Transient** failures (429, 408, 5xx, network) retry up to ``maxAttempts`` with exponential
///   backoff capped at ``maxBackoffSeconds``.
/// - **Permanent** failures (the remaining 4xx — bad key, out of credits, unknown model) are not
///   retried at all. The caller fails immediately with the real reason instead of spending
///   minutes pretending a billing block might resolve itself.
/// - A server-supplied `Retry-After` always wins over our computed delay and is honored with **no
///   upper bound**, because the server knows when its own window reopens.
public enum LLMRetryPolicy {

    /// Maximum attempts for a transient failure, counting the first try.
    public static let maxAttempts = 50

    /// Ceiling on the *computed* backoff. A server-directed `Retry-After` is not subject to it.
    public static let maxBackoffSeconds: TimeInterval = 15

    /// First retry delay; doubles per attempt until it reaches ``maxBackoffSeconds``.
    /// Deliberately short — the observed provider outages were 15–22s, so the useful attempts
    /// are the early ones. The sequence is 1, 2, 4, 8, 15, 15, …
    public static let baseBackoffSeconds: TimeInterval = 1

    /// A `Retry-After` at or above this reads as a provider problem worth telling the user
    /// about. It is still honored — this only drives messaging.
    public static let ridiculousRetryAfterSeconds: TimeInterval = 3600

    /// Whether an error is worth trying again, and how long the server wants us to wait.
    public enum Classification: Sendable, Equatable {
        /// Worth retrying. `retryAfter` is the server-directed delay when it supplied one.
        case transient(retryAfter: TimeInterval?)
        /// Retrying cannot help — a bad key, exhausted credits, an unknown model, a malformed
        /// request. Needs a human, not another attempt.
        case permanent
    }

    /// Classifies a thrown LLM error.
    ///
    /// Unknown errors are treated as **transient**. That is the deliberately conservative
    /// direction: mis-classifying a transient fault as permanent strands an agent that would
    /// have recovered, whereas the reverse merely costs a bounded number of retries. Only the
    /// definitively-deterministic statuses are called permanent.
    ///
    /// Cancellation is permanent — a cancelled call must not be retried into a stopped agent.
    public static func classify(_ error: Error) -> Classification {
        if error is CancellationError { return .permanent }

        if let providerError = error as? LLMProviderError {
            switch providerError {
            case .httpError(let statusCode, let body, _, let retryAfter):
                // Prefer the header; some providers (Gemini/Google) state the delay only in the
                // body as a google.rpc.RetryInfo.
                let serverDelay = retryAfter ?? retryAfterFromErrorBody(body)
                switch statusCode {
                case 408, 429:
                    return .transient(retryAfter: serverDelay)
                case 500...599:
                    return .transient(retryAfter: serverDelay)
                case 400...499:
                    // 400s that ARE recoverable (context overflow, an output cap above the
                    // model's real limit) are detected and handled by the caller before the
                    // error ever reaches classification.
                    return .permanent
                default:
                    return .transient(retryAfter: serverDelay)
                }
            case .invalidRequest:
                // Our own malformed request — a non-finite temperature, etc. Resending it
                // unchanged produces the same failure.
                return .permanent
            case .invalidResponse, .malformedResponse:
                return .transient(retryAfter: nil)
            }
        }

        // URLSession-level faults: timeouts, connection reset, DNS blips.
        if (error as NSError).domain == NSURLErrorDomain { return .transient(retryAfter: nil) }

        return .transient(retryAfter: nil)
    }

    /// Seconds to wait before the next attempt.
    ///
    /// - Parameters:
    ///   - attempt: 1-based count of attempts already made (1 after the first failure).
    ///   - retryAfter: server-directed delay, when the classification supplied one.
    ///
    /// A server delay is floored at 1s so a `Retry-After: 0` cannot spin a tight loop, and is
    /// otherwise honored verbatim — including values far above ``maxBackoffSeconds``.
    public static func delay(attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        if let retryAfter { return max(retryAfter, 1) }
        // Clamp the exponent before `pow` so a large attempt count can't overflow to infinity.
        let exponent = min(max(attempt - 1, 0), 20)
        return min(baseBackoffSeconds * pow(2, Double(exponent)), maxBackoffSeconds)
    }

    /// Sleeps for the computed delay. Returns false if the sleep was cancelled, so callers can
    /// break out of their retry loop rather than immediately re-issuing a doomed call.
    @discardableResult
    public static func sleep(attempt: Int, retryAfter: TimeInterval?) async -> Bool {
        do {
            try await Task.sleep(for: .seconds(delay(attempt: attempt, retryAfter: retryAfter)))
            return true
        } catch {
            return false
        }
    }

    /// Extracts a retry delay stated in an error body rather than the `Retry-After` header.
    /// Google returns `"retryDelay": "34s"` inside a google.rpc.RetryInfo; some
    /// OpenAI-compatible backends write "please retry in 12s" into the message.
    public static func retryAfterFromErrorBody(_ body: String) -> TimeInterval? {
        let patterns = [
            #""retryDelay"\s*:\s*"(\d+(?:\.\d+)?)s""#,
            #"please retry in (\d+(?:\.\d+)?)\s*s"#
        ]
        for pattern in patterns {
            guard let match = body.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
                continue
            }
            let fragment = String(body[match])
            guard let numberRange = fragment.range(of: #"\d+(?:\.\d+)?"#, options: .regularExpression),
                  let seconds = TimeInterval(fragment[numberRange]),
                  seconds.isFinite, seconds >= 0 else {
                continue
            }
            return seconds
        }
        return nil
    }

    /// Human-readable delay for channel messages: "3s", "1m 30s", "2h 5m".
    public static func formatDelay(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 {
            let m = total / 60, s = total % 60
            return s == 0 ? "\(m)m" : "\(m)m \(s)s"
        }
        let h = total / 3600, m = (total % 3600) / 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
}
