import Foundation

/// Smoothness of a run of displayed frames, from the intervals between them.
///
/// A frame is late — a hitch — when it arrives after its refresh interval; the hitch time is how
/// much later. Hitch RATIO (milliseconds of hitch per second of run) is the number Apple uses to
/// grade scrolling: under 5 ms/s reads as smooth, 5–10 is noticeable, over 10 is bad.
public struct FrameTimingStats: Codable, Equatable, Sendable {
    public let frameCount: Int
    public let durationSeconds: Double
    /// The display's refresh interval the frames were judged against.
    public let refreshIntervalMs: Double
    public let medianIntervalMs: Double
    public let p95IntervalMs: Double
    public let maxIntervalMs: Double
    /// Frames that arrived later than one refresh interval (plus a small tolerance for jitter).
    public let hitchCount: Int
    public let totalHitchMs: Double
    public let hitchRatioMsPerSecond: Double

    /// Late by less than this fraction of a refresh is display-timing jitter, not a hitch.
    public static let jitterTolerance = 0.25

    /// One displayed frame: the time since the previous one, and the refresh interval the display
    /// was running at for it. Kept per frame because a variable-refresh display changes rate
    /// mid-run, and a 16.7 ms frame is on time at 60 Hz but a hitch at 120 Hz.
    public struct Sample: Sendable, Equatable {
        public let interval: Double
        public let refreshInterval: Double

        public init(interval: Double, refreshInterval: Double) {
            self.interval = interval
            self.refreshInterval = refreshInterval
        }
    }

    /// Every frame judged against its own refresh interval.
    public init(samples: [Sample]) {
        let sortedIntervals = samples.map(\.interval).sorted()
        frameCount = samples.count
        durationSeconds = samples.reduce(0) { $0 + $1.interval }
        refreshIntervalMs = Self.percentile(0.5, of: samples.map(\.refreshInterval).sorted()) * 1000
        medianIntervalMs = Self.percentile(0.5, of: sortedIntervals) * 1000
        p95IntervalMs = Self.percentile(0.95, of: sortedIntervals) * 1000
        maxIntervalMs = (sortedIntervals.last ?? 0) * 1000

        var count = 0
        var total = 0.0
        for sample in samples where sample.interval > sample.refreshInterval * (1 + Self.jitterTolerance) {
            count += 1
            total += sample.interval - sample.refreshInterval
        }
        hitchCount = count
        totalHitchMs = total * 1000
        hitchRatioMsPerSecond = durationSeconds > 0 ? totalHitchMs / durationSeconds : 0
    }

    /// Frames all shown at one refresh interval.
    /// - Parameters:
    ///   - intervals: seconds between consecutive frames.
    ///   - refreshInterval: seconds per refresh of the display that showed them.
    public init(intervals: [Double], refreshInterval: Double) {
        self.init(samples: intervals.map { Sample(interval: $0, refreshInterval: refreshInterval) })
    }

    /// Nearest-rank percentile of an ascending array; 0 for an empty one.
    public static func percentile(_ fraction: Double, of sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }
}
