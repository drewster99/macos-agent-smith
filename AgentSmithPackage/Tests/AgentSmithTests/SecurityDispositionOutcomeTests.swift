import Foundation
import Testing
import SwiftLLMKit
@testable import AgentSmithKit

/// A blocked call must never be reported as a verdict unless one was actually rendered.
///
/// The Security Agent's backend going down produced `approved: false` plus a prose message, and
/// every renderer's `else` branch called that UNSAFE. Brown's prompt tells it that UNSAFE means
/// stop, find a new approach, and never resubmit — under threat of termination — so an outage made
/// it rewrite commands nothing had objected to. Worse, the fake verdict was written into
/// `task.updates`, which is re-rendered into every future worker briefing, and into the Security
/// Agent's own recent-calls history, which is rendered into every subsequent evaluation prompt.
@Suite("Security disposition outcomes")
struct SecurityDispositionOutcomeTests {

    /// The post closure is `@Sendable`, so the captured value needs isolation of its own.
    private actor CapturedContent {
        private(set) var value: String?
        func set(_ newValue: String) { value = newValue }
    }

    private func call(_ name: String = "bash") -> LLMToolCall {
        LLMToolCall(id: "call-1", name: name, arguments: #"{"command":"ls"}"#)
    }

    // MARK: - The gate

    @Test("Only the three allow outcomes execute; every block outcome is fail-closed")
    func approvalIsFailClosed() {
        #expect(SecurityDisposition(outcome: .approved).approved)
        #expect(SecurityDisposition(outcome: .autoApproved).approved)
        #expect(SecurityDisposition(outcome: .approvedWithoutReview).approved)

        #expect(!SecurityDisposition(outcome: .warned).approved)
        #expect(!SecurityDisposition(outcome: .refused(.unsafe)).approved)
        #expect(!SecurityDisposition(outcome: .refused(.abort)).approved)
        #expect(!SecurityDisposition(outcome: .reviewerUnavailable(.backendUnreachable(failedCalls: 50))).approved)
        #expect(!SecurityDisposition(outcome: .reviewCancelled).approved)
    }

    @Test("wasJudged separates a rendered verdict from a call nothing ruled on")
    func judgementIsDistinctFromApproval() {
        #expect(SecurityDisposition(outcome: .approved).wasJudged)
        #expect(SecurityDisposition(outcome: .warned).wasJudged)
        #expect(SecurityDisposition(outcome: .refused(.unsafe)).wasJudged)
        // Allowed, but by a table rather than a judgement.
        #expect(!SecurityDisposition(outcome: .autoApproved).wasJudged)
        #expect(!SecurityDisposition(outcome: .approvedWithoutReview).wasJudged)
        #expect(!SecurityDisposition(outcome: .reviewerUnavailable(.backendKnownDown)).wasJudged)
        #expect(!SecurityDisposition(outcome: .reviewCancelled).wasJudged)
    }

    // MARK: - What the transcript says

    @Test("No un-judged outcome renders as a verdict in the transcript")
    func channelRowsNeverCallAnOutageAVerdict() async {
        // The regression: a cancelled review printed "Security Agent → Brown: UNSAFE: Evaluation
        // cancelled" because the if-chain had no arm for it and fell into the UNSAFE `else`.
        let unjudged: [SecurityDisposition.Outcome] = [
            .reviewerUnavailable(.backendUnreachable(failedCalls: 50)),
            .reviewerUnavailable(.unparseableVerdict(attempts: 8)),
            .reviewerUnavailable(.backendKnownDown),
            .reviewerUnavailable(.noEvaluatorConfigured),
            .reviewCancelled
        ]
        for outcome in unjudged {
            let captured = CapturedContent()
            await AgentActor.postSecurityReviewToChannel(
                disposition: SecurityDisposition(outcome: outcome, message: "Evaluation cancelled"),
                callID: "c", agentInstanceID: UUID(), roleName: "Brown", agentRoleValue: "brown",
                post: { message in await captured.set(message.content) }
            )
            let content = await captured.value ?? ""
            #expect(!content.contains("UNSAFE"), "\(outcome) rendered as a verdict: \(content)")
            #expect(!content.contains("SAFE"), "\(outcome) implied the call was safe: \(content)")
            #expect(content.contains("BLOCKED") || content.contains("blocked"),
                    "\(outcome) must say the call was blocked: \(content)")
        }
    }

