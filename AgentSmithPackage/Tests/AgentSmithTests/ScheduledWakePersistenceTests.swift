import Testing
import Foundation
@testable import AgentSmithKit

/// Tests the scheduled-wake persistence path that lets reminders survive an app quit.
/// Three guarantees worth pinning down:
///   1. Round-trip: a wake encoded via `JSONEncoder` and decoded back is value-equal.
///   2. `restoreScheduledWakes` replaces the actor's list (not merge), with sort.
///   3. Wakes whose `wakeAt` is already in the past are kept on restore — the production
///      run loop will then fire them on the next iteration, which is the recovery path
///      for "the timer would have fired while the app was quit."
@Suite("Scheduled wake persistence", .serialized)
struct ScheduledWakePersistenceTests {

    @Test("ScheduledWake round-trips through JSON unchanged")
    func roundTripThroughJSON() throws {
        let recurrence = Recurrence.weekly(at: TimeOfDay(hour: 9, minute: 30), on: [.monday, .friday])
        let original = ScheduledWake(
            wakeAt: Date(timeIntervalSince1970: 800_000_000),
            instructions: "Tell Drew to take a break",
            taskID: UUID(uuidString: "00000000-0000-0000-0000-00000000ABCD"),
            recurrence: recurrence
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ScheduledWake.self, from: encoded)
        #expect(decoded == original)
    }

    @Test("restore replaces the scheduler's list with a sorted copy")
    func restoreSortsAndReplaces() async {
        let scheduler = WakeScheduler()
        _ = await scheduler.scheduleWake(wakeAt: Date().addingTimeInterval(60), instructions: "old-1")
        _ = await scheduler.scheduleWake(wakeAt: Date().addingTimeInterval(120), instructions: "old-2")

        let now = Date()
        await scheduler.restore([
            ScheduledWake(wakeAt: now.addingTimeInterval(300), instructions: "later"),
            ScheduledWake(wakeAt: now.addingTimeInterval(30),  instructions: "soon")
        ])
        let listed = await scheduler.listScheduledWakes()
        #expect(listed.count == 2)
        #expect(listed.first?.instructions == "soon")
        #expect(listed.last?.instructions == "later")
    }

    @Test("restore keeps already-elapsed wakes so the armed timer fires them (catch-up)")
    func keepsElapsedWakes() async {
        let scheduler = WakeScheduler()
        let elapsed = ScheduledWake(wakeAt: Date().addingTimeInterval(-3600), instructions: "should-fire-on-catch-up")
        await scheduler.restore([elapsed])
        let listed = await scheduler.listScheduledWakes()
        #expect(listed.count == 1)
        #expect(listed.first?.instructions == "should-fire-on-catch-up")
    }
}
