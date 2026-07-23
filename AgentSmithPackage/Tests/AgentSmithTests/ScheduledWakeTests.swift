import Testing
import Foundation
@testable import AgentSmithKit

/// Tests for the `WakeScheduler` scheduling primitive — the surface behind Smith's
/// `schedule_wake` / `cancel_wake` / `list_scheduled_wakes` tools and the cross-actor
/// `cancelWakesForTask` cleanup hook. Behavioral guarantees covered:
///   - Multiple wakes can coexist at any time gap (no minimum spacing).
///   - `replacesID` removes the named wake before scheduling, atomically.
///   - `cancelWake(id:)` returns true only when something was actually removed.
///   - `cancelWakesForTask(_:)` returns the cancelled wakes' IDs and only touches that task's,
///     preserving `survivesTaskTermination` wakes.
///   - `listScheduledWakes()` returns the wakes sorted ascending by `wakeAt`.
///   - Empty / whitespace `instructions` is rejected via `.error(...)`, not `.scheduled`.
@Suite("WakeScheduler scheduled wakes", .serialized)
struct ScheduledWakeTests {

    /// Returns a wake from a `ScheduleWakeOutcome.scheduled(...)` outcome, failing the test otherwise.
    private static func scheduledOrFail(_ outcome: ScheduleWakeOutcome, comment: Comment) -> ScheduledWake? {
        switch outcome {
        case .scheduled(let wake):
            return wake
        case .error(let message):
            Issue.record("\(comment) — got error: \(message)")
            return nil
        }
    }

    // MARK: - Basic scheduling

    @Test("schedule_wake returns .scheduled with the requested time and reason")
    func basicSchedule() async {
        let scheduler = WakeScheduler()
        let when = Date().addingTimeInterval(60)
        let outcome = await scheduler.scheduleWake(wakeAt: when, instructions: "ping me")
        guard let wake = Self.scheduledOrFail(outcome, comment: "first scheduling should succeed") else { return }
        #expect(wake.instructions == "ping me")
        #expect(wake.wakeAt == when)
        #expect(wake.taskID == nil)
    }

    @Test("schedule_wake rejects empty reason")
    func emptyReasonRejected() async {
        let scheduler = WakeScheduler()
        let outcome = await scheduler.scheduleWake(wakeAt: Date().addingTimeInterval(60), instructions: "")
        switch outcome {
        case .scheduled: Issue.record("empty reason should have been rejected")
        case .error(let message): #expect(message.contains("instructions"))
        }
    }

    @Test("schedule_wake rejects whitespace-only reason")
    func whitespaceReasonRejected() async {
        let scheduler = WakeScheduler()
        let outcome = await scheduler.scheduleWake(wakeAt: Date().addingTimeInterval(60), instructions: "   \n\t  ")
        switch outcome {
        case .scheduled: Issue.record("whitespace-only reason should have been rejected")
        case .error: break
        }
    }

    // MARK: - Coexistence (no spacing minimum)

    @Test("multiple wakes within seconds of each other coexist (no 60s minimum)")
    func wakesCanShareNearTimes() async {
        let scheduler = WakeScheduler()
        let baseTime = Date().addingTimeInterval(60)
        _ = await scheduler.scheduleWake(wakeAt: baseTime, instructions: "first")
        _ = await scheduler.scheduleWake(wakeAt: baseTime.addingTimeInterval(5), instructions: "second")
        _ = await scheduler.scheduleWake(wakeAt: baseTime.addingTimeInterval(30), instructions: "third")

        let listed = await scheduler.listScheduledWakes()
        #expect(listed.count == 3)
        #expect(listed[0].instructions == "first")
        #expect(listed[1].instructions == "second")
        #expect(listed[2].instructions == "third")
    }

    @Test("wakes scheduled at the exact same time both stick")
    func wakesAtSameTimeCoexist() async {
        let scheduler = WakeScheduler()
        let when = Date().addingTimeInterval(120)
        _ = await scheduler.scheduleWake(wakeAt: when, instructions: "a")
        _ = await scheduler.scheduleWake(wakeAt: when, instructions: "b")
        #expect(await scheduler.listScheduledWakes().count == 2)
    }

    // MARK: - replacesID semantics

    @Test("replacesID removes the named wake before scheduling the new one")
    func replacesRemovesPriorWake() async {
        let scheduler = WakeScheduler()
        let firstOutcome = await scheduler.scheduleWake(wakeAt: Date().addingTimeInterval(60), instructions: "old reason")
        guard let firstWake = Self.scheduledOrFail(firstOutcome, comment: "initial") else { return }

        _ = await scheduler.scheduleWake(wakeAt: Date().addingTimeInterval(120), instructions: "new reason", replacesID: firstWake.id)

        let listed = await scheduler.listScheduledWakes()
        #expect(listed.count == 1)
        #expect(listed.first?.instructions == "new reason")
        #expect(listed.contains { $0.id == firstWake.id } == false)
    }

    @Test("replacesID with an unknown id is a no-op (still schedules the new wake)")
    func replacesUnknownIdIsNoop() async {
        let scheduler = WakeScheduler()
        _ = await scheduler.scheduleWake(wakeAt: Date().addingTimeInterval(60), instructions: "fresh", replacesID: UUID())
        #expect(await scheduler.listScheduledWakes().count == 1)
    }