    @Test("Each outcome carries its own wire tag, and blocks never tag as approved")
    func channelTagsAreDistinct() {
        #expect(SecurityDisposition(outcome: .approved).channelTag == "approved")
        #expect(SecurityDisposition(outcome: .autoApproved).channelTag == "autoApproved")
        #expect(SecurityDisposition(outcome: .approvedWithoutReview).channelTag == "reviewDisabled")
        #expect(SecurityDisposition(outcome: .warned).channelTag == "warning")
        #expect(SecurityDisposition(outcome: .refused(.unsafe)).channelTag == "denied")
        #expect(SecurityDisposition(outcome: .refused(.abort)).channelTag == "abort")
        #expect(SecurityDisposition(outcome: .reviewerUnavailable(.backendKnownDown)).channelTag == "unavailable")
        #expect(SecurityDisposition(outcome: .reviewCancelled).channelTag == "cancelled")
    }

    // MARK: - What the worker reads

    @Test("A blocked-but-unjudged call tells the worker not to rewrite its command")
    func blockedResultDoesNotReadAsAVerdict() {
        let text = AgentActor.blockedToolResultMessage(
            SecurityDisposition(outcome: .reviewerUnavailable(.backendUnreachable(failedCalls: 50)),
                                message: "the model backend did not respond")
        )
        #expect(!text.contains("UNSAFE"))
        #expect(!text.contains("denied"))
        #expect(text.contains("NOT a security verdict"))
        // The specific instruction that counters BrownBehavior's "find a new approach" rule.
        #expect(text.contains("Do NOT weaken, rewrite, or split"))
        #expect(text.contains("IDENTICAL"))
        // And it must never assert the command was fine — only that nothing judged it.
        #expect(!text.contains("is safe"))
    }

    @Test("A real refusal still reads as a denial")
    func refusalStillDenies() {
        let text = AgentActor.blockedToolResultMessage(
            SecurityDisposition(outcome: .refused(.unsafe), message: "rm -rf on the home directory")
        )
        #expect(text.contains("denied"))
        #expect(text.contains("rm -rf on the home directory"))
    }

    // MARK: - What becomes permanent task history

