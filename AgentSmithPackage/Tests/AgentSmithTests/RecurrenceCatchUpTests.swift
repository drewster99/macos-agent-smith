import Foundation
import Testing
@testable import AgentSmithKit

/// Catch-up for calendar recurrences, and the `TimeOfDay` validity contract.
///
/// The loop these replace stepped one occurrence at a time inside the `WakeScheduler` actor, up to
/// 100,000 iterations of `Calendar.nextDate`. Two things were wrong with it: a wake left stale by a
/// clock change blocked every other wake in the app for hundreds of milliseconds, and past the cap
/// it returned a still-past candidate, which the caller read as "this series is over" — silently
/// retiring a user's repeating timer.
@Suite("Recurrence catch-up")
struct RecurrenceCatchUpTests {

    private func calendar(_ identifier: String) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: identifier)!
        return cal
    }

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    /// The property the fix rests on: catching up from a stale `after` is the same as asking from
    /// the later of the two bounds. Stated as a test rather than left in a comment.
    @Test("Catch-up equals a single lookup from max(after, notBefore)")
    func catchUpEqualsDirectLookup() {
        let cal = calendar("America/New_York")
        let patterns: [Recurrence] = [
            .daily(at: TimeOfDay(hour: 9, minute: 0)),
            .daily(at: TimeOfDay(hour: 0, minute: 0)),
            .weekly(at: TimeOfDay(hour: 15, minute: 30), on: [.monday, .wednesday, .friday]),
            .weekly(at: TimeOfDay(hour: 6, minute: 0), on: Set(Weekday.allCases)),
            .monthlyOnDay(at: TimeOfDay(hour: 9, minute: 0), dayOfMonth: 1),
            .monthlyOnDay(at: TimeOfDay(hour: 9, minute: 0), dayOfMonth: 31)
        ]
        let notBefore = date("2026-09-10T12:00:00Z")
        // On time, a day stale, a month, a year, five years.
        for staleness in [0.0, 86_400, 2_592_000, 31_536_000, 157_680_000] {
            for pattern in patterns {
                let after = notBefore.addingTimeInterval(-staleness)
                let caught = pattern.nextOccurrence(after: after, notBefore: notBefore, calendar: cal)
                let direct = pattern.nextOccurrence(after: max(after, notBefore), calendar: cal)
                #expect(caught == direct, "\(pattern) at staleness \(staleness)")
            }
        }
    }

    /// Staleness must not cost time. The loop was ~5 µs per elapsed day for `.daily` and ~78 µs for
    /// a 7-weekday `.weekly`, all of it on the scheduler actor.
    @Test("A decades-stale recurrence still resolves, and does so promptly")
    func stalenessIsNotPaidFor() {
        let cal = calendar("America/New_York")
        let pattern = Recurrence.weekly(at: TimeOfDay(hour: 6, minute: 0), on: Set(Weekday.allCases))
        let notBefore = date("2026-09-10T12:00:00Z")
        let after = notBefore.addingTimeInterval(-30 * 365 * 86_400)   // ~30 years

        let started = Date()
        let next = pattern.nextOccurrence(after: after, notBefore: notBefore, calendar: cal)
        let elapsed = Date().timeIntervalSince(started)

        #expect(next != nil, "a 30-year-stale series must survive, not be silently retired")
        #expect(next! > notBefore)
        #expect(elapsed < 0.1, "took \(elapsed)s — the per-period loop is back")
    }

    /// The one case whose answer deliberately changed. During a DST fall-back repeated hour, with
    /// `notBefore` between the two occurrences of a repeated local time, the loop skipped a whole
    /// day; the direct lookup returns the second occurrence. Pinned so a future refactor cannot flip
    /// it back unnoticed.
    @Test("A DST fall-back repeated hour resolves to the second occurrence, not the next day")
    func dstFallBackReturnsTheSecondOccurrence() {
        let cal = calendar("America/New_York")
        let pattern = Recurrence.daily(at: TimeOfDay(hour: 1, minute: 0))
        // 2026-11-01: 01:00 EDT is 05:00Z; the clock falls back and 01:00 EST is 06:00Z.
        let after = date("2026-11-01T04:30:00Z")
        let notBefore = date("2026-11-01T05:30:00Z")

        let next = pattern.nextOccurrence(after: after, notBefore: notBefore, calendar: cal)
        #expect(next == date("2026-11-01T06:00:00Z"))
        // Whatever it returns, it is always strictly future — it can never re-fire or duplicate.
        #expect(next! > notBefore)
        #expect(next! > after)
    }

    @Test("A spring-forward gap still yields a strictly-future occurrence")
    func dstSpringForwardStaysFuture() {
        let cal = calendar("America/New_York")
        let pattern = Recurrence.daily(at: TimeOfDay(hour: 2, minute: 30))
        let notBefore = date("2026-03-08T06:30:00Z")   // inside the missing local hour
        let next = pattern.nextOccurrence(after: notBefore.addingTimeInterval(-86_400), notBefore: notBefore, calendar: cal)
        #expect(next != nil)
        #expect(next! > notBefore)
    }

    // MARK: - TimeOfDay validity

    @Test("The memberwise init no longer clamps, so it agrees with the decoder")
    func timeOfDayDoesNotClamp() throws {
        // Clamping made 24:00 into 23:00 — a different time, fired an hour early forever.
        #expect(TimeOfDay(hour: 24, minute: 0).hour == 24)
        #expect(TimeOfDay(hour: 24, minute: 0).isValid == false)
        #expect(TimeOfDay(hour: 9, minute: 30).isValid)

        // The decoder assigns stored properties directly, so it must agree with the init.
        let decoded = try JSONDecoder().decode(TimeOfDay.self, from: Data(#"{"hour":25,"minute":90}"#.utf8))
        #expect(decoded.hour == 25)
        #expect(decoded.isValid == false)
    }

    @Test("An invalid time ends the series deliberately, in every calendar pattern")
    func invalidTimeYieldsNil() {
        let cal = calendar("UTC")
        let bad = TimeOfDay(hour: 25, minute: 0)
        let now = date("2026-09-10T12:00:00Z")
        #expect(Recurrence.daily(at: bad).nextOccurrence(after: now, calendar: cal) == nil)
        #expect(Recurrence.weekly(at: bad, on: [.monday]).nextOccurrence(after: now, calendar: cal) == nil)
        #expect(Recurrence.monthlyOnDay(at: bad, dayOfMonth: 1).nextOccurrence(after: now, calendar: cal) == nil)
    }

    /// A stricter decoder would be worse than the bug: `scheduled_wakes.json` decodes as one array,
    /// so a throwing element disarms every timer in the session, permanently, on every launch.
    @Test("One out-of-range wake does not take the whole file down with it")
    func oneBadRecordDoesNotBrickTheFile() throws {
        let good = UUID().uuidString
        let bad = UUID().uuidString
        let json = """
            [{"id":"\(good)","wakeAt":800000000,"instructions":"ok","structuredDispatch":true,
              "recurrence":{"daily":{"at":{"hour":9,"minute":0}}}},
             {"id":"\(bad)","wakeAt":800000000,"instructions":"bad time","structuredDispatch":true,
              "recurrence":{"daily":{"at":{"hour":25,"minute":0}}}}]
            """
        let wakes = try JSONDecoder().decode([ScheduledWake].self, from: Data(json.utf8))
        #expect(wakes.count == 2, "both must decode — a strict decoder would lose both")
    }

    /// The leniency must live in `TimerEvent`'s decoder, not in a lenient `init?(rawValue:)` on the
    /// enum: the synthesized `Decodable` for a RawRepresentable THROWS when `init(rawValue:)`
    /// returns nil, so an enum-level init would look lenient and change nothing. This decodes real
    /// JSON to prove it — the first version of this test asserted on `init?(rawValue:)` directly
    /// and would have passed against the broken implementation.
    @Test("A cancellation cause from a newer build does not take the timer history down")
    func unknownCancellationCauseDoesNotThrow() throws {
        func row(_ cause: String) -> String {
            let ids = "\"\(UUID().uuidString)\""
            return "{\"id\":\(ids),\"timestamp\":800000000,\"kind\":\"cancelled\",\"wakeID\":\(ids),"
                + "\"originalID\":\(ids),\"instructions\":\"x\",\"cancellationCause\":\"\(cause)\"}"
        }
        let json = "[\(row("userRequest")),\(row("recurrenceExhausted")),\(row("somethingFromTheFuture"))]"
        let events = try JSONDecoder().decode([TimerEvent].self, from: Data(json.utf8))

        #expect(events.count == 3, "one unknown value must not lose the other rows")
        #expect(events[0].cancellationCause == .userRequest)
        #expect(events[1].cancellationCause == .recurrenceExhausted)
        #expect(events[2].cancellationCause == nil, "unknown degrades to nil, not to a throw")
    }

    // MARK: - Tool-boundary validation

    @Test("A missing recurrence hour is rejected, not silently midnight")
    func missingHourIsRejected() {
        let raw = AnyCodable.dictionary(["type": .string("daily")])
        guard case .invalid(let reason) = TimerArgumentParsing.parseRecurrence(raw) else {
            Issue.record("a daily recurrence with no hour must be refused, not defaulted to 00:00")
            return
        }
        #expect(reason.contains("hour"))
    }

    @Test("A missing minute still means o'clock")
    func missingMinuteMeansZero() {
        let raw = AnyCodable.dictionary(["type": .string("daily"), "hour": .int(9)])
        guard case .value(.some(.daily(let time))) = TimerArgumentParsing.parseRecurrence(raw) else {
            Issue.record("9am with no minute is a real intent and must parse")
            return
        }
        #expect(time == TimeOfDay(hour: 9, minute: 0))
    }

    /// Every stored property of `TimerEvent` must have a `CodingKeys` case.
    ///
    /// `TimerEvent` gained a hand-written `init(from:)` so an unrecognized `cancellationCause`
    /// degrades instead of taking the whole log down. That costs the type its SYNTHESIZED key list,
    /// and the resulting footgun is the one `ledgerCodingKeyCoverage` was written for: a stored
    /// property with a default (every optional here) that is missing a case is silently never
    /// persisted, and a round-trip test stays GREEN because the field decodes back to the same
    /// default it was given. Reflection is what catches it; a round trip is not.
    @Test("Every TimerEvent stored property has a CodingKeys case")
    func timerEventCodingKeyCoverage() throws {
        // Every optional populated, or an absent key would be indistinguishable from an uncovered one.
        let event = TimerEvent(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1),
            kind: .cancelled,
            wakeID: UUID(),
            originalID: UUID(),
            instructions: "do the thing",
            taskID: UUID(),
            recurrenceDescription: "Daily at 09:00",
            coalescedCount: 3,
            scheduledFireAt: Date(timeIntervalSince1970: 2),
            cancellationCause: .recurrenceExhausted,
            action: .run
        )
        let object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any]
        )
        let expected = Set(Mirror(reflecting: event).children.compactMap(\.label))
        let missing = expected.subtracting(object.keys).sorted()
        #expect(missing.isEmpty, """
            \(missing.joined(separator: ", ")) is a stored property with no CodingKeys case, so it is \
            silently never persisted. Add it to TimerEvent.CodingKeys AND to init(from:).
            """)

        // The hand-written decoder must also READ every key the encoder writes — a case present in
        // CodingKeys but missing from `init(from:)` passes the check above and still loses the field.
        let decoded = try JSONDecoder().decode(TimerEvent.self, from: JSONEncoder().encode(event))
        #expect(decoded == event)
    }
}
