import Testing
import Foundation
@testable import AgentSmithKit
import SwiftLLMKit

/// `InspectorCallLog` makes bounded inspector retention honest: stable lifetime ordinals,
/// visible eviction, and an explicit reason whenever a full request snapshot is absent.
@Suite("InspectorCallLog")
struct InspectorCallLogTests {

    private func turn(_ label: String, withSnapshot: Bool = true) -> LLMTurnRecord {
        LLMTurnRecord(
            inputDelta: [.user(label)],
            response: LLMResponse(text: "reply to \(label)"),
            totalMessageCount: 1,
            contextSnapshot: withSnapshot ? [.system("sys"), .user(label)] : []
        )
    }

    private func failure(_ message: String) -> LLMCallFailureRecord {
        LLMCallFailureRecord(
            latencyMs: 12,
            modelID: "m",
            providerID: "p",
            disposition: .transient,
            errorDescription: message
        )
    }

    private func completedTurn(_ entry: InspectorCallLog.Entry) -> LLMTurnRecord? {
        if case .completed(_, let turn, _) = entry { return turn }
        return nil
    }

    private func snapshot(_ entry: InspectorCallLog.Entry) -> InspectorCallLog.SnapshotRetention? {
        if case .completed(_, _, let snapshot) = entry { return snapshot }
        return nil
    }

    @Test("ordinals are 1-based lifetime positions")
    func ordinalsAreLifetimePositions() {
        var log = InspectorCallLog(capacity: 10, snapshotWindow: 10)
        log.append(.completed(turn("a")))
        log.append(.failed(failure("boom")))
        log.append(.completed(turn("b")))
        #expect(log.entries.map(\.ordinal) == [1, 2, 3])
        #expect(log.lifetimeCount == 3)
        #expect(log.lifetimeFailureCount == 1)
        #expect(log.evictedCount == 0)
        #expect(log.retainedTurns.map(\.response.text) == ["reply to a", "reply to b"])
    }

    @Test("eviction keeps surviving rows' original ordinals and reports the lifetime total")
    func evictionKeepsStableOrdinals() {
        var log = InspectorCallLog(capacity: 100, snapshotWindow: 10)
        for index in 1...143 {
            log.append(.completed(turn("t\(index)")))
        }
        #expect(log.entries.count == 100)
        #expect(log.lifetimeCount == 143)
        #expect(log.evictedCount == 43)
        #expect(log.entries.first?.ordinal == 44, "lifetime call 44 must not be renumbered to 1")
        #expect(log.entries.last?.ordinal == 143)
        #expect(log.retainedTurns.count == 100)
        #expect(log.retainedTurns.first?.inputDelta == [.user("t44")])
    }

    @Test("evicting failures keeps retainedTurns aligned with the completed entries")
    func evictingMixedEntriesKeepsTurnsAligned() {
        var log = InspectorCallLog(capacity: 3, snapshotWindow: 3)
        log.append(.failed(failure("f1")))
        log.append(.completed(turn("a")))
        log.append(.failed(failure("f2")))
        log.append(.completed(turn("b")))
        log.append(.completed(turn("c")))
        #expect(log.entries.map(\.ordinal) == [3, 4, 5])
        #expect(log.retainedTurns.map(\.inputDelta) == [[.user("b")], [.user("c")]])
        #expect(log.entries.compactMap(completedTurn) == log.retainedTurns)
        #expect(log.lifetimeFailureCount == 2)
    }

    @Test("only the newest completed turns keep their snapshot; older ones say it was released")
    func snapshotWindowReleasesOlderSnapshots() {
        var log = InspectorCallLog(capacity: 100, snapshotWindow: 10)
        for index in 1...15 {
            log.append(.completed(turn("t\(index)")))
            // Failures don't count against the snapshot window.
            log.append(.failed(failure("f\(index)")))
        }
        let completed = log.entries.filter { completedTurn($0) != nil }
        let released = completed.prefix(5)
        let kept = completed.suffix(10)
        #expect(released.allSatisfy { snapshot($0) == .discardedByRetention })
        #expect(released.allSatisfy { completedTurn($0)?.contextSnapshot.isEmpty == true })
        #expect(kept.allSatisfy { snapshot($0) == .retained })
        #expect(kept.allSatisfy { completedTurn($0)?.contextSnapshot.isEmpty == false })
        #expect(log.retainedTurns.prefix(5).allSatisfy { $0.contextSnapshot.isEmpty })
        #expect(log.retainedTurns.suffix(10).allSatisfy { !$0.contextSnapshot.isEmpty })
    }

    @Test("a turn that arrived without a snapshot is 'not captured', never 'released'")
    func uncapturedSnapshotIsDistinct() {
        var log = InspectorCallLog(capacity: 100, snapshotWindow: 1)
        log.append(.completed(turn("none", withSnapshot: false)))
        log.append(.completed(turn("a")))
        log.append(.completed(turn("b")))
        #expect(log.entries.map(snapshot) == [.notCaptured, .discardedByRetention, .retained])
    }

    @Test("a zero snapshot window releases every snapshot immediately")
    func zeroWindowReleasesEverything() {
        var log = InspectorCallLog(capacity: 5, snapshotWindow: 0)
        log.append(.completed(turn("a")))
        #expect(log.entries.map(snapshot) == [.discardedByRetention])
        #expect(log.retainedTurns.first?.contextSnapshot.isEmpty == true)
    }

    @Test("failed-attempt records classify by the shared retry policy")
    func failureDispositionFollowsRetryPolicy() {
        let start = Date(timeIntervalSince1970: 1_000)
        let now = start.addingTimeInterval(1.5)
        let cancelled = LLMCallFailureRecord(error: CancellationError(), startedAt: start,
                                             modelID: "m", providerID: nil, now: now)
        #expect(cancelled.disposition == .cancelled)
        #expect(cancelled.latencyMs == 1_500)

        let permanent = LLMCallFailureRecord(
            error: LLMProviderError.httpError(statusCode: 401, body: "bad key"),
            startedAt: start, modelID: "m", providerID: nil, now: now)
        #expect(permanent.disposition == .permanent)

        let urlCancelled = LLMCallFailureRecord(error: URLError(.cancelled), startedAt: start,
                                                modelID: "m", providerID: nil, now: now)
        #expect(urlCancelled.disposition == .cancelled, "a stopped URLSession request is cancelled, not a transient failure")

        let transient = LLMCallFailureRecord(
            error: LLMProviderError.httpError(statusCode: 503, body: "busy"),
            startedAt: start, modelID: "m", providerID: nil, now: now)
        #expect(transient.disposition == .transient)
    }

    @Test("releasing a self-contained call's snapshot releases its outgoing request too")
    func selfContainedReleaseFreesTheRequest() {
        var log = InspectorCallLog(capacity: 10, snapshotWindow: 1)
        let request: [LLMMessage] = [.system("s"), .user("review this")]
        let selfContained = LLMTurnRecord(inputDelta: [], response: LLMResponse(text: "SAFE"), totalMessageCount: 2,
                                          contextSnapshot: request, isSelfContainedRequest: true)
        log.append(.completed(selfContained))
        #expect(log.retainedTurns.first?.outgoingMessages == request)
        log.append(.completed(turn("newer")))
        #expect(log.entries.first.flatMap(snapshot) == .discardedByRetention)
        #expect(log.retainedTurns.first?.outgoingMessages.isEmpty == true,
                "nothing may keep the released request alive")
    }
}