    @Test("An un-judged block is never written into the task's progress log")
    func outageDoesNotPinItselfIntoEveryFutureBriefing() {
        // `task.updates` is re-rendered into "## Prior Progress" of every worker briefing, so a
        // line written here follows the task forever, across every respawn.
        for outcome in [SecurityDisposition.Outcome.reviewerUnavailable(.backendKnownDown), .reviewCancelled] {
            #expect(AgentActor.securityDenialUpdateMessage(
                call: call(), disposition: SecurityDisposition(outcome: outcome), isParallelBatch: false
            ) == nil, "\(outcome) must not become durable task history")
        }
    }

    @Test("A real verdict IS written into the task's progress log")
    func verdictsAreStillRecorded() {
        let warn = AgentActor.securityDenialUpdateMessage(
            call: call(), disposition: SecurityDisposition(outcome: .warned, message: "risky"), isParallelBatch: false)
        #expect(warn?.contains("WARN") == true)

        let unsafe = AgentActor.securityDenialUpdateMessage(
            call: call(), disposition: SecurityDisposition(outcome: .refused(.unsafe), message: "no"), isParallelBatch: false)
        #expect(unsafe?.contains("UNSAFE") == true)
    }

    // MARK: - The breaker

    @Test("The breaker opens on the second unreachable result and blocks without another attempt")
    func breakerOpensAfterTwoFailures() async {
        let health = SecurityBackendHealth()
        #expect(await health.admit() == .proceed(probeToken: nil))
        await health.recordUnreachable()
        #expect(await health.isFirstFailureOfStreak())
        #expect(await health.admit() == .proceed(probeToken: nil), "one failure is not yet a pattern")
        await health.recordUnreachable()
        #expect(await health.admit() == .blocked, "the second opens it")
    }

    @Test("A reachable backend closes the breaker and restores the full budget")
    func breakerClosesOnRecovery() async {
        let health = SecurityBackendHealth()
        await health.recordUnreachable()
        // Reduced while the backend is known to be struggling — a probe on the full budget would
        // take about twelve minutes, which would make the cooldown meaningless.
        #expect(await health.transportAttemptBudget() == SecurityBackendHealth.probeAttemptBudget)
        await health.recordUnreachable()
        #expect(await health.admit() == .blocked)

        await health.recordReachable()
        #expect(await health.admit() == .proceed(probeToken: nil))
        #expect(await health.transportAttemptBudget() == LLMRetryPolicy.maxAttempts)
    }

    /// Only ONE probe may be out at a time, however long it takes to come back.
    @Test("A second caller cannot start a probe while one is still out")
    func onlyOneProbeIsEverInFlight() async {
        let health = SecurityBackendHealth()
        await health.recordUnreachable()
        await health.recordUnreachable()

        let past = Date().addingTimeInterval(120)
        guard case .proceed(let token) = await health.admit(now: past), token != nil else {
            Issue.record("the cooldown lapsed — one probe should go")
            return
        }
        // Still within the probe's lease, nobody else goes.
        #expect(await health.admit(now: past.addingTimeInterval(120)) == .blocked)
    }

    /// A probe that never reports back must NOT wedge the breaker permanently. A cancelled
    /// evaluation records no verdict, so without a bound the exclusive slot is held forever and
    /// every tool call in the app is blocked — far worse than the overlap the slot prevents.
    @Test("An abandoned probe releases its slot, and a lost one expires")
    func probeCannotWedgeTheBreakerOpen() async {
        let health = SecurityBackendHealth()
        await health.recordUnreachable()
        await health.recordUnreachable()
        let t0 = Date().addingTimeInterval(120)
        guard case .proceed(let token) = await health.admit(now: t0) else {
            Issue.record("expected a probe"); return
        }

        // Explicit release (the cancellation path).
        await health.abandonProbe(token)
        guard case .proceed = await health.admit(now: t0.addingTimeInterval(61)) else {
            Issue.record("an abandoned probe must free the slot"); return
        }

        // And the backstop: a probe that never reports at all eventually stops blocking.
        let health2 = SecurityBackendHealth()
        await health2.recordUnreachable()
        await health2.recordUnreachable()
        _ = await health2.admit(now: t0)
        #expect(await health2.admit(now: t0.addingTimeInterval(120)) == .blocked, "lease still held")
        guard case .proceed = await health2.admit(now: t0.addingTimeInterval(400)) else {
            Issue.record("a lost probe must not wedge the breaker forever"); return
        }
    }

    /// A straggler evaluation that started BEFORE the breaker opened must not release a probe slot
    /// it never took — that is how two probes end up out at once.
    @Test("An unrelated failure cannot release another caller's probe slot")
    func onlyTheProbeOwnerReleasesTheSlot() async {
        let health = SecurityBackendHealth()
        await health.recordUnreachable()
        await health.recordUnreachable()
        let t0 = Date().addingTimeInterval(120)
        guard case .proceed(let probeToken) = await health.admit(now: t0), probeToken != nil else {
            Issue.record("expected a probe"); return
        }

        // A straggler from before the breaker opened now fails. It carries no probe token.
        await health.recordUnreachable(now: t0, probeToken: nil)
        #expect(await health.admit(now: t0.addingTimeInterval(61)) == .blocked,
                "the straggler released a slot it never held — two probes are now out")
    }

    /// A probe that SUCCEEDS clears everything, so the breaker admits normally again.
    @Test("A successful probe fully closes the breaker")
    func successfulProbeClosesTheBreaker() async {
        let health = SecurityBackendHealth()
        await health.recordUnreachable()
        await health.recordUnreachable()
        let t0 = Date().addingTimeInterval(120)
        guard case .proceed(let token) = await health.admit(now: t0) else {
            Issue.record("expected a probe"); return
        }
        await health.recordReachable(probeToken: token)

        #expect(await health.admit() == .proceed(probeToken: nil))
        #expect(await health.transportAttemptBudget() == LLMRetryPolicy.maxAttempts)
    }
}
