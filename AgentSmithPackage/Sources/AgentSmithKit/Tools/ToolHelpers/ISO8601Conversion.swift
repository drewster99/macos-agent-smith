import Foundation
import Synchronization

/// Shared ISO-8601 conversion for tool arguments and tool output.
///
/// The formatters are built once and shared because constructing an `ISO8601DateFormatter`
/// costs ~89µs — and 93% of that is CoreFoundation regenerating the underlying
/// `CFDateFormatterRef` the moment `formatOptions` is assigned, which every call did. A single
/// `list_tasks` page renders up to three timestamps for each of up to 100 tasks, so the old
/// allocate-per-call shape cost ~27ms of pure formatter construction per call.
///
/// They are held behind a `Mutex` rather than plain statics because `ISO8601DateFormatter` is a
/// mutable reference type that Foundation does NOT mark `NS_SWIFT_SENDABLE` — unlike
/// `DateFormatter`, which does. Its header is sendability-audited, so the omission is deliberate
/// and Swift 6 rejects a shared `static let`. `OSAllocatedUnfairLock` cannot be used either: it
/// constrains `State: Sendable`.
///
/// `Date.ISO8601FormatStyle` is deliberately NOT used despite being lock-free and ~5x faster
/// again: it TRUNCATES sub-millisecond values where `ISO8601DateFormatter` ROUNDS them. That
/// shifts ~52% of emitted timestamps by 1ms, and at the fractional boundary the rounding carries
/// into the seconds field (`02:14:20.000Z` vs `02:14:19.999Z`), rolling minutes and hours. These
/// strings are LLM-facing and are parsed back by `date(from:)` for date-range filters, so the
/// divergence would be a silent contract change. The remaining 5x is not worth it.
enum ISO8601Conversion {

    private static let fractional = Mutex<ISO8601DateFormatter>({
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }())

    private static let plain = Mutex<ISO8601DateFormatter>({
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }())

    /// Renders `date` as an internet date-time string including fractional seconds.
    ///
    /// Only the resulting `String` leaves the lock — never the formatter itself. `Mutex` does not
    /// enforce that (returning `$0` compiles), so it is a convention this type must keep.
    static func string(from date: Date) -> String {
        fractional.withLock { $0.string(from: date) }
    }

    /// Parses an internet date-time string, accepting it with or without fractional seconds.
    ///
    /// Two formatters are genuinely required and the order matters: each one REJECTS the other's
    /// shape, so the fractional attempt has to come first and fall through.
    static func date(from value: String) -> Date? {
        if let date = fractional.withLock({ $0.date(from: value) }) { return date }
        return plain.withLock { $0.date(from: value) }
    }
}
