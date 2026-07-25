import SwiftUI
import Charts
import AgentSmithKit
import SwiftLLMKit

// MARK: - Task Cost Detail Sheet

/// Sheet showing detailed cost and usage metrics for a single task.
/// Opened by clicking a task row in the Spending Dashboard's task ledger.
struct TaskCostDetailSheet: View {
    /// The task this sheet details, or nil for the Orchestration bucket (records attributed to
    /// no task). When nil, `titleOverride` names the sheet and the id footer is hidden.
    let taskID: UUID?
    /// Title to show when there's no task to resolve one from (the Orchestration bucket).
    var titleOverride: String? = nil
    let task: AgentTask?
    /// Persisted summary of a completed/failed task, used to resolve title and status
    /// when the live `AgentTask` isn't reachable from the dashboard.
    let taskSummary: TaskSummaryEntry?
    let records: [UsageRecord]
    let allRecordsSummary: UsageSummary
    /// Number of distinct tasks in the parent dashboard's filtered time range (for the popover text).
    let taskCountInRange: Int
    /// Average TASK cost in range (total task cost / task count) — computed by the dashboard from
    /// task rows only, so Orchestration/unattributed cost doesn't inflate it. 0 hides "vs Average".
    let averageTaskCostUSD: Double
    let aggregator: UsageAggregator
    let providerNames: [String: String]
    /// Opens the full Task Detail window for this task. Nil for the Orchestration bucket (no task)
    /// or when the dashboard has no session to open it in — the id then renders as plain text.
    var onOpenTaskDetail: ((UUID) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var showingVsAvgInfo = false

    private var summary: UsageSummary {
        aggregator.summarize(records, scopeLabel: titleOverride ?? task?.title ?? taskSummary?.title ?? "Unknown")
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

                // Task ID in the lower right corner (omitted for the Orchestration bucket).
                // Clickable to open the full Task Detail window when the dashboard supplied an action.
                if let taskID {
                    HStack {
                        Spacer()
                        if let onOpenTaskDetail {
                            Button(action: { onOpenTaskDetail(taskID) }, label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.up.forward.square")
                                    Text(taskID.uuidString)
                                }
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                            })
                            .buttonStyle(.plain)
                            .help("Open the full task detail window")
                        } else {
                            Text(taskID.uuidString)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                        }
                    }
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
        let resolvedTitle = titleOverride ?? task?.title ?? taskSummary?.title ?? "Unknown Task"
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
                        Text(resolvedStatus.displayName)
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

                // Comparison to the average TASK cost across the time range (task rows only;
                // Orchestration/unattributed cost is excluded so the average isn't inflated).
                if averageTaskCostUSD > 0 {
                    let avgTaskCost = averageTaskCostUSD
                    do {
                        let ratio = summary.totalCostUSD / avgTaskCost
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            headerStat(
                                label: "vs Average",
                                value: String(format: "%.1fx", ratio),
                                color: ratio > 2 ? .red : ratio > 1 ? .orange : .green
                            )
                            Button(action: { showingVsAvgInfo = true }, label: {
                                Image(systemName: "info.circle").font(.caption2).foregroundStyle(.tertiary)
                            })
                            .buttonStyle(.plain)
                            .popover(isPresented: $showingVsAvgInfo, arrowEdge: .bottom) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("vs Average").font(.headline)
                                    Text("This task's TOTAL cost (\(formatCost(summary.totalCostUSD))) divided by the average total cost of a task in the selected range — \(formatCost(avgTaskCost)) across \(taskCountInRange) task\(taskCountInRange == 1 ? "" : "s"). So \(String(format: "%.1f", ratio))× means this task cost \(String(format: "%.1f", ratio)) times the average task.")
                                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(12).frame(width: 340)
                            }
                        }
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
                    .sorted {
                        $0.value.totalCostUSD != $1.value.totalCostUSD
                            ? $0.value.totalCostUSD > $1.value.totalCostUSD
                            : $0.key.rawValue < $1.key.rawValue
                    }
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
            // Deterministic order: by count desc, then tool name asc to break ties. Without the
            // tie-breaker, equal-count tools came out in the dictionary's (randomized) iteration
            // order and visibly reshuffled on every re-render.
            let toolCounts = toolFrequency(records)
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
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

    /// Every DISTINCT model configuration that produced a record for this task, in first-seen
    /// order, with the roles that used it and its call count. Grouping is imperative, so it lives
    /// outside the `@ViewBuilder` body.
    private func configRows() -> [(key: String, config: ModelConfiguration, roles: [AgentRole], calls: Int)] {
        // Group by CONTENT (provider/model + temperature + max output + context), not the config's
        // UUID: a config edited in place keeps its id, so id-grouping would fold pre- and post-edit
        // settings into one row showing whichever was seen first. Content grouping shows each
        // distinct setting as its own row and also merges identical settings across roles.
        var order: [String] = []
        var byKey: [String: (config: ModelConfiguration, roles: Set<AgentRole>, calls: Int)] = [:]
        for record in records {
            guard let c = record.configuration else { continue }
            let key = "\(c.providerID)/\(c.model)|t=\(c.temperature.map { String(format: "%.2f", $0) } ?? "d")|max=\(c.maxTokens)|ctx=\(c.contextWindowSize)"
            if byKey[key] == nil { byKey[key] = (c, [], 0); order.append(key) }
            byKey[key]?.roles.insert(record.agentRole)
            byKey[key]?.calls += 1
        }
        return order.compactMap { key in
            guard let entry = byKey[key] else { return nil }
            return (key, entry.config, entry.roles.sorted { $0.rawValue < $1.rawValue }, entry.calls)
        }
    }

    @ViewBuilder
    private func configurationSection() -> some View {
        let rows = configRows()
        if !rows.isEmpty {
            card(title: rows.count == 1 ? "Configuration" : "Configurations (\(rows.count))") {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        Text("Model").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Roles").frame(width: 210, alignment: .leading)
                        Text("Temp").frame(width: 56, alignment: .trailing)
                        Text("Max Out").frame(width: 70, alignment: .trailing)
                        Text("Context").frame(width: 70, alignment: .trailing)
                        Text("Calls").frame(width: 54, alignment: .trailing)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    Divider().padding(.vertical, 2)
                    ForEach(rows, id: \.key) { row in
                        HStack(spacing: 0) {
                            Text(row.config.model)
                                .lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(row.roles.map(\.displayName).joined(separator: ", "))
                                .lineLimit(1).foregroundStyle(.secondary)
                                .frame(width: 210, alignment: .leading)
                            Text(row.config.temperature.map { String(format: "%.1f", $0) } ?? "—")
                                .monospacedDigit().frame(width: 56, alignment: .trailing)
                            Text(formatTokenCount(row.config.maxTokens))
                                .monospacedDigit().frame(width: 70, alignment: .trailing)
                            Text(formatTokenCount(row.config.contextWindowSize))
                                .monospacedDigit().frame(width: 70, alignment: .trailing)
                            Text("\(row.calls)")
                                .monospacedDigit().frame(width: 54, alignment: .trailing)
                        }
                        .font(.caption)
                        .padding(.vertical, 2)
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
                    costFormatted: formatTurnCost(computeTurnCost(record)),
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
            Text(formatCostAligned(cost)).font(.system(.caption, design: .monospaced)).frame(width: 78, alignment: .trailing)
            Text(detail).font(.caption2).foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
        }
    }

    private func tokenRow(label: String, count: Int, cost: Double) -> some View {
        HStack {
            Text(label).font(.caption)
            Spacer()
            Text(formatTokenCount(count)).font(.caption.monospacedDigit()).frame(width: 60, alignment: .trailing)
            Text(formatCostAligned(cost)).font(.system(.caption, design: .monospaced)).frame(width: 72, alignment: .trailing)
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
    /// Same adaptive precision as `formatCost` (2 decimals, or 4 for sub-penny), but the 2-decimal
    /// case is padded so the fraction is always 4 characters wide. Under a right-aligned MONOSPACED
    /// font that puts the decimal point at a fixed offset from the right, so a column of these lines
    /// up on the decimal regardless of integer width. The pad is U+2007 FIGURE SPACE (digit-width,
    /// and not collapsed the way trailing ASCII spaces can be). Use with a monospaced font + trailing frame.
    private func formatCostAligned(_ cost: Double) -> String {
        if cost > 0 && cost < 0.01 { return String(format: "$%.4f", cost) }
        return String(format: "$%.2f\u{2007}\u{2007}", cost)
    }
    /// Per-turn cost — always 3 decimals so the (monospaced) column's decimal points line up
    /// and sub-penny turns stay legible. Turn-by-turn only; summary/breakdown rows use `formatCost`.
    private func formatTurnCost(_ cost: Double) -> String {
        String(format: "$%.3f", cost)
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
