import Testing
import Foundation
@testable import AgentSmithKit

/// Trap-safety for LLM-supplied timer arguments. An LLM can put a non-finite or absurdly large
/// number in a recurrence/delay field; the parser must reject it, never crash on an `Int(_:)`
/// conversion trap or an overflowing multiply/add.
@Suite("Timer argument parsing — trap safety")
struct TimerArgumentParsingSafetyTests {

    private func recurrence(_ dict: [String: AnyCodable]) -> TimerArgumentParsing.RecurrenceResult {
        TimerArgumentParsing.parseRecurrence(.dictionary(dict))
    }

    @Test("an out-of-range Double in an interval field does not trap (Int(1e300) would)")
    func hugeDoubleDoesNotTrap() {
        let result = recurrence([
            "type": .string("interval"),
            "hours": .double(1e300),
        ])
        // The un-representable value is treated as absent → total 0 → invalid, NOT a crash.
        guard case .invalid = result else { Issue.record("expected .invalid, got \(result)"); return }
    }

    @Test("the exact Double(Int.max) boundary does not trap (2^63 rounds up and Int(_) would trap)")
    func intMaxBoundaryDoesNotTrap() {
        // `Double(Int.max)` == 2^63, one past Int.max — the value an LLM could supply to hit the
        // old `v <= Double(Int.max)`-then-`Int(v)` trap.
        for bad in [Double(Int.max), 9.223372036854776e18, -9.223372036854776e18, Double(Int.min)] {
            let result = recurrence(["type": .string("interval"), "seconds": .double(bad)])
            guard case .invalid = result else { Issue.record("expected .invalid for \(bad), got \(result)"); return }
        }
    }

    @Test("a NaN Double in an interval field does not trap")
    func nanDoubleDoesNotTrap() {
        let result = recurrence([
            "type": .string("interval"),
            "minutes": .double(Double.nan),
        ])
        guard case .invalid = result else { Issue.record("expected .invalid, got \(result)"); return }
    }

    @Test("an overflowing minutes*60 does not trap — reported as invalid")
    func overflowingMinutesDoesNotTrap() {
        let result = recurrence([
            "type": .string("interval"),
            "minutes": .int(Int.max),
        ])
        guard case .invalid(let message) = result else { Issue.record("expected .invalid, got \(result)"); return }
        #expect(message.contains("too large"))
    }

    @Test("a valid interval still parses to the summed seconds")
    func validIntervalStillWorks() {
        let result = recurrence([
            "type": .string("interval"),
            "hours": .int(1),
            "minutes": .int(30),
        ])
        #expect(result.value == .interval(seconds: 5400))
    }

    @Test("a non-finite delay_seconds is rejected, not turned into a garbage Date")
    func nonFiniteDelayRejected() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        for bad in [Double.nan, .infinity, -.infinity] {
            let result = TimerArgumentParsing.resolveFireTime(
                arguments: ["delay_seconds": .double(bad)],
                now: now, minDelaySeconds: 1, maxDelaySeconds: 31_536_000
            )
            guard case .failure = result else { Issue.record("expected .failure for \(bad), got \(result)"); return }
        }
    }

    @Test("a finite in-range delay_seconds still resolves")
    func finiteDelayResolves() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let result = TimerArgumentParsing.resolveFireTime(
            arguments: ["delay_seconds": .double(120)],
            now: now, minDelaySeconds: 1, maxDelaySeconds: 31_536_000
        )
        guard case .success(let date) = result else { Issue.record("expected .success, got \(result)"); return }
        #expect(date == now.addingTimeInterval(120))
    }
}
