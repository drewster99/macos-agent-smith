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
    /// How long a probe may hold its exclusive slot before the breaker stops waiting for it.
    ///
    /// A SAFETY VALVE, not the mechanism. A probe normally reports back and releases its own slot;
    /// this bounds the case where it never can — cancelled mid-flight when its worker is stopped,
    /// or lost to a crash in the evaluator. Without it a boolean "probe in flight" is a permanent
    /// wedge: every tool call in the app blocked forever, which is far worse than the overlapping
    /// probes the flag exists to prevent. Generous, so an honest probe honoring a long
    /// server-directed delay is not overtaken; the cost of expiry is one extra probe, not a wedge.
    private static let probeLeaseSeconds: TimeInterval = 300

    private var consecutiveFailures = 0
    private var openedAt: Date?
    /// The token of the probe currently holding the exclusive slot, and when it took it.
    ///
    /// A TOKEN rather than a bool because a bare flag has no owner: an evaluation that started
    /// before the breaker opened, and fails while a probe is out, would clear a marker it never
    /// set — admitting a second probe alongside the first.
    private var probe: (token: Int, startedAt: Date)?
    private var nextProbeToken = 1

    /// Whether to skip the LLM entirely and block immediately, and if not, the probe token this
    /// caller must report back with.
    enum Admission: Sendable, Equatable {
        /// Block now, with no LLM attempt.
        case blocked
        /// Proceed. `probeToken` is non-nil when this caller is the exclusive half-open probe and
        /// must pass it to `recordReachable`/`recordUnreachable`.
        case proceed(probeToken: Int?)
    }

    func admit(now: Date = Date()) -> Admission {
        guard let openedAt else { return .proceed(probeToken: nil) }

        // A probe holds the slot until it reports back or its lease lapses.
        if let probe, now.timeIntervalSince(probe.startedAt) < Self.probeLeaseSeconds {
            return .blocked
        }

        if now.timeIntervalSince(openedAt) >= Self.cooldownSeconds {
            let token = nextProbeToken
            nextProbeToken += 1
            probe = (token: token, startedAt: now)
            return .proceed(probeToken: token)
        }
        return .blocked
    }

    /// Records that an evaluation ended with no verdict because the backend did not answer.
    ///
    /// Takes `now` for the same reason `admit` does: the two have to agree about the clock, and an
    /// injected time on only one of them makes the pair untestable.
    func recordUnreachable(now: Date = Date(), probeToken: Int? = nil) {
        consecutiveFailures += 1
        // Restart the cooldown on EVERY failure, including a failed probe. Opening only when
        // `openedAt` was nil left a failed probe's window measured from when that probe was
        // admitted, so the next probe went out immediately rather than a cooldown later.
        if consecutiveFailures >= Self.failureThreshold {
            openedAt = now
        }
        releaseProbe(probeToken)
    }

    /// Records that the backend answered — whatever the verdict was. Closes the breaker.
    func recordReachable(probeToken: Int? = nil) {
        consecutiveFailures = 0
        openedAt = nil
        probe = nil
    }

    /// Releases a probe slot without recording a verdict either way — the evaluation was abandoned
    /// (cancelled with its worker, say), which says nothing about whether the backend is healthy.
    func abandonProbe(_ probeToken: Int?) {
        releaseProbe(probeToken)
    }

    /// Only the probe that took the slot may release it.
    private func releaseProbe(_ probeToken: Int?) {
        guard let probeToken, probe?.token == probeToken else { return }
        probe = nil
    }

    /// The transport budget the next evaluation may spend. Reduced while the backend is known to be
    /// struggling, so a probe costs seconds rather than minutes.
    func transportAttemptBudget() -> Int {
        consecutiveFailures > 0 ? Self.probeAttemptBudget : LLMRetryPolicy.maxAttempts
    }

    /// Whether this is the first unreachable result of a streak — the edge a user-facing alarm
    /// would fire on, so an outage produces one row rather than one per blocked call.
    func isFirstFailureOfStreak() -> Bool { consecutiveFailures == 1 }
}
