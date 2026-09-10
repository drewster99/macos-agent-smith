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

    /// How long a caller will keep retrying, and how sparsely.
    ///
    /// The ceiling belongs here because endurance and request rate are one decision: reaching a
    /// two-hour window at a 15 s ceiling would mean ~480 requests to a backend already refusing
    /// them. Attempts alone are also a poor proxy for endurance once the curve flattens — attempts
    /// 5 through 50 are all 15 s apart.
    public struct RetryBudget: Sendable, Equatable {
        public let maxAttempts: Int
        public let maxElapsedSeconds: TimeInterval
        public let maxBackoffSeconds: TimeInterval

        public init(maxAttempts: Int, maxElapsedSeconds: TimeInterval, maxBackoffSeconds: TimeInterval) {
            self.maxAttempts = maxAttempts
            self.maxElapsedSeconds = maxElapsedSeconds
            self.maxBackoffSeconds = maxBackoffSeconds
        }
    }

    /// Today's behavior, byte for byte: bounded by ATTEMPTS ONLY.
    ///
    /// `maxElapsedSeconds` is `.infinity` on purpose, not as a placeholder. Any finite value is a
    /// silent tightening, because a server-directed `Retry-After` is honored UNCAPPED: a 429 asking
    /// for two hours picks this budget (the server stated a delay, so patience isn't needed), sleeps
    /// two hours, and would then find any finite window already spent — so the NEXT transient error,
    /// which today would simply retry, would instead kill the agent. The wall clock exists to bound
    /// the patient budget below, where attempts alone bound nothing useful; here attempts already do.
    public static let standardBudget = RetryBudget(
        maxAttempts: maxAttempts, maxElapsedSeconds: .infinity, maxBackoffSeconds: maxBackoffSeconds)

    /// For a 429 that states NO delay, when nothing is blocked behind the caller.
    ///
    /// Sized from this app's own logs rather than from taste. Two Ollama Cloud "session usage
    /// limit" episodes RECOVERED and their workers finished the task — after 26 and 37 consecutive
    /// failures spanning 65 and 98 minutes. Both predate the 2026-07-25 retry consolidation, which
    /// replaced a 3 s→120 s per-agent curve with the shared 1,2,4,8,15,15… one and thereby cut
    /// maximum 429 endurance from roughly 90 minutes to about 11.5 — so under `standardBudget`
    /// both of those recoveries would now be deaths.
    ///
    /// The 300 s ceiling reaches two hours in ~33 attempts, which is the point: endure longer while
    /// asking *less* often. Do not lower `maxElapsedSeconds` below ~6000 without new evidence —
    /// anything under about 100 minutes discards a recovery this app has actually observed.
    public static let patientThrottleBudget = RetryBudget(
        maxAttempts: maxAttempts, maxElapsedSeconds: 7200, maxBackoffSeconds: 300)

    /// The budget for a classification.
    ///
    /// `patient` is the CALLER's declaration that nothing is blocked behind it. A worker's next
    /// turn can wait; a security verdict that a tool call is parked on cannot, and neither can a
    /// validator holding a task. Only the agent run loop passes true.
    ///
    /// A throttle that STATES its own delay does not need patience — the server said when its
    /// window reopens, so believe it and use the standard budget. That is also the only signal
    /// available: the word "quota" is semantically inverted across providers (Gemini's recoverable
    /// limit says "You exceeded your current quota"; Moonshot's terminal suspension is typed
    /// `exceeded_current_quota_error`), and Ollama alone has shipped three wordings across two JSON
    /// schemas — so nothing here reads the body's prose.
    public static func budget(for classification: Classification, patient: Bool) -> RetryBudget {
        guard case .transient(let retryAfter, let isThrottle) = classification,
              isThrottle, retryAfter == nil, patient else { return standardBudget }
        return patientThrottleBudget
    }

    /// Whether an error is worth trying again, and how long the server wants us to wait.
    public enum Classification: Sendable, Equatable {
        /// Worth retrying. `retryAfter` is the server-directed delay when it supplied one.
        ///
        /// `isThrottle` is read off the STATUS CODE alone — it is true for 429 and nothing else.
        /// It exists so a caller can spend a different BUDGET on a rate limit without any part of
        /// the system reclassifying a 429 as permanent, which no available signal can justify.
        case transient(retryAfter: TimeInterval?, isThrottle: Bool = false)
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
                case 429:
                    // Still transient — the most common 429 by far is an ordinary rate limit, and
                    // an exhausted balance is indistinguishable from it by status code. What the
                    // flag changes is how long we are willing to be wrong about which one this is.
                    return .transient(retryAfter: serverDelay, isThrottle: true)
                case 408:
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
    public static func delay(
        attempt: Int,
        retryAfter: TimeInterval?,
        budget: RetryBudget = standardBudget
    ) -> TimeInterval {
        if let retryAfter { return max(retryAfter, 1) }
        // Clamp the exponent before `pow` so a large attempt count can't overflow to infinity.
        let exponent = min(max(attempt - 1, 0), 20)
        return min(baseBackoffSeconds * pow(2, Double(exponent)), budget.maxBackoffSeconds)
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

    /// Extracts a server-requested retry delay (seconds) from an error *body* for providers that
    /// don't use the `Retry-After` header. Handles Google/Gemini's `google.rpc.RetryInfo`
    /// (`"retryDelay": "34s"`) and its "Please retry in 34.376s" phrasing in the message text.
    /// The prose pattern is anchored on "please retry in" so incidental error prose that merely
    /// mentions some other "retry in N s" (e.g. describing a background job) can't be mistaken for
    /// a directive to this client.
    public static func retryAfterFromErrorBody(_ body: String) -> TimeInterval? {
        let patterns = [
            #""retryDelay"\s*:\s*"(\d+(?:\.\d+)?)s""#,
            #"please retry in (\d+(?:\.\d+)?)\s*s"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(body.startIndex..<body.endIndex, in: body)
            if let match = regex.firstMatch(in: body, options: [], range: range),
               match.numberOfRanges >= 2,
               let captured = Range(match.range(at: 1), in: body),
               let value = TimeInterval(body[captured]), value.isFinite, value >= 0 {
                return value
            }
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
