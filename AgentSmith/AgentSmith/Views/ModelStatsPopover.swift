import AVFoundation
import SwiftUI
import SwiftLLMKit
import AgentSmithKit

// MARK: - Model Stats Popover

/// Aggregated stats computed from LLM turn records for a given agent role.
private struct ModelStats {
    let totalCalls: Int
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let totalCacheReadTokens: Int
    let totalCacheWriteTokens: Int
    let totalToolCalls: Int
    let avgLatencyMs: Int
    let maxLatencyMs: Int
    let contextResets: Int

    // Per-call extremes
    let maxInputTokens: Int
    let maxOutputTokens: Int
    let lastInputTokens: Int
    let lastOutputTokens: Int
    let lastCacheReadTokens: Int

    /// Input tokens minus cache read and cache write (billed at full input rate).
    var uncachedInputTokens: Int {
        max(0, totalInputTokens - totalCacheReadTokens - totalCacheWriteTokens)
    }

    /// Combined input + output.
    var totalTokens: Int { totalInputTokens + totalOutputTokens }

    /// Fraction of input served from cache.
    var cacheHitRate: Double {
        guard totalInputTokens > 0 else { return 0 }
        return Double(totalCacheReadTokens) / Double(totalInputTokens)
    }

    var avgInputTokens: Int { totalCalls > 0 ? totalInputTokens / totalCalls : 0 }
    var avgOutputTokens: Int { totalCalls > 0 ? totalOutputTokens / totalCalls : 0 }

    init(turns: [LLMTurnRecord]) {
        totalCalls = turns.count
        totalInputTokens = turns.compactMap(\.usage?.inputTokens).reduce(0, +)
        totalOutputTokens = turns.compactMap(\.usage?.outputTokens).reduce(0, +)
        totalCacheReadTokens = turns.compactMap(\.usage?.cacheReadTokens).reduce(0, +)
        totalCacheWriteTokens = turns.compactMap(\.usage?.cacheWriteTokens).reduce(0, +)
        totalToolCalls = turns.reduce(0) { $0 + $1.response.toolCalls.count }
        let latencies = turns.map(\.latencyMs).filter { $0 > 0 }
        avgLatencyMs = latencies.isEmpty ? 0 : latencies.reduce(0, +) / latencies.count
        maxLatencyMs = latencies.max() ?? 0

        maxInputTokens = turns.compactMap(\.usage?.inputTokens).max() ?? 0
        maxOutputTokens = turns.compactMap(\.usage?.outputTokens).max() ?? 0

        let last = turns.last
        lastInputTokens = last?.usage?.inputTokens ?? 0
        lastOutputTokens = last?.usage?.outputTokens ?? 0
        lastCacheReadTokens = last?.usage?.cacheReadTokens ?? 0

        // Count turns where input tokens dropped significantly (context reset indicator)
        var resets = 0
        var prevInput = 0
        for turn in turns {
            let input = turn.usage?.inputTokens ?? 0
            if prevInput > 0 && input < prevInput / 2 { resets += 1 }
            prevInput = input
        }
        contextResets = resets
    }
}

/// Popover showing aggregated session statistics for an agent's model usage.
struct ModelStatsPopover: View {
    let turns: [LLMTurnRecord]
    let modelID: String
    let role: AgentRole

    var body: some View {
        // Compute once per body. The earlier `private var stats: ModelStats` was rebuilt
        // every time `body` evaluated and again on each Grid row that referenced it,
        // each time iterating the turns array several times.
        let stats = ModelStats(turns: turns)
        return VStack(alignment: .leading, spacing: 8) {
            Text("\(role.displayName) — Session Stats")
                .font(.headline)

            Text(modelID)
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                // -- Overview --
                sectionHeader("Overview")
                statRow("LLM calls", "\(stats.totalCalls)")
                statRow("Tool calls issued", "\(stats.totalToolCalls)")
                statRow("Context resets", "\(stats.contextResets)")

                // -- Latency --
                GridRow { Divider().gridCellColumns(2) }
                sectionHeader("Latency")
                statRow("Avg response time", formatLatency(stats.avgLatencyMs))
                statRow("Max response time", formatLatency(stats.maxLatencyMs))

                // -- Token Totals --
                GridRow { Divider().gridCellColumns(2) }
                sectionHeader("Token Totals")
                statRow("Total tokens", formatCount(stats.totalTokens))
                statRow("Input tokens", formatCount(stats.totalInputTokens))
                statRow("Output tokens", formatCount(stats.totalOutputTokens))

                // -- Cache Breakdown --
                if stats.totalCacheReadTokens > 0 || stats.totalCacheWriteTokens > 0 {
                    GridRow { Divider().gridCellColumns(2) }
                    sectionHeader("Cache")
                    statRow("Uncached input", formatCount(stats.uncachedInputTokens))
                    statRow("Cache read", formatCount(stats.totalCacheReadTokens))
                    statRow("Cache write", formatCount(stats.totalCacheWriteTokens))
                    statRow("Cache hit rate", formatPercent(stats.cacheHitRate))
                }

                // -- Per-Call Averages --
                GridRow { Divider().gridCellColumns(2) }
                sectionHeader("Per-Call Averages")
                statRow("Avg input / call", formatCount(stats.avgInputTokens))
                statRow("Avg output / call", formatCount(stats.avgOutputTokens))

                // -- Per-Call Extremes --
                GridRow { Divider().gridCellColumns(2) }
                sectionHeader("Per-Call Max")
                statRow("Max input", formatCount(stats.maxInputTokens))
                statRow("Max output", formatCount(stats.maxOutputTokens))

                // -- Last Turn --
                if stats.totalCalls > 0 {
                    GridRow { Divider().gridCellColumns(2) }
                    sectionHeader("Last Turn")
                    statRow("Input", formatCount(stats.lastInputTokens))
                    statRow("Output", formatCount(stats.lastOutputTokens))
                    if stats.lastCacheReadTokens > 0 {
                        statRow("Cache read", formatCount(stats.lastCacheReadTokens))
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 260)
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        GridRow {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .gridCellColumns(2)
        }
    }

    @ViewBuilder
    private func statRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit())
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func formatCount(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }

    private func formatLatency(_ ms: Int) -> String {
        guard ms > 0 else { return "—" }
        if ms < 1000 { return "\(ms)ms" }
        return String(format: "%.1fs", Double(ms) / 1000.0)
    }

    private func formatPercent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }
}
