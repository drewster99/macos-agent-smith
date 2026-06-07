import Foundation

/// Recurrence pattern attached to a `ScheduledWake`. When a recurring wake fires, the
/// runtime computes the next occurrence via `nextOccurrence(after:)` and schedules a fresh
/// wake with the same instructions. Four patterns cover the common use cases ("every 30
/// minutes", "every day at 9pm", "every Mon/Wed/Fri at 3pm", "the 1st of every month at
/// 9am") without forcing callers into RRULE territory.
public enum Recurrence: Sendable, Codable, Equatable {
    case daily(at: TimeOfDay)
    case weekly(at: TimeOfDay, on: Set<Weekday>)
    case monthlyOnDay(at: TimeOfDay, dayOfMonth: Int)
    /// Fixed-period recurrence: fires every `seconds` seconds regardless of wall clock.
    /// Use for "every 30 minutes" or "every 2 hours" where alignment to a particular
    /// hour-of-day doesn't matter.
    case interval(seconds: Int)

    /// Minimum interval recurrence period. Below this, recurring wakes risk runaway loops,
    /// especially when paired with auto-running agents. See the no-runaway-loops policy.
    public static let minimumIntervalSeconds: Int = 60

    /// Returns the next fire time strictly after `after`, in the supplied calendar/timezone.
    /// Returns nil only when the recurrence is malformed (for example, weekly with an empty
    /// weekday set, monthly with day < 1 or > 31, or interval below the minimum). Callers
    /// should treat nil the same as "stop recurring."
    public func nextOccurrence(after: Date, calendar: Calendar = Calendar.current) -> Date? {
        func nextMatch(_ components: DateComponents) -> Date? {
            calendar.nextDate(
                after: after,
                matching: components,
                matchingPolicy: .nextTime,
                direction: .forward
            )
        }
        switch self {
        case .daily(let time):
            return nextMatch(DateComponents(hour: time.hour, minute: time.minute))
        case .weekly(let time, let weekdays):
            guard !weekdays.isEmpty else { return nil }
            let candidates = weekdays.compactMap { weekday in
                nextMatch(DateComponents(
                    hour: time.hour,
                    minute: time.minute,
                    weekday: weekday.calendarValue
                ))
            }
            return candidates.min()
        case .monthlyOnDay(let time, let day):
            guard day >= 1, day <= 31 else { return nil }
            return nextMonthlyOccurrence(day: day, time: time, after: after, calendar: calendar)
        case .interval(let seconds):
            guard seconds >= Self.minimumIntervalSeconds else { return nil }
            return after.addingTimeInterval(TimeInterval(seconds))
        }
    }

    /// Finds the next real calendar date matching the requested day/time.
    ///
    /// `Calendar.nextDate(..., matchingPolicy: .nextTime)` is intentionally not used here:
    /// for impossible dates like February 31 it rolls components forward to March 1 00:00,
    /// which silently changes both the day and the requested time. A direct `Calendar.date(from:)`
    /// also normalizes impossible components (for example, April 31 to May 1). The explicit
    /// component comparison below skips those invalid months while keeping the requested time.
    private func nextMonthlyOccurrence(day: Int, time: TimeOfDay, after: Date, calendar: Calendar) -> Date? {
        let start = calendar.dateComponents([.year, .month], from: after)
        guard let year = start.year, let month = start.month else { return nil }

        for monthOffset in 0..<1200 {
            let monthStart = DateComponents(year: year, month: month + monthOffset, day: 1)
            guard let monthDate = calendar.date(from: monthStart) else { continue }

            let normalizedMonth = calendar.dateComponents([.era, .year, .month], from: monthDate)
            var candidateComponents = normalizedMonth
            candidateComponents.calendar = calendar
            candidateComponents.day = day
            candidateComponents.hour = time.hour
            candidateComponents.minute = time.minute
            guard let candidate = calendar.date(from: candidateComponents) else { continue }

            let resolved = calendar.dateComponents(
                [.era, .year, .month, .day, .hour, .minute],
                from: candidate
            )
            guard resolved.era == normalizedMonth.era,
                  resolved.year == normalizedMonth.year,
                  resolved.month == normalizedMonth.month,
                  resolved.day == day,
                  resolved.hour == time.hour,
                  resolved.minute == time.minute else { continue }

            if candidate > after {
                return candidate
            }
        }
        return nil
    }

    /// Human-readable form for display in the timers UI ("Daily at 21:00", "Mon/Wed/Fri at 15:00").
    public var displayDescription: String {
        switch self {
        case .daily(let t):
            return "Daily at \(t.displayString)"
        case .weekly(_, let weekdays) where weekdays.isEmpty:
            return "Weekly (no days set)"
        case .weekly(let t, let weekdays):
            let ordered = Weekday.allCases.filter { weekdays.contains($0) }
            let label = ordered.map(\.shortName).joined(separator: "/")
            return "\(label) at \(t.displayString)"
        case .monthlyOnDay(let t, let day):
            return "Day \(day) of every month at \(t.displayString)"
        case .interval(let seconds):
            return "Every \(Self.intervalLabel(seconds: seconds))"
        }
    }

    /// Render an interval as "30 minutes", "2 hours", "1 hour 30 minutes", or "45 seconds",
    /// whichever is the most natural unit for the supplied second count.
    private static func intervalLabel(seconds: Int) -> String {
        guard seconds > 0 else { return "0 seconds" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) hour\(hours == 1 ? "" : "s")") }
        if minutes > 0 { parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")") }
        if secs > 0 && hours == 0 { parts.append("\(secs) second\(secs == 1 ? "" : "s")") }
        return parts.joined(separator: " ")
    }
}

/// Hour + minute (24h) without a date attached. Stored on `Recurrence` so the recurrence
/// pattern is timezone-relative: "every day at 21:00" follows the user's local clock
/// rather than drifting against UTC.
public struct TimeOfDay: Sendable, Codable, Equatable, Hashable {
    public let hour: Int
    public let minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = max(0, min(23, hour))
        self.minute = max(0, min(59, minute))
    }

    /// `HH:mm` formatted, suitable for UI labels.
    public var displayString: String {
        String(format: "%02d:%02d", hour, minute)
    }
}

/// Weekday with `Calendar` (`.weekday`)-style numbering: Sunday = 1 through Saturday = 7.
/// Stored as `String` to keep persisted recurrence data readable in the JSON file.
public enum Weekday: String, Sendable, Codable, CaseIterable, Hashable {
    case sunday, monday, tuesday, wednesday, thursday, friday, saturday

    /// Calendar's `.weekday` numbering (1 = Sunday through 7 = Saturday).
    public var calendarValue: Int {
        switch self {
        case .sunday:    return 1
        case .monday:    return 2
        case .tuesday:   return 3
        case .wednesday: return 4
        case .thursday:  return 5
        case .friday:    return 6
        case .saturday:  return 7
        }
    }

    /// Three-letter abbreviation (Mon, Tue, ...).
    public var shortName: String {
        switch self {
        case .sunday:    return "Sun"
        case .monday:    return "Mon"
        case .tuesday:   return "Tue"
        case .wednesday: return "Wed"
        case .thursday:  return "Thu"
        case .friday:    return "Fri"
        case .saturday:  return "Sat"
        }
    }
}
