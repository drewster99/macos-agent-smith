import Foundation
import Testing
@testable import AgentSmithKit

/// The numbers the transcript scroll benchmark reports. A wrong hitch count would grade a janky
/// transcript smooth — the benchmark exists to stop exactly that regression going unnoticed.
@Suite("Frame timing stats")
struct FrameTimingStatsTests {
    private let refresh = 1.0 / 60

    @Test("Frames on time are not hitches")
    func onTimeFramesAreSmooth() {
        let stats = FrameTimingStats(intervals: Array(repeating: refresh, count: 60), refreshInterval: refresh)
        #expect(stats.frameCount == 60)
        #expect(stats.hitchCount == 0)
        #expect(stats.totalHitchMs == 0)
        #expect(abs(stats.durationSeconds - 1) < 1e-9)
        #expect(abs(stats.medianIntervalMs - 1000.0 / 60) < 1e-9)
    }

    @Test("Display jitter within the tolerance is not a hitch")
    func jitterIsNotAHitch() {
        let stats = FrameTimingStats(intervals: [refresh * 1.2, refresh * 0.8], refreshInterval: refresh)
        #expect(stats.hitchCount == 0)
    }

    @Test("A dropped frame hitches by the time it was late")
    func droppedFrameCountsItsLateness() {
        // One frame took two refreshes: it was one refresh late.
        let intervals = Array(repeating: refresh, count: 58) + [refresh * 2]
        let stats = FrameTimingStats(intervals: intervals, refreshInterval: refresh)
        #expect(stats.hitchCount == 1)
        #expect(abs(stats.totalHitchMs - 1000.0 / 60) < 1e-6)
        #expect(abs(stats.maxIntervalMs - 2000.0 / 60) < 1e-6)
        // 16.7 ms of hitch over exactly one second of frames.
        #expect(abs(stats.hitchRatioMsPerSecond - 1000.0 / 60) < 1e-6)
    }

    @Test("Each frame is judged at its own refresh rate on a variable-refresh display")
    func mixedRefreshRatesJudgedPerFrame() {
        let fast = 1.0 / 120
        // Mostly 120 Hz, with stretches where the display legitimately dropped to 60 Hz.
        let samples = Array(repeating: FrameTimingStats.Sample(interval: fast, refreshInterval: fast), count: 90)
            + Array(repeating: FrameTimingStats.Sample(interval: refresh, refreshInterval: refresh), count: 30)
        let stats = FrameTimingStats(samples: samples)
        // Judged against one 8.3 ms budget, those 30 on-time 60 Hz frames would be 30 hitches.
        #expect(stats.hitchCount == 0)
        #expect(abs(stats.refreshIntervalMs - 1000.0 / 120) < 1e-9)
        // A frame that took two refreshes AT 120 Hz is one 120 Hz refresh late.
        let late = FrameTimingStats(samples: [FrameTimingStats.Sample(interval: fast * 2, refreshInterval: fast)])
        #expect(late.hitchCount == 1)
        #expect(abs(late.totalHitchMs - 1000.0 / 120) < 1e-6)
    }

    @Test("p95 is the nearest-rank value")
    func percentileNearestRank() {
        let sorted = (1...100).map(Double.init)
        #expect(FrameTimingStats.percentile(0.95, of: sorted) == 95)
        #expect(FrameTimingStats.percentile(0.5, of: sorted) == 50)
        #expect(FrameTimingStats.percentile(1, of: sorted) == 100)
        #expect(FrameTimingStats.percentile(0.95, of: [7]) == 7)
    }

    @Test("No frames reports zeros, not a division by zero")
    func emptyRun() {
        let stats = FrameTimingStats(intervals: [], refreshInterval: refresh)
        #expect(stats.frameCount == 0)
        #expect(stats.hitchRatioMsPerSecond == 0)
        #expect(stats.p95IntervalMs == 0)
    }
}
