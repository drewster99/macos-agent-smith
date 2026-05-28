import SwiftUI
import Charts
import AgentSmithKit
import SwiftLLMKit

// MARK: - Task Cost Detail Sheet

/// Sheet showing detailed cost and usage metrics for a single task.
/// Opened by clicking a task row in the Spending Dashboard's task ledger.
struct TaskCostDetailSheet: View {
    let taskID: UUID
    let task: AgentTask?
    /// Persisted summary of a completed/failed task, used to resolve title and status
    /// when the live `AgentTask` isn't reachable from the dashboard.
    let taskSummary: TaskSummaryEntry?
    let records: [UsageRecord]
    let allRecordsSummary: UsageSummary
    /// Number of distinct tasks in the parent dashboard's filtered time range,
    /// used to compute "vs average task cost" comparison.
    let taskCountInRange: Int
    let aggregator: UsageAggregator
    let providerNames: [String: String]

    @Environment(\.dismiss) private var dismiss

    private var summary: UsageSummary {
        aggregator.summarize(records, scopeLabel: task?.title ?? taskSummary?.title ?? "Unknown")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection()
                costBreakdownSection()
                efficiencySection()
                toolUsageSection()
                configurationSection()
                turnTimelineSection()

                // Task ID in the lower right corner
                HStack {
                    Spacer()
                    Text(taskID.uuidString)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
            .padding(24)
        }
        .frame(minWidth: 600, minHeight: 500)
        .background(AppColors.background)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    // MARK: - Header

    @ViewBuilder

    private func headerSection() -> some View {
        let resolvedTitle = task?.title ?? taskSummary?.title ?? "Unknown Task"
        let resolvedStatus: AgentTask.Status? = task?.status ?? taskSummary?.status
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(resolvedTitle)
                    .font(.title2.bold())
                Spacer()
                if let resolvedStatus {
                    HStack(spacing: 4) {
                        Image(systemName: TaskStatusBadge.icon(for: resolvedStatus))
                            .foregroundStyle(TaskStatusBadge.color(for: resolvedStatus))
                        Text(resolvedStatus.rawValue.capitalized)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(TaskStatusBadge.color(for: resolvedStatus))
                    }
                }
            }

            HStack(spacing: 20) {
                headerStat(label: "Total Cost", value: formatCost(summary.totalCostUSD))
                headerStat(label: "LLM Calls", value: "\(summary.callCount)")
                headerStat(label: "Tokens", value: formatTokenCount(summary.totalInputTokens + summary.totalOutputTokens))

                if let task {
                    if let started = task.startedAt {
                        let end = task.completedAt ?? Date()
                        headerStat(label: "Duration", value: formatDuration(end.timeIntervalSince(started)))
                    }
                }

                // Comparison to average task cost across the time range
                if allRecordsSummary.callCount > 0 && taskCountInRange > 0 {
                    let avgTaskCost = allRecordsSummary.totalCostUSD / Double(taskCountInRange)
                    if avgTaskCost > 0 {
                        let ratio = summary.totalCostUSD / avgTaskCost
                        headerStat(
                            label: "vs Average",
                            value: String(format: "%.1fx", ratio),
                            color: ratio > 2 ? .red : ratio > 1 ? .orange : .green
                        )
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(AppColors.secondaryBackground))
    }

    // MARK: - Cost Breakdown

    @ViewBuilder

    private func costBreakdownSection() -> some View {
        HStack(alignment: .top, spacing: 16) {
            // By Agent Role
            card(title: "Cost by Agent") {
                let byAgent = aggregator.byAgent(records)
                    .sorted { $0.value.totalCostUSD > $1.value.totalCostUSD }
                ForEach(byAgent, id: \.key) { role, agentSummary in
                    costRow(
                        name: role.displayName,
                        cost: agentSummary.totalCostUSD,
                        detail: "\(agentSummary.callCount) calls",
                        color: AppColors.color(for: .agent(role))
                    )
                }
                if !byAgent.contains(where: { $0.key == .smith }) {
                    Text("Smith's costs are not attributed to individual tasks (Smith orchestrates but is not assigned as a task worker).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }

            // By Token Category
            card(title: "Token Breakdown") {
                let s = summary
                tokenRow(label: "Uncached Input", count: s.totalUncachedInputTokens, cost: s.inputCostUSD)
                tokenRow(label: "Output", count: s.totalOutputTokens, cost: s.outputCostUSD)
                tokenRow(label: "Cache Read", count: s.totalCacheReadTokens, cost: s.cacheReadCostUSD)
                tokenRow(label: "Cache Write", count: s.totalCacheWriteTokens, cost: s.cacheWriteCostUSD)
                Divider()
                HStack {
                    Text("Cache Hit Rate")
                        .font(.caption)
                    Spacer()
                    Text(String(format: "%.0f%%", s.cacheHitRate * 100))
                        .font(.caption.monospacedDigit().weight(.semibold))
                }
            }
        }
    }

    // MARK: - Efficiency Metrics

    @ViewBuilder

    private func efficiencySection() -> some View {
        card(title: "Efficiency") {
            let s = summary
            HStack(spacing: 24) {
                miniStat(label: "Avg Cost / Call", value: formatCost(s.avgCostUSD))
                miniStat(label: "Avg Tokens / Call", value: formatTokenCount(Int(s.avgInputTokens + s.avgOutputTokens)))
                miniStat(label: "Avg Latency", value: formatLatency(Int(s.avgLatencyMs)))
                miniStat(label: "LLM Time", value: formatLatency(s.totalLatencyMs))
                miniStat(label: "Tool Exec Time", value: formatLatency(s.totalToolExecutionMs))

                let contextResets = records.filter { $0.preResetInputTokens != nil }.count
                if contextResets > 0 {
                    miniStat(label: "Context Resets", value: "\(contextResets)", color: .orange)
                }
            }
        }
    }

    // MARK: - Tool Usage

    @ViewBuilder

    private func toolUsageSection() -> some View {
        card(title: "Tool Usage") {
            let toolCounts = toolFrequency(records)
                .sorted { $0.value > $1.value }
            if toolCounts.isEmpty {
                Text("No tool call data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                let maxCount = toolCounts.first?.value ?? 1
                ForEach(toolCounts.prefix(12), id: \.key) { tool, count in
                    HStack(spacing: 8) {
                        Text(tool)
                            .font(.caption)
                            .frame(width: 160, alignment: .leading)
                            .lineLimit(1)
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.accentColor.opacity(0.5))
                                .frame(width: max(2, geo.size.width * Double(count) / Double(maxCount)))
                        }
                        .frame(height: 8)
                        Text("\(count)")
                            .font(.caption.monospacedDigit())
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: - Configuration

    @ViewBuilder

    private func configurationSection() -> some View {
        let configs = Set(records.compactMap { $0.configuration?.id })
        let configRecords = records.compactMap(\.configuration)
        if let primaryConfig = configRecords.first {
            card(title: "Configuration") {
                HStack(spacing: 24) {
                    miniStat(label: "Model", value: primaryConfig.model)
                    miniStat(label: "Temperature", value: primaryConfig.temperature.map { String(format: "%.1f", $0) } ?? "default")
                    miniStat(label: "Max Output", value: formatTokenCount(primaryConfig.maxTokens))
                    miniStat(label: "Context Window", value: formatTokenCount(primaryConfig.contextWindowSize))
                    if configs.count > 1 {
                        miniStat(label: "Configs Used", value: "\(configs.count)", color: .orange)
                    }
                }
            }
        }
    }

    // MARK: - Turn Timeline

    @ViewBuilder

    private func turnTimelineSection() -> some View {
        card(title: "Turn-by-Turn (\(records.count) calls)") {
            let sorted = records.sorted { $0.timestamp < $1.timestamp }
            let displayedTurns = Array(sorted.suffix(100))
            let startOffset = sorted.count - displayedTurns.count

            if sorted.count > 100 {
                Text("Showing last 100 of \(sorted.count) turns")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Header
            HStack(spacing: 0) {
                Text("#").frame(width: 30, alignment: .trailing)
                Text("Agent").frame(width: 60, alignment: .leading).padding(.leading, 8)
                Text("In").frame(width: 60, alignment: .trailing)
                Text("Out").frame(width: 60, alignment: .trailing)
                Text("Cost").frame(width: 60, alignment: .trailing)
                Text("Latency").frame(width: 60, alignment: .trailing)
                Text("Tools").frame(width: 150, alignment: .leading).padding(.leading, 8)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)

            Divider()

            ForEach(Array(displayedTurns.enumerated()), id: \.element.id) { index, record in
                TaskCostTurnRow(
                    displayNumber: startOffset + index + 1,
                    agentRole: record.agentRole,
                    inputTokensFormatted: formatTokenCount(record.inputTokens),
                    outputTokensFormatted: formatTokenCount(record.outputTokens),
                    costFormatted: formatCost(computeTurnCost(record)),
                    latencyFormatted: formatLatency(record.latencyMs),
                    toolNames: (record.toolCallNames ?? []).joined(separator: ", ")
                )
            }
        }
    }

    // MARK: - Helpers

    private func card<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(AppFonts.sectionHeader)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(AppColors.secondaryBackground))
    }

    private func headerStat(label: String, value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.title3, design: .rounded, weight: .semibold)).foregroundStyle(color)
        }
    }

    private func miniStat(label: String, value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.semibold)).foregroundStyle(color)
        }
    }

    private func costRow(name: String, cost: Double, detail: String, color: Color) -> some View {
        HStack {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(name).font(.caption)
            Spacer()
            Text(formatCost(cost)).font(.caption.monospacedDigit())
            Text(detail).font(.caption2).foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
        }
    }

    private func tokenRow(label: String, count: Int, cost: Double) -> some View {
        HStack {
            Text(label).font(.caption)
            Spacer()
            Text(formatTokenCount(count)).font(.caption.monospacedDigit()).frame(width: 60, alignment: .trailing)
            Text(formatCost(cost)).font(.caption.monospacedDigit()).frame(width: 60, alignment: .trailing)
        }
    }

    private func toolFrequency(_ records: [UsageRecord]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for r in records {
            for name in r.toolCallNames ?? [] { counts[name, default: 0] += 1 }
        }
        return counts
    }

    private func computeTurnCost(_ record: UsageRecord) -> Double {
        guard let providerID = record.providerID else { return 0 }
        guard let pricing = aggregator.pricingLookup(providerID, record.modelID) else { return 0 }
        let rates = pricing.effectiveRates(totalInputTokens: record.inputTokens)
        let uncached = max(0, record.inputTokens - record.cacheReadTokens - record.cacheWriteTokens)
        return Double(uncached) * (rates.input ?? 0)
             + Double(record.outputTokens) * (rates.output ?? 0)
             + Double(record.cacheReadTokens) * (rates.cacheRead ?? 0)
             + Double(record.cacheWriteTokens) * (rates.cacheWrite ?? 0)
    }

    private func formatCost(_ cost: Double) -> String {
        if cost > 0 && cost < 0.01 { return String(format: "$%.4f", cost) }
        return String(format: "$%.2f", cost)
    }
    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.0fK", Double(count) / 1_000) }
        return "\(count)"
    }
    private func formatLatency(_ ms: Int) -> String {
        if ms >= 60_000 { return String(format: "%.1fm", Double(ms) / 60_000) }
        if ms >= 1_000 { return String(format: "%.1fs", Double(ms) / 1_000) }
        return "\(ms)ms"
    }
    private func formatDuration(_ interval: TimeInterval) -> String {
        let s = Int(interval)
        if s >= 3600 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        if s >= 60 { return "\(s / 60)m \(s % 60)s" }
        return "\(s)s"
    }
}
