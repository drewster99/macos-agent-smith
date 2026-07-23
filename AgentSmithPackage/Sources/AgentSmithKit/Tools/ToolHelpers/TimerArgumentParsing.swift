import Foundation

/// Shared argument parsing for `schedule_task_action`, `reschedule_wake`, and (in
/// `CreateTaskTool`) the `scheduled_run_at` field. Centralizes the validation rules so
/// behaviour stays identical across tools — same min/max delay, same ISO-8601 forgiveness,
/// same recurrence schema.
enum TimerArgumentParsing {

    /// Resolves a fire-time `Date` from either `delay_seconds` or `at_time`. Returns
    /// `.success(date)` or `.failure(reason)` so the caller can early-return a tool failure
    /// without throwing.
    enum FireTimeResult {
        case success(Date)
        case failure(String)
    }

    static func resolveFireTime(
        arguments: [String: AnyCodable],
        now: Date,
        minDelaySeconds: Double,
        maxDelaySeconds: Double
    ) -> FireTimeResult {
        if let value = arguments["at_time"], case .string(let isoString) = value {
            guard let parsed = ISO8601Conversion.date(from: isoString) else {
                return .failure("Invalid at_time: '\(isoString)' is not a valid ISO-8601 timestamp.")
            }
            let delta = parsed.timeIntervalSince(now)
            if delta < minDelaySeconds {
                return .failure("Invalid at_time: '\(isoString)' is in the past or less than \(Int(minDelaySeconds)) seconds from now.")
            }
            if delta > maxDelaySeconds {
                return .failure("Invalid at_time: '\(isoString)' is more than 1 year in the future.")
            }
            return .success(parsed)
        }
        let rawDelay: Double
        switch arguments["delay_seconds"] {
        case .int(let v):    rawDelay = Double(v)
        case .double(let v): rawDelay = v
        case .string(let s):
            guard let parsed = Double(s) else {
                return .failure("Invalid delay_seconds: '\(s)' is not a number.")
            }
            rawDelay = parsed
        default:
            return .failure("Either delay_seconds or at_time is required.")
        }
        // A non-finite delay (NaN/inf) slips past both range checks below — NaN compares false to
        // everything — and `addingTimeInterval(NaN)` yields a garbage Date that never fires. Reject.
        guard rawDelay.isFinite else {
            return .failure("Invalid delay_seconds: must be a finite number.")
        }
        if rawDelay < minDelaySeconds {
            return .failure("Invalid delay_seconds: \(rawDelay) is below the minimum of \(Int(minDelaySeconds)).")
        }
        if rawDelay > maxDelaySeconds {
            return .failure("Invalid delay_seconds: \(rawDelay) exceeds the maximum of \(Int(maxDelaySeconds)) (1 year).")
        }
        return .success(now.addingTimeInterval(rawDelay))
    }

    /// Result of parsing a recurrence object. `.value(nil)` means "no recurrence given —
    /// one-shot timer," which is valid; `.invalid(reason)` means a recurrence object was
    /// passed but malformed.
    enum RecurrenceResult {
        case value(Recurrence?)
        case invalid(String)

        var value: Recurrence? {
            switch self {
            case .value(let r): return r
            case .invalid: return nil
            }
        }
    }

