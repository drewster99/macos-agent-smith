import AppKit
import AgentSmithKit
import os

/// A request, from the Debug menu, to benchmark one session's main transcript. A new value per
/// click (`id`), so clicking twice runs twice.
nonisolated struct TranscriptScrollBenchmarkRequest: Equatable, Sendable {
    let id = UUID()
    let sessionID: UUID
}

/// How smoothly the transcript drew while scrolled at a fixed speed — the number that says
/// whether a transcript change made scrolling worse. `docs/plans/TranscriptScrollPerformance.md`.
struct TranscriptScrollBenchmarkResult: Codable {
    static let durationSeconds: Double = 10
    /// A brisk flick: fast enough that most frames bring new rows on screen.
    static let speedPointsPerSecond: CGFloat = 4000
    /// Less scrollback than this many screenfuls re-draws the same few rows — not a measurement.
    static let minimumScrollableViewports: CGFloat = 5

    let date: Date
    let rowCount: Int
    let documentHeight: Double
    let stats: FrameTimingStats
    /// Stored, not computed, so it is in the saved JSON — a Debug number and a Release number are
    /// not comparable.
    var buildConfiguration = TranscriptScrollBenchmarkResult.currentBuildConfiguration

    static var currentBuildConfiguration: String {
        #if DEBUG
        return "Debug"
        #else
        return "Release"
        #endif
    }
}

/// What a benchmark request came to.
enum TranscriptScrollBenchmarkOutcome {
    case completed(TranscriptScrollBenchmarkResult)
    /// Refused: not enough transcript to scroll through.
    case tooShort(scrollableHeight: Double, viewportHeight: Double)
}

/// Writes a benchmark result where it can be compared later, and shows the headline numbers.
enum TranscriptScrollBenchmarkReporter {
    private static let logger = Logger(subsystem: "com.agentsmith", category: "TranscriptBenchmark")

    /// Next to the LLM request logs: `$TMPDIR/AgentSmith-Benchmarks/`.
    static var resultsDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("AgentSmith-Benchmarks", isDirectory: true)
    }

    static func report(_ outcome: TranscriptScrollBenchmarkOutcome) {
        switch outcome {
        case .completed(let result):
            report(result)
        case .tooShort(let scrollableHeight, let viewportHeight):
            let alert = NSAlert()
            alert.messageText = "Transcript Scroll Benchmark"
            alert.informativeText = String(
                format: "Not run: the transcript scrolls %.0f pt, less than %.0f screenfuls (%.0f pt). Benchmark a longer transcript.",
                scrollableHeight, TranscriptScrollBenchmarkResult.minimumScrollableViewports,
                viewportHeight * TranscriptScrollBenchmarkResult.minimumScrollableViewports)
            alert.runModal()
        }
    }

    private static func report(_ result: TranscriptScrollBenchmarkResult) {
        let stats = result.stats
        let summary = String(
            format: "%@ build, %d rows, %d frames over %.1fs\nHitch ratio %.1f ms/s (%d hitches, %.0f ms)\nFrame interval median %.1f ms, p95 %.1f ms, max %.1f ms (refresh %.1f ms)",
            result.buildConfiguration, result.rowCount, stats.frameCount, stats.durationSeconds,
            stats.hitchRatioMsPerSecond, stats.hitchCount, stats.totalHitchMs,
            stats.medianIntervalMs, stats.p95IntervalMs, stats.maxIntervalMs, stats.refreshIntervalMs
        )
        logger.notice("Transcript scroll benchmark: \(summary, privacy: .public)")

        let alert = NSAlert()
        alert.messageText = "Transcript Scroll Benchmark"
        do {
            let file = try write(result)
            alert.informativeText = summary + "\n\nSaved to \(file.path)"
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Show in Finder")
            if alert.runModal() == .alertSecondButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([file])
            }
        } catch {
            logger.error("Transcript scroll benchmark: saving failed: \(error.localizedDescription, privacy: .public)")
            alert.informativeText = summary + "\n\nNot saved: \(error.localizedDescription)"
            alert.runModal()
        }
    }

    private static func write(_ result: TranscriptScrollBenchmarkResult) throws -> URL {
        try FileManager.default.createDirectory(at: resultsDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let stamp = ISO8601DateFormatter().string(from: result.date).replacingOccurrences(of: ":", with: "-")
        let file = resultsDirectory.appendingPathComponent("transcript-scroll-\(result.buildConfiguration)-\(stamp).json")
        try encoder.encode(result).write(to: file, options: .atomic)
        return file
    }
}
