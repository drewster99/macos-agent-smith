import Testing
import Foundation
@testable import AgentSmithKit

/// Guards the shared ISO-8601 helper that `list_tasks`, `create_task`, and the timer argument
/// parser all route through. The emitted shape is LLM-facing AND is parsed back for date-range
/// filters, so format drift is a silent contract change — hence the explicit shape assertion.
@Suite("ISO8601 conversion")
struct ISO8601ConversionTests {

    @Test("Emits the fractional-seconds Zulu shape")
    func emitsFractionalZuluShape() {
        let rendered = ISO8601Conversion.string(from: Date(timeIntervalSince1970: 1_763_000_000))
        // This is the guard that would catch a swap to `Date.ISO8601FormatStyle` or any other
        // formatter whose output shape differs.
        #expect(rendered.wholeMatch(of: /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z/) != nil, "got \(rendered)")
    }

    @Test("Output is byte-identical to a freshly built ISO8601DateFormatter")
    func matchesFreshlyBuiltFormatter() {
        let reference = ISO8601DateFormatter()
        reference.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Includes the sub-millisecond values where rounding and truncation disagree.
        for offset in [0.0, 0.999, 0.9996, -0.001, 1_763_000_059.9997, 4_102_444_800.5] {
            let date = Date(timeIntervalSince1970: offset)
            #expect(ISO8601Conversion.string(from: date) == reference.string(from: date))
        }
    }

    @Test("Round-trips its own output")
    func roundTripsOwnOutput() {
        let original = Date(timeIntervalSince1970: 1_763_000_000.25)
        let parsed = ISO8601Conversion.date(from: ISO8601Conversion.string(from: original))
        #expect(parsed != nil)
        #expect(abs((parsed ?? .distantPast).timeIntervalSince(original)) < 0.001)
    }

    @Test("Accepts both fractional and non-fractional input")
    func acceptsBothShapes() {
        // The two-formatter fallback is load-bearing and order-dependent: each formatter REJECTS
        // the other's shape. Existing callers pass non-fractional timestamps.
        #expect(ISO8601Conversion.date(from: "2025-11-13T02:13:20Z") != nil)
        #expect(ISO8601Conversion.date(from: "2025-11-13T02:13:20.500Z") != nil)
        #expect(ISO8601Conversion.date(from: "2025-11-13T02:13:20+05:00") != nil)
    }

    @Test("Rejects junk")
    func rejectsJunk() {
        #expect(ISO8601Conversion.date(from: "") == nil)
        #expect(ISO8601Conversion.date(from: "not-a-date") == nil)
        #expect(ISO8601Conversion.date(from: "2025-11-13") == nil)
    }

    @Test("Shared formatters are safe under concurrent use")
    func concurrentUseIsSafe() async {
        // The formatters are process-wide statics behind a Mutex; every worker and window shares
        // them. Identical inputs must yield identical output under contention.
        let date = Date(timeIntervalSince1970: 1_763_000_000.125)
        let expected = ISO8601Conversion.string(from: date)
        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    for _ in 0..<200 {
                        guard ISO8601Conversion.string(from: date) == expected,
                              ISO8601Conversion.date(from: expected) != nil else { return false }
                    }
                    return true
                }
            }
            return await group.reduce(into: [Bool]()) { $0.append($1) }
        }
        #expect(results.allSatisfy { $0 })
    }
}