    // MARK: - Cancellation

    @Test("cancelWake by id returns true exactly once for an existing wake")
    func cancelWakeReturnsTrueOnce() async {
        let scheduler = WakeScheduler()
        let outcome = await scheduler.scheduleWake(wakeAt: Date().addingTimeInterval(60), instructions: "x")
        guard let wake = Self.scheduledOrFail(outcome, comment: "set up") else { return }

        #expect(await scheduler.cancelWake(id: wake.id) == true)
        #expect(await scheduler.cancelWake(id: wake.id) == false)
    }

    @Test("cancelWake by unknown id returns false and leaves other wakes intact")
    func cancelUnknownIdReturnsFalse() async {
        let scheduler = WakeScheduler()
        _ = await scheduler.scheduleWake(wakeAt: Date().addingTimeInterval(60), instructions: "kept")
        #expect(await scheduler.cancelWake(id: UUID()) == false)
        #expect(await scheduler.listScheduledWakes().count == 1)
    }

    @Test("cancelWakesForTask returns only the cancelled IDs and leaves others")
    func cancelWakesForTaskScopedCorrectly() async {
        let scheduler = WakeScheduler()
        let taskA = UUID()
        let taskB = UUID()

        let a1 = await scheduler.scheduleWake(wakeAt: Date().addingTimeInterval(30), instructions: "a-1", taskID: taskA)
        let a2 = await scheduler.scheduleWake(wakeAt: Date().addingTimeInterval(60), instructions: "a-2", taskID: taskA)
        let b1 = await scheduler.scheduleWake(wakeAt: Date().addingTimeInterval(45), instructions: "b-1", taskID: taskB)
        let untagged = await scheduler.scheduleWake(wakeAt: Date().addingTimeInterval(90), instructions: "u")
        guard let aw1 = Self.scheduledOrFail(a1, comment: "a-1"),
              let aw2 = Self.scheduledOrFail(a2, comment: "a-2"),
              Self.scheduledOrFail(b1, comment: "b-1") != nil,
              Self.scheduledOrFail(untagged, comment: "untagged") != nil else { return }

        let cancelledIDs = await scheduler.cancelWakesForTask(taskA)
        #expect(Set(cancelledIDs) == Set([aw1.id, aw2.id]))

        let listed = await scheduler.listScheduledWakes()
        let listedIDs = Set(listed.map { $0.id })
        #expect(listedIDs.contains(aw1.id) == false)
        #expect(listedIDs.contains(aw2.id) == false)
        #expect(listed.count == 2)
        #expect(listed.contains { $0.instructions == "b-1" })
        #expect(listed.contains { $0.instructions == "u" })
    }

    @Test("cancelWakesForTask on a task with no wakes returns empty")
    func cancelWakesForTaskEmpty() async {
        let scheduler = WakeScheduler()
        #expect(await scheduler.cancelWakesForTask(UUID()).isEmpty)
    }

    @Test("cancelWakesForTask preserves wakes flagged survivesTaskTermination")
    func cancelWakesForTaskPreservesSurvivors() async {
        let scheduler = WakeScheduler()
        let taskID = UUID()

        let cancellable = await scheduler.scheduleWake(wakeAt: Date().addingTimeInterval(30), instructions: "pause", taskID: taskID, survivesTaskTermination: false)
        let surviving1 = await scheduler.scheduleWake(wakeAt: Date().addingTimeInterval(60), instructions: "run-again-1", taskID: taskID, survivesTaskTermination: true)
        let surviving2 = await scheduler.scheduleWake(wakeAt: Date().addingTimeInterval(90), instructions: "run-again-2", taskID: taskID, survivesTaskTermination: true)
        guard let cw = Self.scheduledOrFail(cancellable, comment: "cancellable"),
              let sw1 = Self.scheduledOrFail(surviving1, comment: "surviving-1"),
              let sw2 = Self.scheduledOrFail(surviving2, comment: "surviving-2") else { return }

        let cancelledIDs = await scheduler.cancelWakesForTask(taskID)
        #expect(cancelledIDs == [cw.id])

        let listedIDs = Set(await scheduler.listScheduledWakes().map { $0.id })
        #expect(listedIDs == Set([sw1.id, sw2.id]))
    }

    // MARK: - Listing order

    @Test("listScheduledWakes returns wakes sorted ascending by wakeAt regardless of insertion order")
    func listingIsSortedAscending() async {
        let scheduler = WakeScheduler()
        _ = await scheduler.scheduleWake(wakeAt: Date().addingTimeInterval(60),  instructions: "60")
        _ = await scheduler.scheduleWake(wakeAt: Date().addingTimeInterval(10),  instructions: "10")
        _ = await scheduler.scheduleWake(wakeAt: Date().addingTimeInterval(120), instructions: "120")
        _ = await scheduler.scheduleWake(wakeAt: Date().addingTimeInterval(30),  instructions: "30")

        let reasons = await scheduler.listScheduledWakes().map { $0.instructions }
        #expect(reasons == ["10", "30", "60", "120"])
    }
}
