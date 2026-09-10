import Testing
import Foundation
@testable import AgentSmithKit
import SwiftLLMKit

/// Pins the one retry policy every LLM caller shares.
///
/// Before consolidation each caller invented its own, and the differences were load-bearing:
/// the security evaluator retried with NO delay and burned all 8 attempts inside a single ~20s
/// provider outage; the validator gave up after one failure and parked the task for a human;
/// `AgentActor` classified an out-of-credits 402 as permanent and then retried it 50 times
/// anyway, because the classification only gated the log message.
@Suite("LLM retry policy")
struct LLMRetryPolicyTests {

    private func httpError(_ status: Int, body: String = "", retryAfter: TimeInterval? = nil) -> Error {
        LLMProviderError.httpError(statusCode: status, body: body, url: nil, retryAfter: retryAfter)
    }

    // MARK: - Classification

    @Test("Rate limits, timeouts and server faults are transient", arguments: [408, 429, 500, 502, 503, 529])
    func transientStatuses(status: Int) {
        // `isThrottle` is 429 and nothing else — it is read off the status code, never the body,
        // because the body's wording is inverted across providers and drifts within one of them.
        #expect(LLMRetryPolicy.classify(httpError(status)) == .transient(retryAfter: nil, isThrottle: status == 429))
    }

    /// The whole point of classifying: these never recover on their own, so retrying them is
    /// pure waste. 402 is the one that actually cost time — an empty Anthropic balance was
    /// retried 50 times across ~90 minutes.
    @Test("Client errors that need a human are permanent", arguments: [400, 401, 402, 403, 404, 422])
    func permanentStatuses(status: Int) {
        #expect(LLMRetryPolicy.classify(httpError(status)) == .permanent)
    }

    @Test("A server-supplied Retry-After rides along with the classification")
    func retryAfterIsCarried() {
        #expect(LLMRetryPolicy.classify(httpError(429, retryAfter: 30)) == .transient(retryAfter: 30, isThrottle: true))
    }

