import Foundation
import Testing
@testable import AgentSmithKit

/// `LiveActivityTracker`'s security-evaluation registry — the single source of truth for "the
/// Security Agent is evaluating this call", from which the Agents tally, a worker's "waiting on
/// security", and each tool row's marker are all derived.
///
/// This type had no tests at all, and the two defects found in review were both of the kind that a
/// synchronous test catches immediately: a key collision between agents, and a stale snapshot
/// winning a delivery race.
@Suite("Live activity tracker — security registry")
struct LiveActivityTrackerTests {

    private func makeTracker() -> LiveActivityTracker { LiveActivityTracker() }

    /// Collects published snapshots from the tracker's `@Sendable` callback, which Swift 6 will
    /// not let close over a mutable local.
    private final class PublishRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [UInt64] = []
        func record(_ version: UInt64) {
            lock.lock(); storage.append(version); lock.unlock()
        }
        var versions: [UInt64] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
        var count: Int { versions.count }
    }

    @Test("Two agents can hold the same provider call id without colliding")
    func sameCallIDFromDifferentAgentsDoesNotCollide() {
        // Some OpenAI-compatible servers emit per-response index ids, so `call_0` from two agents
        // is ordinary, not exotic. Keying on the call id alone made the second registration
        // overwrite the first — under-counting the meter and, worse, making the first agent's
        // `isAwaitingSecurity` read FALSE while it was genuinely blocked.
        let tracker = makeTracker()
        let agentA = UUID()
        let agentB = UUID()
        tracker.beginSecurityEvaluation(callID: "call_0", agentInstanceID: agentA, startedAt: Date())
        tracker.beginSecurityEvaluation(callID: "call_0", agentInstanceID: agentB, startedAt: Date())

        #expect(tracker.current().securityEvaluations == 2)
        #expect(tracker.current().isAwaitingSecurity(agentInstanceID: agentA))
        #expect(tracker.current().isAwaitingSecurity(agentInstanceID: agentB))
        #expect(tracker.current().isEvaluating(callID: "call_0", agentInstanceID: agentA))
        #expect(tracker.current().isEvaluating(callID: "call_0", agentInstanceID: agentB))

        // And one finishing must not clear the other's entry.
        tracker.endSecurityEvaluation(callID: "call_0", agentInstanceID: agentA)
        #expect(tracker.current().securityEvaluations == 1)
        #expect(!tracker.current().isAwaitingSecurity(agentInstanceID: agentA))
        #expect(tracker.current().isAwaitingSecurity(agentInstanceID: agentB))
    }

    @Test("An empty call id is refused rather than sharing one entry app-wide")
    func emptyCallIDIsNotRegistered() {
        // The provider guard rejects a MISSING id, not an empty one, so `""` reaches the tracker.
        // Every empty-id call would otherwise share a single key.
        let tracker = makeTracker()
        tracker.beginSecurityEvaluation(callID: "", agentInstanceID: UUID(), startedAt: Date())
        #expect(tracker.current().securityEvaluations == 0)
    }

    @Test("Every snapshot published carries a strictly increasing version")
    func snapshotVersionIsMonotonic() {
        // Mutators publish AFTER releasing the lock, so delivery order isn't mutation order. The
        // version is what lets an observer drop a stale snapshot that lands last — without it, the
        // meter sticks above zero and a worker reads "waiting on security" indefinitely.
        let tracker = makeTracker()
        let agent = UUID()
        let recorder = PublishRecorder()
        tracker.setOnChange { snapshot in recorder.record(snapshot.version) }

        tracker.beginSecurityEvaluation(callID: "a", agentInstanceID: agent, startedAt: Date())
        tracker.beginSecurityEvaluation(callID: "b", agentInstanceID: agent, startedAt: Date())
        tracker.endSecurityEvaluation(callID: "a", agentInstanceID: agent)
        tracker.endSecurityEvaluation(callID: "b", agentInstanceID: agent)

        let versions = recorder.versions
        #expect(versions.count >= 4)
        #expect(versions == versions.sorted(), "versions must never go backwards: \(versions)")
        #expect(Set(versions).count == versions.count, "versions must be distinct: \(versions)")
    }

    @Test("Ending an unregistered call publishes nothing")
    func idempotentEndDoesNotPublish() {
        // The teardown sweep and `evaluate()`'s own defer both fire for the same call by design, so
        // the redundant one must be free — each publish costs a main-actor hop and a full
        // inspector recompute that reverse-scans the transcript.
        let tracker = makeTracker()
        let agent = UUID()
        tracker.beginSecurityEvaluation(callID: "a", agentInstanceID: agent, startedAt: Date())
        let recorder = PublishRecorder()
        tracker.setOnChange { snapshot in recorder.record(snapshot.version) }
        let afterAttach = recorder.count  // setOnChange delivers current state immediately

        tracker.endSecurityEvaluation(callID: "a", agentInstanceID: agent)
        #expect(recorder.count == afterAttach + 1)

        tracker.endSecurityEvaluation(callID: "a", agentInstanceID: agent)
        tracker.endSecurityEvaluation(callID: "never-registered", agentInstanceID: agent)
        #expect(recorder.count == afterAttach + 1, "a no-op end must not publish")
    }

    @Test("Teardown drops one agent's evaluations and leaves every other agent's alone")
    func teardownSweepIsScopedToOneAgent() {
        // A turn cancelled mid-flight leaves its registration standing until the LLM call returns,
        // which a hung provider may never do promptly — so `stop()` sweeps. It must not take the
        // other concurrent workers' entries with it.
        let tracker = makeTracker()
        let stopping = UUID()
        let survivor = UUID()
        tracker.beginSecurityEvaluation(callID: "x", agentInstanceID: stopping, startedAt: Date())
        tracker.beginSecurityEvaluation(callID: "y", agentInstanceID: stopping, startedAt: Date())
        tracker.beginSecurityEvaluation(callID: "z", agentInstanceID: survivor, startedAt: Date())

        tracker.endSecurityEvaluations(forAgentInstanceID: stopping)

        #expect(tracker.current().securityEvaluations == 1)
        #expect(!tracker.current().isAwaitingSecurity(agentInstanceID: stopping))
        #expect(tracker.current().isAwaitingSecurity(agentInstanceID: survivor))

        // Sweeping again changes nothing and publishes nothing.
        let recorder = PublishRecorder()
        tracker.setOnChange { snapshot in recorder.record(snapshot.version) }
        let afterAttach = recorder.count
        tracker.endSecurityEvaluations(forAgentInstanceID: stopping)
        #expect(recorder.count == afterAttach, "a no-op sweep must not publish")
    }

    @Test("isIdle reflects live evaluations")
    func idleAccountsForSecurityEvaluations() {
        let tracker = makeTracker()
        let agent = UUID()
        #expect(tracker.current().isIdle)
        tracker.beginSecurityEvaluation(callID: "a", agentInstanceID: agent, startedAt: Date())
        #expect(!tracker.current().isIdle)
        tracker.endSecurityEvaluation(callID: "a", agentInstanceID: agent)
        #expect(tracker.current().isIdle)
    }
}
