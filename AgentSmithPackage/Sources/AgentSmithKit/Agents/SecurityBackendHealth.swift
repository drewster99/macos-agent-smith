import Foundation

/// Shared circuit breaker for the Security Agent's model backend.
///
/// Exists because the honest answer to an unreachable reviewer — telling the blocked worker its
/// call was never judged and to retry the identical call — is only safe if retrying is cheap. It
/// isn't: each attempt re-enters `LLMRetryPolicy`'s full transport budget, roughly twelve minutes
/// of backoff, before failing the same way. A worker would spend hours blocked, and the per-tool
/// failure streak would eventually stop it with advice to change its approach, which for an outage
/// means weakening a command nothing objected to.
///
/// Lives on the RUNTIME and is injected into every evaluator, not held per-evaluator: each Brown
/// gets its own `SecurityEvaluator` instance whose state dies with it, so a per-instance breaker
/// would fragment across up to ten concurrent workers and reset on every respawn — exactly when the
/// backend is least likely to have recovered.
///
/// It only ever makes the system block FASTER. It cannot approve anything: the outcome it
/// short-circuits to is `.reviewerUnavailable`, whose `approved` is false by construction.
actor SecurityBackendHealth {

    /// Consecutive unreachable verdicts before the breaker opens. Two, not the scoping path's
    /// three, because one failure here has already spent a full transport budget — the patience is
    /// paid before we ever get a say.
    private static let failureThreshold = 2
    /// How long to answer immediately before letting one probe through.
    private static let cooldownSeconds: TimeInterval = 60
    /// Transport attempts a half-open probe may spend. Without this the "cooldown" is meaningless:
    /// a probe on the full budget takes twelve minutes, so the breaker would spend far longer open
    /// than closed and could never notice a recovery promptly.
    static let probeAttemptBudget = 2

    private var consecutiveFailures = 0
    private var openedAt: Date?

    /// Records that an evaluation ended with no verdict because the backend did not answer.
    func recordUnreachable() {
        consecutiveFailures += 1
        if consecutiveFailures >= Self.failureThreshold, openedAt == nil {
            openedAt = Date()
        }
    }

    /// Records that the backend answered — whatever the verdict was. Closes the breaker.
    func recordReachable() {
        consecutiveFailures = 0
        openedAt = nil
    }

    /// Whether to skip the LLM entirely and block immediately.
    ///
    /// False once the cooldown lapses, which lets exactly one probe through on the reduced budget;
    /// that probe then calls `recordReachable`/`recordUnreachable` and either closes the breaker or
    /// restarts the cooldown.
    func shouldShortCircuit(now: Date = Date()) -> Bool {
        guard let openedAt else { return false }
        if now.timeIntervalSince(openedAt) >= Self.cooldownSeconds {
            self.openedAt = now      // half-open: this caller is the probe, others keep blocking
            return false
        }
        return true
    }

    /// The transport budget the next evaluation may spend. Reduced while the backend is known to be
    /// struggling, so a probe costs seconds rather than minutes.
    func transportAttemptBudget() -> Int {
        consecutiveFailures > 0 ? Self.probeAttemptBudget : LLMRetryPolicy.maxAttempts
    }

    /// Whether this is the first unreachable result of a streak — the edge the user-facing alarm
    /// fires on, so an outage produces one row rather than one per blocked call.
    func isFirstFailureOfStreak() -> Bool { consecutiveFailures == 1 }
}