    @Test("A retry delay stated only in the body is recovered")
    func retryAfterFromBody() {
        // Google states it as a google.rpc.RetryInfo rather than a header.
        let gemini = httpError(429, body: #"{"error":{"details":[{"retryDelay":"34s"}]}}"#)
        #expect(LLMRetryPolicy.classify(gemini) == .transient(retryAfter: 34, isThrottle: true))

        let prose = httpError(503, body: "overloaded, please retry in 12s")
        #expect(LLMRetryPolicy.classify(prose) == .transient(retryAfter: 12))
    }

    @Test("Network faults are transient; cancellation and bad requests are not")
    func nonHTTPClassification() {
        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        #expect(LLMRetryPolicy.classify(timeout) == .transient(retryAfter: nil))
        #expect(LLMRetryPolicy.classify(CancellationError()) == .permanent)
        #expect(LLMRetryPolicy.classify(LLMProviderError.invalidRequest(detail: "NaN temperature")) == .permanent)
    }

    /// Unknown errors lean transient on purpose: stranding an agent that would have recovered
    /// is worse than a bounded number of wasted retries.
    @Test("An unrecognized error is treated as transient")
    func unknownIsTransient() {
        struct Mystery: Error {}
        #expect(LLMRetryPolicy.classify(Mystery()) == .transient(retryAfter: nil))
    }

    // MARK: - Backoff

    @Test("Backoff doubles from 1s and caps at 15s")
    func backoffCurve() {
        let observed = (1...8).map { LLMRetryPolicy.delay(attempt: $0, retryAfter: nil) }
        #expect(observed == [1, 2, 4, 8, 15, 15, 15, 15])
    }

    @Test("A server Retry-After overrides the curve and is not capped")
    func serverDelayWins() {
        // 300s is far above maxBackoffSeconds — honored anyway, because the server knows when
        // its own window reopens.
        #expect(LLMRetryPolicy.delay(attempt: 1, retryAfter: 300) == 300)
    }

    @Test("Retry-After: 0 is floored so it cannot spin a tight loop")
    func serverDelayFloored() {
        #expect(LLMRetryPolicy.delay(attempt: 1, retryAfter: 0) == 1)
    }

    /// A large attempt count must not overflow `pow` into infinity and schedule a forever-sleep.
    @Test("A huge attempt count stays clamped at the ceiling")
    func noOverflow() {
        let delay = LLMRetryPolicy.delay(attempt: 10_000, retryAfter: nil)
        #expect(delay == LLMRetryPolicy.maxBackoffSeconds)
        #expect(delay.isFinite)
    }

    // MARK: - Agreed constants

    @Test("The shared budget and ceiling are what every caller was told to use")
    func constants() {
        #expect(LLMRetryPolicy.maxAttempts == 50)
        #expect(LLMRetryPolicy.maxBackoffSeconds == 15)
    }

    /// Worst case for a transient outage: the ramp plus the capped tail. Bounds total
    /// wall-clock so nobody has to re-derive it from the curve.
    @Test("Fifty transient attempts bound total wait to roughly twelve minutes")
    func totalWaitIsBounded() {
        let total = (1..<LLMRetryPolicy.maxAttempts)
            .reduce(0.0) { $0 + LLMRetryPolicy.delay(attempt: $1, retryAfter: nil) }
        #expect(total > 600)   // long enough to outlast a real outage
        #expect(total < 780)   // short enough that a dead backend surfaces promptly
    }

    // MARK: - Body parsing

    @Test("Body parsing ignores malformed and absent delays")
    func bodyParsingRejects() {
        #expect(LLMRetryPolicy.retryAfterFromErrorBody("") == nil)
        #expect(LLMRetryPolicy.retryAfterFromErrorBody(#"{"error":"Internal Server Error"}"#) == nil)
        #expect(LLMRetryPolicy.retryAfterFromErrorBody(#"{"retryDelay":"soon"}"#) == nil)
    }

    // MARK: - Formatting

    @Test("Delays format readably at every magnitude")
    func formatting() {
        #expect(LLMRetryPolicy.formatDelay(15) == "15s")
        #expect(LLMRetryPolicy.formatDelay(90) == "1m 30s")
        #expect(LLMRetryPolicy.formatDelay(120) == "2m")
        #expect(LLMRetryPolicy.formatDelay(7200) == "2h")
        #expect(LLMRetryPolicy.formatDelay(7500) == "2h 5m")
    }

    /// The standard budget must be bounded by ATTEMPTS ONLY.
    ///
    /// Any finite wall clock here is a silent tightening, because a server-directed `Retry-After`
    /// is honored uncapped: a 429 asking for two hours selects this budget (a stated delay needs no
    /// patience), sleeps two hours, and would then find a finite window already spent — so the next
    /// transient error, which today simply retries, would instead kill the agent. Nothing in this
    /// change was allowed to make any caller's endurance SHORTER.
    @Test("The standard budget is bounded by attempts, never by wall clock")
    func standardBudgetHasNoWallClockBound() {
        #expect(LLMRetryPolicy.standardBudget.maxElapsedSeconds == .infinity)
        #expect(LLMRetryPolicy.standardBudget.maxAttempts == LLMRetryPolicy.maxAttempts)
        #expect(LLMRetryPolicy.standardBudget.maxBackoffSeconds == LLMRetryPolicy.maxBackoffSeconds)

        // The concrete scenario: a two-hour Retry-After picks the standard budget, and honoring it
        // must not consume an allowance that then stops the next attempt.
        let longWait = LLMRetryPolicy.classify(
            LLMProviderError.httpError(statusCode: 429, body: "", url: nil, retryAfter: 7200)
        )
        let budget = LLMRetryPolicy.budget(for: longWait, patient: true)
        #expect(budget.maxElapsedSeconds == .infinity, "a stated long wait must not shorten endurance")
        #expect(LLMRetryPolicy.delay(attempt: 1, retryAfter: 7200, budget: budget) == 7200,
                "a server-directed wait is honored uncapped")
    }

    /// The patient budget is the only one the wall clock bounds, and it must stay long enough to
    /// cover the recoveries this app has actually observed (65 and 98 minutes).
    @Test("The patient budget endures past the observed recoveries and asks less often")
    func patientBudgetOutlastsObservedRecoveries() {
        let patient = LLMRetryPolicy.patientThrottleBudget
        #expect(patient.maxElapsedSeconds >= 6000, "under ~100 min discards an observed recovery")
        #expect(patient.maxBackoffSeconds > LLMRetryPolicy.maxBackoffSeconds, "endure longer, ask less often")

        // A 429 with NO stated delay is the only thing that gets it, and only for a patient caller.
        let silent429 = LLMRetryPolicy.classify(
            LLMProviderError.httpError(statusCode: 429, body: "{}", url: nil, retryAfter: nil)
        )
        #expect(LLMRetryPolicy.budget(for: silent429, patient: true) == patient)
        #expect(LLMRetryPolicy.budget(for: silent429, patient: false) == LLMRetryPolicy.standardBudget,
                "the four non-agent callers keep today's behavior exactly")

        // Neither a 5xx nor a stated-delay 429 gets patience.
        let serverFault = LLMRetryPolicy.classify(
            LLMProviderError.httpError(statusCode: 503, body: "", url: nil, retryAfter: nil)
        )
        #expect(LLMRetryPolicy.budget(for: serverFault, patient: true) == LLMRetryPolicy.standardBudget)

        // Neither bound is dead: the curve must reach the window inside the attempt cap.
        var elapsed: TimeInterval = 0
        var attempt = 1
        while elapsed < patient.maxElapsedSeconds && attempt <= patient.maxAttempts {
            elapsed += LLMRetryPolicy.delay(attempt: attempt, retryAfter: nil, budget: patient)
            attempt += 1
        }
        #expect(elapsed >= patient.maxElapsedSeconds,
                "the attempt cap fires before the window — the wall clock would be a dead constant")
    }
}
