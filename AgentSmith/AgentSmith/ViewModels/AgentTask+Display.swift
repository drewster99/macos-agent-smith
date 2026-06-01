import Foundation
import AgentSmithKit

extension AgentTask {
    /// Human-readable elapsed duration from `startedAt` to `completedAt` (or now, if the
    /// task hasn't finished). `nil` when the task has never started or the interval is
    /// negative. Shared by the task detail window and the PDF exporter.
    var elapsedDisplayString: String? {
        guard let start = startedAt else { return nil }
        let end = completedAt ?? Date()
        let interval = end.timeIntervalSince(start)
        guard interval >= 0 else { return nil }

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
}
