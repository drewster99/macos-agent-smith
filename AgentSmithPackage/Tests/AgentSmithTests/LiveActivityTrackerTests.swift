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
        tracker.beginSecurityEvaluation(callID: "call_0", agentInstanceID: agentA)
        tracker.beginSecurityEvaluation(callID: "call_0", agentInstanceID: agentB)

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
        tracker.beginSecurityEvaluation(callID: "", agentInstanceID: UUID())
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

        // EVERY publishing mutator, not just the two security ones — a version bump missing from
        // `adjust`, `setBrownWorkers` or the sweep would let a stale snapshot from that path win
        // the delivery race, and a test covering only begin/end would stay green through it.
        tracker.beginSecurityEvaluation(callID: "a", agentInstanceID: agent)
        tracker.beginSecurityEvaluation(callID: "b", agentInstanceID: agent)
        tracker.begin(.validatorEvaluation)
        tracker.setBrownWorkers(source: ObjectIdentifier(Self.self), to: 2)
        tracker.end(.validatorEvaluation)
        tracker.endSecurityEvaluation(callID: "a", agentInstanceID: agent)
        tracker.endSecurityEvaluations(forAgentInstanceID: agent)

        let versions = recorder.versions
        #expect(versions.count >= 7)
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
        tracker.beginSecurityEvaluation(callID: "a", agentInstanceID: agent)
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
        tracker.beginSecurityEvaluation(callID: "x", agentInstanceID: stopping)
        tracker.beginSecurityEvaluation(callID: "y", agentInstanceID: stopping)
        tracker.beginSecurityEvaluation(callID: "z", agentInstanceID: survivor)

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

    @Test("A stale delivery is refused, and an equal-version one is not")
    func supersedesOrdersDeliveries() {
        // Mutators publish AFTER releasing the lock and each delivery hops the main actor
        // separately, so neither step preserves mutation order. This is the rule the app-side
        // mirror applies to drop a stale snapshot that lands last — it lives in the Kit precisely
        // so it can be tested, since the app target has no test bundle.
        let tracker = makeTracker()
        let agent = UUID()
        let first = tracker.current()

        tracker.beginSecurityEvaluation(callID: "a", agentInstanceID: agent)
        let second = tracker.current()
        tracker.endSecurityEvaluation(callID: "a", agentInstanceID: agent)
        let third = tracker.current()

        #expect(second.supersedes(first))
        #expect(third.supersedes(second))
        // The stale one arriving late must be refused — this is the freeze it prevents.
        #expect(!first.supersedes(second))
        #expect(!second.supersedes(third))
        // First delivery: `setOnChange` republishes existing state without bumping, so an
        // equal-version snapshot has to be ACCEPTED or the mirror never populates at launch.
        #expect(first.supersedes(first))
    }

    @Test("Equality ignores the version, so a content-identical publish is not a change")
    func equalityIgnoresVersion() {
        // `version` changes on every publish. If it participated in `==`, every observer keyed on
        // the snapshot would fire on publishes that changed nothing — undoing the no-op-publish
        // suppression a few lines away.
        let tracker = makeTracker()
        let agent = UUID()
        tracker.beginSecurityEvaluation(callID: "a", agentInstanceID: agent)
        let before = tracker.current()
        tracker.begin(.memorySearch)
        tracker.end(.memorySearch)
        let after = tracker.current()

        #expect(after.version > before.version, "the publishes must still be ordered")
        #expect(after == before, "identical content must compare equal despite a newer version")
    }

    @Test("Every stored property except `version` participates in equality")
    func equalityCoversEveryStoredProperty() {
        // `Snapshot`'s `==` is HAND-WRITTEN so it can exclude `version`, which changes on every
        // publish. That costs the synthesised conformance, and the resulting footgun is the same
        // one `ledgerCodingKeyCoverage` guards against for `CodingKeys`: a stored property added
        // later is silently absent from `==`, so two genuinely different snapshots compare equal,
        // every observer stops updating on that field, and nothing fails.
        //
        // Guarded by REFLECTION rather than by a round trip: a field missing from `==` still
        // round-trips fine, so only counting the properties catches it.
        let base = LiveActivityTracker.Snapshot()
        let storedPropertyCount = Mirror(reflecting: base).children.count

        // One mutator per property that MUST break equality.
        let mutators: [(inout LiveActivityTracker.Snapshot) -> Void] = [
            { $0.brownWorkers += 1 },
            { $0.validatorEvaluations += 1 },
            { $0.summarizerRuns += 1 },
            { $0.memorySearches += 1 },
            { $0.securityEvaluationsByCall.insert(
                LiveActivityTracker.SecurityEvaluationKey(agentInstanceID: UUID(), callID: "c")
            ) }
        ]

        #expect(
            storedPropertyCount == mutators.count + 1,
            "A stored property was added to Snapshot without deciding whether it belongs in `==`. Add it to the hand-written `==` and add a mutator here, or — if it is like `version` and must NOT affect equality — raise the `+ 1`."
        )

        for (index, mutate) in mutators.enumerated() {
            var changed = base
            mutate(&changed)
            #expect(changed != base, "mutator \(index) did not break equality")
        }

        // And the one exclusion, asserted rather than assumed.
        var bumped = base
        bumped.version &+= 1
        #expect(bumped == base, "`version` must not participate in equality")
    }

    @Test("isIdle reflects live evaluations")
    func idleAccountsForSecurityEvaluations() {
        let tracker = makeTracker()
        let agent = UUID()
        #expect(tracker.current().isIdle)
        tracker.beginSecurityEvaluation(callID: "a", agentInstanceID: agent)
        #expect(!tracker.current().isIdle)
        tracker.endSecurityEvaluation(callID: "a", agentInstanceID: agent)
        #expect(tracker.current().isIdle)
    }
}