    static func parseRecurrence(_ raw: AnyCodable?) -> RecurrenceResult {
        guard let raw else { return .value(nil) }
        guard case .dictionary(let dict) = raw else {
            return .invalid("recurrence must be an object.")
        }
        guard case .string(let type) = dict["type"] else {
            return .invalid("recurrence.type missing or not a string. Expected one of: interval, daily, weekly, monthly.")
        }

        let normalizedType = type.lowercased()
        if normalizedType == "interval" || normalizedType == "every" {
            let seconds = intValue(dict["seconds"]) ?? 0
            let minutes = intValue(dict["minutes"]) ?? 0
            let hours = intValue(dict["hours"]) ?? 0
            // `minutes * 60 + hours * 3600` traps on overflow for large in-range Ints an LLM might
            // supply. Compute with overflow-reporting arithmetic and reject rather than crash. An
            // overflowing value is nonsensical as an interval anyway.
            guard let total = safeIntervalSeconds(seconds: seconds, minutes: minutes, hours: hours) else {
                return .invalid("interval recurrence value is too large.")
            }
            guard total > 0 else {
                return .invalid("interval recurrence requires a positive `seconds`, `minutes`, or `hours` value.")
            }
            guard total >= Recurrence.minimumIntervalSeconds else {
                return .invalid("interval recurrence period must be at least \(Recurrence.minimumIntervalSeconds) seconds (got \(total)). Lower intervals risk runaway loops.")
            }
            return .value(.interval(seconds: total))
        }

        let hour = intValue(dict["hour"]) ?? 0
        let minute = intValue(dict["minute"]) ?? 0
        guard (0...23).contains(hour), (0...59).contains(minute) else {
            return .invalid("hour must be 0-23 and minute must be 0-59.")
        }
        let timeOfDay = TimeOfDay(hour: hour, minute: minute)

        switch normalizedType {
        case "daily":
            return .value(.daily(at: timeOfDay))
        case "weekly":
            guard case .array(let onArray) = dict["on"] else {
                return .invalid("weekly recurrence requires `on`: array of weekday short names (e.g. [\"mon\",\"wed\",\"fri\"]).")
            }
            var weekdays = Set<Weekday>()
            for entry in onArray {
                guard case .string(let name) = entry else {
                    return .invalid("weekly `on` entries must be strings.")
                }
                if let day = parseWeekday(name) {
                    weekdays.insert(day)
                } else {
                    return .invalid("Unknown weekday '\(name)'. Use sun/mon/tue/wed/thu/fri/sat.")
                }
            }
            guard !weekdays.isEmpty else {
                return .invalid("weekly recurrence requires at least one weekday in `on`.")
            }
            return .value(.weekly(at: timeOfDay, on: weekdays))
        case "monthly", "monthlyonday", "monthly_on_day":
            guard let day = intValue(dict["day_of_month"]) ?? intValue(dict["dayOfMonth"]) else {
                return .invalid("monthly recurrence requires `day_of_month` (1-31).")
            }
            guard (1...31).contains(day) else {
                return .invalid("day_of_month must be 1-31.")
            }
            return .value(.monthlyOnDay(at: timeOfDay, dayOfMonth: day))
        default:
            return .invalid("Unknown recurrence type '\(type)'. Expected one of: interval, daily, weekly, monthly.")
        }
    }

    private static func parseWeekday(_ name: String) -> Weekday? {
        let lower = name.lowercased()
        switch lower {
        case "sun", "sunday":     return .sunday
        case "mon", "monday":     return .monday
        case "tue", "tues", "tuesday": return .tuesday
        case "wed", "wednesday":  return .wednesday
        case "thu", "thur", "thurs", "thursday": return .thursday
        case "fri", "friday":     return .friday
        case "sat", "saturday":   return .saturday
        default: return nil
        }
    }

    /// `seconds + minutes*60 + hours*3600` with overflow reported as nil rather than a trap.
    private static func safeIntervalSeconds(seconds: Int, minutes: Int, hours: Int) -> Int? {
        let (minuteSeconds, mOver) = minutes.multipliedReportingOverflow(by: 60)
        guard !mOver else { return nil }
        let (hourSeconds, hOver) = hours.multipliedReportingOverflow(by: 3600)
        guard !hOver else { return nil }
        let (partial, p1Over) = seconds.addingReportingOverflow(minuteSeconds)
        guard !p1Over else { return nil }
        let (total, p2Over) = partial.addingReportingOverflow(hourSeconds)
        guard !p2Over else { return nil }
        return total
    }

    private static func intValue(_ value: AnyCodable?) -> Int? {
        guard let value else { return nil }
        switch value {
        case .int(let v): return v
        // `Int(v)` TRAPS on a non-finite or out-of-range Double — an LLM can supply `1e300` or NaN,
        // so convert defensively and treat the un-representable case as "not a number" (nil).
        case .double(let v):
            guard v.isFinite, v >= Double(Int.min), v <= Double(Int.max) else { return nil }
            return Int(v)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    /// Formats the user-facing tool result for `schedule_task_action` / `reschedule_wake`.
    static func formatScheduleOutcome(_ outcome: ScheduleWakeOutcome, kind: String) -> ToolExecutionResult {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        switch outcome {
        case .scheduled(let wake):
            let recurFragment = wake.recurrence.map { " (recurring: \($0.displayDescription))" } ?? ""
            let taskFragment = wake.taskID.map { " (linked to task \($0.uuidString))" } ?? ""
            return .success("\(kind) scheduled \(wake.id.uuidString) for \(formatter.string(from: wake.wakeAt))\(taskFragment)\(recurFragment). Instructions: \(wake.instructions)")
        case .error(let message):
            return .failure("Could not schedule \(kind.lowercased()): \(message)")
        }
    }
}
