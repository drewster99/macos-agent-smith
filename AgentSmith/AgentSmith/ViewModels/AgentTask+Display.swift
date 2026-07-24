import Foundation
import AgentSmithKit

/// "1h 4m 12s" / "4m 12s" / "12s" — the app's one spelling of a duration. Used for a single
/// task's elapsed time and for aggregate totals (e.g. a template's runs summed together), so
/// the two never render the same span differently.
func durationDisplayString(_ interval: TimeInterval) -> String {
    let totalSeconds = Int(interval)
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let seconds = totalSeconds % 60

    if hours > 0 {
        return "\(hours)h \(minutes)m \(seconds)s"
    } else if minutes > 0 {
        return "\(minutes)m \(seconds)s"
    } else {
        return "\(seconds)s"
    }
}

extension AgentTask {
    /// Elapsed seconds from `startedAt` to `completedAt` (or now, if unfinished). `nil` when
    /// the task never started or the interval is negative. The single numeric source both the
    /// human-readable duration and the cost-per-hour rate derive from.
    var elapsedSeconds: TimeInterval? {
        guard let start = startedAt else { return nil }
        let interval = (completedAt ?? Date()).timeIntervalSince(start)
        return interval >= 0 ? interval : nil
    }

    /// Human-readable elapsed duration from `startedAt` to `completedAt` (or now, if the
    /// task hasn't finished). `nil` when the task has never started or the interval is
    /// negative. Shared by the task detail window and the PDF exporter.
    var elapsedDisplayString: String? {
        elapsedSeconds.map(durationDisplayString)
    }

    /// The task's spend extrapolated to an hourly rate ("$26.10/hr"), given its accrued
    /// `cost`. `nil` for runs under a minute — extrapolating a 12-second burst to an hourly
    /// figure is noise, not information, so we simply don't show a rate there.
    func costPerHourString(cost: Double) -> String? {
        guard let seconds = elapsedSeconds, seconds >= 60, cost > 0 else { return nil }
        let ratePerHour = cost / (seconds / 3600.0)
        return String(format: "$%.2f/hr", ratePerHour)
    }
}
