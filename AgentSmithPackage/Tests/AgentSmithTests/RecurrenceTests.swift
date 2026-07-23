import Testing
import Foundation
@testable import AgentSmithKit

/// Behavioral tests for the `Recurrence` enum's `nextOccurrence(after:)`. The
/// production code uses these to re-schedule recurring wakes after each fire — getting the
/// math right matters because a one-minute drift compounds across daily/weekly cycles.
@Suite("Recurrence next-occurrence")
struct RecurrenceTests {

    private static let utc = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    private static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min; c.second = 0
        c.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: {
            var copy = c; copy.timeZone = TimeZone(identifier: "UTC"); return copy
        }())!
    }

    // MARK: - Daily

    @Test("daily recurrence returns the next 21:00 today when current time is before 21:00")
    func dailySameDay() {
        let recurrence = Recurrence.daily(at: TimeOfDay(hour: 21, minute: 0))
        let now = Self.date(2026, 4, 25, 19, 30)
        let next = recurrence.nextOccurrence(after: now, calendar: Self.utc)
        #expect(next == Self.date(2026, 4, 25, 21, 0))
    }

    @Test("daily recurrence skips to the next day when current time is past today's fire time")
    func dailyNextDay() {
        let recurrence = Recurrence.daily(at: TimeOfDay(hour: 9, minute: 0))
        let now = Self.date(2026, 4, 25, 10, 0)
        let next = recurrence.nextOccurrence(after: now, calendar: Self.utc)
        #expect(next == Self.date(2026, 4, 26, 9, 0))
    }

    // MARK: - Catch-up collapse (restart storm guard)

    @Test("interval catch-up collapses a day-stale wake to ONE future occurrence, not 1440")
    func intervalCatchUpCollapses() {
        // A 60-second reminder whose last fire was a full day before `now`. The naive
        // nextOccurrence(after:) would return after+60s (still ~a day in the past), which the
        // run loop would re-fire once per elapsed period until caught up. The catch-up variant
        // must jump straight to the first fire strictly after `now`.
        let recurrence = Recurrence.interval(seconds: 60)
        let lastFire = Self.date(2026, 4, 24, 9, 0)
        let now = Self.date(2026, 4, 25, 9, 0)
        let next = recurrence.nextOccurrence(after: lastFire, notBefore: now, calendar: Self.utc)
        let unwrapped = try! #require(next)
        #expect(unwrapped > now, "successor must be in the future")
        #expect(unwrapped.timeIntervalSince(now) <= 60, "and within one period — a single collapsed occurrence")
        // Proof this differs from the naive step, which stays stale.
        #expect(recurrence.nextOccurrence(after: lastFire, calendar: Self.utc)! < now)
    }

    @Test("daily catch-up collapses a 5-day-stale wake to the next single 09:00 after now")
    func dailyCatchUpCollapses() {
        let recurrence = Recurrence.daily(at: TimeOfDay(hour: 9, minute: 0))
        let lastFire = Self.date(2026, 4, 20, 9, 0)
        let now = Self.date(2026, 4, 25, 10, 0)   // past today's 09:00
        let next = recurrence.nextOccurrence(after: lastFire, notBefore: now, calendar: Self.utc)
        #expect(next == Self.date(2026, 4, 26, 9, 0))
    }

    @Test("on-time fire is unchanged — catch-up variant matches the plain next occurrence")
    func onTimeFireMatchesPlain() {
        let recurrence = Recurrence.interval(seconds: 3600)
        let fire = Self.date(2026, 4, 25, 9, 0)
        // after == notBefore (fired exactly on time): normal cadence, one period later.
        let collapsed = recurrence.nextOccurrence(after: fire, notBefore: fire, calendar: Self.utc)
        #expect(collapsed == recurrence.nextOccurrence(after: fire, calendar: Self.utc))
        #expect(collapsed == Self.date(2026, 4, 25, 10, 0))
    }

    // MARK: - Weekly

    @Test("weekly recurrence picks the next matching weekday")
    func weeklyNextWeekday() {
        // Saturday Apr 25 2026 → next Mon/Wed/Fri at 15:00 should be Mon Apr 27.
        let recurrence = Recurrence.weekly(at: TimeOfDay(hour: 15, minute: 0), on: [.monday, .wednesday, .friday])
        let now = Self.date(2026, 4, 25, 12, 0)
        let next = recurrence.nextOccurrence(after: now, calendar: Self.utc)
        #expect(next == Self.date(2026, 4, 27, 15, 0))
    }

    @Test("weekly recurrence with empty weekday set returns nil")
    func weeklyEmptySetReturnsNil() {
        let recurrence = Recurrence.weekly(at: TimeOfDay(hour: 15, minute: 0), on: [])
        let now = Self.date(2026, 4, 25, 12, 0)
        let next = recurrence.nextOccurrence(after: now, calendar: Self.utc)
        #expect(next == nil)
    }

    @Test("weekly recurrence on the same weekday but past time picks next week's same day")
    func weeklySameWeekdayPastTime() {
        // Saturday Apr 25 17:00 → next Saturday-only-at-15:00 should be next Saturday.
        let recurrence = Recurrence.weekly(at: TimeOfDay(hour: 15, minute: 0), on: [.saturday])
        let now = Self.date(2026, 4, 25, 17, 0)
        let next = recurrence.nextOccurrence(after: now, calendar: Self.utc)
        #expect(next == Self.date(2026, 5, 2, 15, 0))
    }

    // MARK: - Monthly

    @Test("monthly recurrence picks the next 1st-of-month")
    func monthlyNext() {
        let recurrence = Recurrence.monthlyOnDay(at: TimeOfDay(hour: 9, minute: 0), dayOfMonth: 1)
        let now = Self.date(2026, 4, 25, 12, 0)
        let next = recurrence.nextOccurrence(after: now, calendar: Self.utc)
        #expect(next == Self.date(2026, 5, 1, 9, 0))
    }

    @Test("monthly recurrence picks same-month date when requested day is still ahead")
    func monthlySameMonthAhead() {
        let recurrence = Recurrence.monthlyOnDay(at: TimeOfDay(hour: 9, minute: 0), dayOfMonth: 30)
        let now = Self.date(2026, 4, 25, 12, 0)
        let next = recurrence.nextOccurrence(after: now, calendar: Self.utc)
        #expect(next == Self.date(2026, 4, 30, 9, 0))
    }

    @Test("monthly recurrence with day = 0 returns nil")
    func monthlyInvalidDayReturnsNil() {
        let recurrence = Recurrence.monthlyOnDay(at: TimeOfDay(hour: 9, minute: 0), dayOfMonth: 0)
        let now = Self.date(2026, 4, 25, 12, 0)
        #expect(recurrence.nextOccurrence(after: now, calendar: Self.utc) == nil)
    }

    @Test("monthly recurrence skips February for day 31 instead of rolling to March 1")
    func monthlySkipsMissingDay() {
        let recurrence = Recurrence.monthlyOnDay(at: TimeOfDay(hour: 9, minute: 0), dayOfMonth: 31)
        let now = Self.date(2026, 1, 31, 10, 0)
        let next = recurrence.nextOccurrence(after: now, calendar: Self.utc)
        #expect(next == Self.date(2026, 3, 31, 9, 0))
    }

    @Test("monthly recurrence preserves requested time after skipping an invalid month")
    func monthlyPreservesTimeAfterInvalidMonth() {
        let recurrence = Recurrence.monthlyOnDay(at: TimeOfDay(hour: 18, minute: 45), dayOfMonth: 31)
        let now = Self.date(2026, 2, 1, 10, 0)
        let next = recurrence.nextOccurrence(after: now, calendar: Self.utc)
        #expect(next == Self.date(2026, 3, 31, 18, 45))
    }

    @Test("monthly recurrence skips April for day 31 instead of rolling to May 1")
    func monthlySkipsThirtyDayMonth() {
        let recurrence = Recurrence.monthlyOnDay(at: TimeOfDay(hour: 7, minute: 15), dayOfMonth: 31)
        let now = Self.date(2026, 3, 31, 8, 0)
        let next = recurrence.nextOccurrence(after: now, calendar: Self.utc)
        #expect(next == Self.date(2026, 5, 31, 7, 15))
    }

    // MARK: - Display strings

    @Test("display description for weekly recurrence orders weekdays Sun..Sat")
    func weeklyDisplayOrdered() {
        let recurrence = Recurrence.weekly(at: TimeOfDay(hour: 15, minute: 30), on: [.friday, .monday, .wednesday])
        #expect(recurrence.displayDescription == "Mon/Wed/Fri at 15:30")
    }

    @Test("display description for daily recurrence")
    func dailyDisplay() {
        let recurrence = Recurrence.daily(at: TimeOfDay(hour: 9, minute: 5))
        #expect(recurrence.displayDescription == "Daily at 09:05")
    }

    // MARK: - Interval

    @Test("interval recurrence adds the period to the supplied date")
    func intervalNext() {
        let recurrence = Recurrence.interval(seconds: 30 * 60)
        let now = Self.date(2026, 4, 25, 12, 0)
        let next = recurrence.nextOccurrence(after: now, calendar: Self.utc)
        #expect(next == Self.date(2026, 4, 25, 12, 30))
    }

    @Test("interval recurrence below the minimum returns nil")
    func intervalBelowMinimumReturnsNil() {
        let recurrence = Recurrence.interval(seconds: 30)
        let now = Self.date(2026, 4, 25, 12, 0)
        #expect(recurrence.nextOccurrence(after: now, calendar: Self.utc) == nil)
    }

    @Test("display description for interval recurrence picks the natural unit")
    func intervalDisplay() {
        #expect(Recurrence.interval(seconds: 1800).displayDescription == "Every 30 minutes")
        #expect(Recurrence.interval(seconds: 7200).displayDescription == "Every 2 hours")
        #expect(Recurrence.interval(seconds: 5400).displayDescription == "Every 1 hour 30 minutes")
        #expect(Recurrence.interval(seconds: 60).displayDescription == "Every 1 minute")
    }
}
