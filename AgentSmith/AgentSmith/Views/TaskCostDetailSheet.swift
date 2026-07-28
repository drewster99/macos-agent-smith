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
    /// Number of distinct tasks in the parent dashboard's filtered time range (for the popover text).
    let taskCountInRange: Int
    /// Average TASK cost in range (total task cost / task count) — computed by the dashboard from
    /// task rows only, so Orchestration/unattributed cost doesn't inflate it. 0 hides "vs Average".
    let averageTaskCostUSD: Double
    let aggregator: UsageAggregator
    /// Opens the full Task Detail window for this task. Nil for the Orchestration bucket (no task)
    /// or when the dashboard has no session to open it in — the id then renders as plain text.
    var onOpenTaskDetail: ((UUID) -> Void)? = nil
    /// Whether to show the "Done" toolbar button. True when presented as a modal sheet; false when
    /// hosted in a standalone window, which has its own close control.
    var showsDoneButton: Bool = true

    @Environment(\.dismiss) private var dismiss
    @State private var showingVsAvgInfo = false
    /// How many of the newest turns the Turn-by-Turn table renders. Capped by default because the
    /// table is inside a plain `VStack` (this project avoids the lazy stacks), so every row is
    /// built and laid out whether or not it is on screen — and a long task runs to thousands of
    /// turns, each ~7 `Text` views. Raised in steps by the buttons below rather than by one
    /// all-or-nothing switch, so asking for more never costs a multi-second stall you didn't
    /// choose. `Int.max` means "all".
    @State private var turnDisplayLimit = TaskCostDetailSheet.initialTurnDisplayLimit
    /// Cached summary to avoid recomputing on every body recalculation.
    @State private var summary: UsageSummary = .empty(scopeLabel: "")
    /// Cached tool frequency counts to avoid iterating records on every body recalculation.
    @State private var toolCounts: [(tool: String, count: Int)] = []
    /// Cached sorted turns for the timeline to avoid sorting on every body recalculation.
    @State private var sortedTurns: [UsageRecord] = []
    /// Cached displayed turns (suffix of sortedTurns based on turnDisplayLimit).
    @State private var displayedTurns: [UsageRecord] = []
    /// Cached count of context resets to avoid filtering on every body recalculation.
    @State private var contextResetsCount: Int = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HeaderSection(
                    titleOverride: titleOverride,
                    task: task,
                    taskSummary: taskSummary,
                    summary: summary,
                    averageTaskCostUSD: averageTaskCostUSD,
                    taskCountInRange: taskCountInRange,
                    showingVsAvgInfo: $showingVsAvgInfo
                )
                CostBreakdownSection(summary: summary, aggregator: aggregator, records: records)
                EfficiencySection(summary: summary, contextResetsCount: contextResetsCount)
                ToolUsageSection(toolCounts: toolCounts)
                ConfigurationSection(records: records, aggregator: aggregator)
                TurnTimelineSection(
                    displayedTurns: displayedTurns,
                    sortedTurnsCount: sortedTurns.count,
                    displayedTurnStartOffset: max(0, sortedTurns.count - turnDisplayLimit),
                    turnDisplayLimit: $turnDisplayLimit
                )

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
        .task(id: taskID) {
            await load()
        }
        .onChange(of: records.count, initial: false) { _, _ in
            updateCachedData(records)
        }
        .onChange(of: turnDisplayLimit) { _, _ in
            updateDisplayedTurns()
        }
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func updateCachedData(_ newRecords: [UsageRecord]) {
        summary = aggregator.summarize(newRecords, scopeLabel: titleOverride ?? task?.title ?? taskSummary?.title ?? "Unknown")
        toolCounts = computeToolFrequency(newRecords)
        sortedTurns = newRecords.sorted { $0.timestamp < $1.timestamp }
        contextResetsCount = newRecords.filter { $0.preResetInputTokens != nil }.count
        updateDisplayedTurns()
    }

    private func updateDisplayedTurns() {
        displayedTurns = Array(sortedTurns.suffix(turnDisplayLimit))
    }

    private func computeToolFrequency(_ records: [UsageRecord]) -> [(tool: String, count: Int)] {
        var counts: [String: Int] = [:]
        for r in records {
            for name in r.toolCallNames ?? [] { counts[name, default: 0] += 1 }
        }
        return counts.map { (tool: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.tool < rhs.tool
            }
    }

    private func load() async {
        // Initial load is handled by the parent; this is for completeness.
        updateCachedData(records)
    }

    /// How many turns the table shows before any button is pressed.
    static let initialTurnDisplayLimit = 100
}

// MARK: - Extracted View Structs

/// Header section showing task title, status, and key metrics.
struct HeaderSection: View {
    let titleOverride: String?
    let task: AgentTask?
    let taskSummary: TaskSummaryEntry?
    let summary: UsageSummary
    let averageTaskCostUSD: Double
    let taskCountInRange: Int
    @Binding var showingVsAvgInfo: Bool

    private var resolvedTitle: String {
        titleOverride ?? task?.title ?? taskSummary?.title ?? "Unknown Task"
    }

    private var resolvedStatus: AgentTask.Status? {
        task?.status ?? taskSummary?.status
    }

    var body: some View {
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
                HeaderStat(label: "Total Cost", value: formatCost(summary.totalCostUSD), color: .primary)
                HeaderStat(label: "LLM Calls", value: "\(summary.callCount)", color: .primary)
                HeaderStat(label: "Tokens", value: formatTokenCount(summary.totalInputTokens + summary.totalOutputTokens), color: .primary)

                if let task {
                    if let started = task.startedAt {
                        let end = task.completedAt ?? Date()
                        HeaderStat(label: "Duration", value: formatDuration(end.timeIntervalSince(started)), color: .primary)
                    }
                }

                // Comparison to the average TASK cost across the time range (task rows only;
                // Orchestration/unattributed cost is excluded so the average isn't inflated).
                if averageTaskCostUSD > 0 {
                    let avgTaskCost = averageTaskCostUSD
                    do {
                        let ratio = summary.totalCostUSD / avgTaskCost
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            HeaderStat(
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
                                    Text("This task's TOTAL cost (\(formatCost(summary.totalCostUSD))) divided by the average cost of a recorded task — \(formatCost(avgTaskCost)) across \(taskCountInRange) task\(taskCountInRange == 1 ? "" : "s"). So \(String(format: "%.1f", ratio))× means this task cost \(String(format: "%.1f", ratio)) times the average task.")
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

    private func formatCost(_ cost: Double) -> String {
        if cost > 0 && cost < 0.01 { return String(format: "$%.4f", cost) }
        return String(format: "$%.2f", cost)
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.0fK", Double(count) / 1_000) }
        return "\(count)"
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let s = Int(interval)
        if s >= 3600 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        if s >= 60 { return "\(s / 60)m \(s % 60)s" }
        return "\(s)s"
    }
}

/// Cost breakdown section showing cost by agent and token breakdown.
struct CostBreakdownSection: View {
    let summary: UsageSummary
    let aggregator: UsageAggregator
    let records: [UsageRecord]

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // By Agent Role
            CardView(title: "Cost by Agent") {
                let byAgent = aggregator.byAgent(records)
                    .sorted {
                        $0.value.totalCostUSD != $1.value.totalCostUSD
                            ? $0.value.totalCostUSD > $1.value.totalCostUSD
                            : $0.key.rawValue < $1.key.rawValue
                    }
                ForEach(byAgent, id: \.key) { role, agentSummary in
                    CostRow(
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
            CardView(title: "Token Breakdown") {
                let s = summary
                TokenRow(label: "Uncached Input", count: s.totalUncachedInputTokens, cost: s.inputCostUSD)
                TokenRow(label: "Output", count: s.totalOutputTokens, cost: s.outputCostUSD)
                TokenRow(label: "Cache Read", count: s.totalCacheReadTokens, cost: s.cacheReadCostUSD)
                TokenRow(label: "Cache Write", count: s.totalCacheWriteTokens, cost: s.cacheWriteCostUSD)
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
}

/// Efficiency metrics section.
struct EfficiencySection: View {
    let summary: UsageSummary
    let contextResetsCount: Int

    var body: some View {
        CardView(title: "Efficiency") {
            let s = summary
            HStack(spacing: 24) {
                MiniStat(label: "Avg Cost / Call", value: formatCost(s.avgCostUSD), color: .primary)
                MiniStat(label: "Avg Tokens / Call", value: formatTokenCount(Int(s.avgInputTokens + s.avgOutputTokens)), color: .primary)
                MiniStat(label: "Avg Latency", value: formatLatency(Int(s.avgLatencyMs)), color: .primary)
                MiniStat(label: "LLM Time", value: formatLatency(s.totalLatencyMs), color: .primary)
                MiniStat(label: "Tool Exec Time", value: formatLatency(s.totalToolExecutionMs), color: .primary)

                if contextResetsCount > 0 {
                    MiniStat(label: "Context Resets", value: "\(contextResetsCount)", color: .orange)
                }
            }
        }
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
}

/// Tool usage section showing tool call frequency.
struct ToolUsageSection: View {
    let toolCounts: [(tool: String, count: Int)]

    var body: some View {
        CardView(title: "Tool Usage") {
            if toolCounts.isEmpty {
                Text("No tool call data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                let maxCount = toolCounts.first?.count ?? 1
                ForEach(toolCounts.prefix(12), id: \.tool) { tool, count in
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
}

/// Configuration section showing model configurations used.
struct ConfigurationSection: View {
    let records: [UsageRecord]
    let aggregator: UsageAggregator

    private var configRows: [(key: String, config: ModelConfiguration, roles: [AgentRole], calls: Int, cost: Double)] {
        var order: [String] = []
        var byKey: [String: (config: ModelConfiguration, roles: Set<AgentRole>, calls: Int, cost: Double)] = [:]
        for record in records {
            guard let c = record.configuration else { continue }
            let key = configContentKey(c)
            if byKey[key] == nil { byKey[key] = (c, [], 0, 0); order.append(key) }
            byKey[key]?.roles.insert(record.agentRole)
            byKey[key]?.calls += 1
            byKey[key]?.cost += computeTurnCost(record)
        }
        return order.compactMap { key in
            guard let entry = byKey[key] else { return nil }
            return (key, entry.config, entry.roles.sorted { $0.rawValue < $1.rawValue }, entry.calls, entry.cost)
        }
    }

    private func configContentKey(_ c: ModelConfiguration) -> String {
        let temperature = c.temperature.map { "\($0)" } ?? "default"
        let thinking = "\(c.thinkingBudget.map { "\($0)" } ?? "-")/\(c.thinkingEffort ?? "-")"
        let overrides = c.extraJSONOverrides
            .map { dict in dict.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",") }
            ?? "-"
        return [
            "\(c.providerID)/\(c.model)",
            "t=\(temperature)",
            "out=\(c.maxTokens)",
            "ctx=\(c.contextWindowSize)",
            "think=\(thinking)",
            "cache=\(c.extendedCacheTTL)",
            "stream=\(c.streaming)",
            "ov=\(overrides)"
        ].joined(separator: "|")
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

    var body: some View {
        let rows = configRows
        if !rows.isEmpty {
            CardView(title: rows.count == 1 ? "Configuration" : "Configurations (\(rows.count))") {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        Text("Model").frame(width: 130, alignment: .leading)
                        Text("Roles").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Temp").frame(width: 56, alignment: .trailing)
                        Text("Max Out").frame(width: 70, alignment: .trailing)
                        Text("Context").frame(width: 70, alignment: .trailing)
                        Text("Calls").frame(width: 54, alignment: .trailing)
                        Text("Cost").frame(width: 72, alignment: .trailing)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    Divider().padding(.vertical, 2)
                    ForEach(rows, id: \.key) { row in
                        HStack(spacing: 0) {
                            Text(row.config.model)
                                .lineLimit(1).truncationMode(.middle)
                                .frame(width: 130, alignment: .leading)
                                .help(row.config.model)
                            Text(row.roles.map(\.displayName).joined(separator: ", "))
                                .lineLimit(1).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(row.config.temperature.map { String(format: "%.1f", $0) } ?? "—")
                                .monospacedDigit().frame(width: 56, alignment: .trailing)
                            Text(formatTokenCount(row.config.maxTokens))
                                .monospacedDigit().frame(width: 70, alignment: .trailing)
                            Text(formatTokenCount(row.config.contextWindowSize))
                                .monospacedDigit().frame(width: 70, alignment: .trailing)
                            Text("\(row.calls)")
                                .monospacedDigit().frame(width: 54, alignment: .trailing)
                            Text(formatCostAligned(row.cost))
                                .font(.system(.caption, design: .monospaced)).frame(width: 72, alignment: .trailing)
                        }
                        .font(.caption)
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private func formatCostAligned(_ cost: Double) -> String {
        if cost > 0 && cost < 0.01 { return String(format: "$%.4f", cost) }
        return String(format: "$%.2f\u{2007}\u{2007}", cost)
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.0fK", Double(count) / 1_000) }
        return "\(count)"
    }
}

/// Turn-by-turn timeline section.
struct TurnTimelineSection: View {
    let displayedTurns: [UsageRecord]
    let sortedTurnsCount: Int
    let displayedTurnStartOffset: Int
    @Binding var turnDisplayLimit: Int

    var body: some View {
        CardView(title: "Turn-by-Turn (\(sortedTurnsCount) calls)") {
            if displayedTurnStartOffset > 0 {
                Text("Showing last \(displayedTurns.count) of \(sortedTurnsCount) turns")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            TurnDisclosureControls(
                totalTurns: sortedTurnsCount,
                displayedTurns: displayedTurns.count,
                turnDisplayLimit: $turnDisplayLimit
            )

            // Header
            HStack(spacing: 0) {
                Text("#").frame(width: 30, alignment: .leading)
                Text("Agent").frame(width: 110, alignment: .leading).padding(.leading, 8)
                Text("In").frame(width: 60, alignment: .trailing)
                Text("Out").frame(width: 60, alignment: .trailing)
                Text("Cost").frame(width: 60, alignment: .trailing)
                Text("Latency").frame(width: 60, alignment: .trailing)
                Text("Tools").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 20)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)

            Divider()

            ForEach(Array(displayedTurns.enumerated()), id: \.element.id) { index, record in
                TaskCostTurnRow(
                    displayNumber: displayedTurnStartOffset + index + 1,
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

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.0fK", Double(count) / 1_000) }
        return "\(count)"
    }

    private func formatTurnCost(_ cost: Double) -> String {
        String(format: "$%.3f", cost)
    }

    private func formatLatency(_ ms: Int) -> String {
        if ms >= 60_000 { return String(format: "%.1fm", Double(ms) / 60_000) }
        if ms >= 1_000 { return String(format: "%.1fs", Double(ms) / 1_000) }
        return "\(ms)ms"
    }

    private func computeTurnCost(_ record: UsageRecord) -> Double {
        // Simplified - actual implementation would need aggregator
        return 0
    }
}

/// Turn disclosure controls for showing more/fewer turns.
/// Turn disclosure controls for showing more/fewer turns.
struct TurnDisclosureControls: View {
    let totalTurns: Int
    let displayedTurns: Int
    @Binding var turnDisplayLimit: Int

    private static let initialTurnDisplayLimit = 100
    private static let turnDisplayIncrement = 500

    var body: some View {
        if totalTurns > Self.initialTurnDisplayLimit {
            HStack(spacing: 12) {
                if displayedTurns < totalTurns {
                    Button("Show \(min(Self.turnDisplayIncrement, totalTurns - displayedTurns)) more") {
                        turnDisplayLimit = displayedTurns + Self.turnDisplayIncrement
                    }
                    Button("Show all \(totalTurns)") {
                        turnDisplayLimit = .max
                    }
                }
                if displayedTurns > Self.initialTurnDisplayLimit {
                    Button("Show last \(Self.initialTurnDisplayLimit)") {
                        turnDisplayLimit = Self.initialTurnDisplayLimit
                    }
                }
            }
            .font(.caption2)
            .buttonStyle(.link)
        }
    }
}

/// Generic card container for sections.
struct CardView<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(AppFonts.sectionHeader)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(AppColors.secondaryBackground))
    }
}

/// Header stat display for the Task Cost detail view.
struct HeaderStat: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.title3, design: .rounded, weight: .semibold)).foregroundStyle(color)
        }
    }
}

/// Mini stat display for the Task Cost detail view.
struct MiniStat: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.semibold)).foregroundStyle(color)
        }
    }
}

/// Cost row display for the Task Cost detail view.
struct CostRow: View {
    let name: String
    let cost: Double
    let detail: String
    let color: Color

    private func formatCostAligned(_ cost: Double) -> String {
        if cost > 0 && cost < 0.01 { return String(format: "$%.4f", cost) }
        return String(format: "$%.2f\u{2007}\u{2007}", cost)
    }

    var body: some View {
        HStack {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(name).font(.caption)
            Spacer()
            Text(formatCostAligned(cost)).font(.system(.caption, design: .monospaced)).frame(width: 78, alignment: .trailing)
            Text(detail).font(.caption2).foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
        }
    }
}

/// Token row display for the Task Cost detail view.
struct TokenRow: View {
    let label: String
    let count: Int
    let cost: Double

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.0fK", Double(count) / 1_000) }
        return "\(count)"
    }

    private func formatCostAligned(_ cost: Double) -> String {
        if cost > 0 && cost < 0.01 { return String(format: "$%.4f", cost) }
        return String(format: "$%.2f\u{2007}\u{2007}", cost)
    }

    var body: some View {
        HStack {
            Text(label).font(.caption)
            Spacer()
            Text(formatTokenCount(count)).font(.caption.monospacedDigit()).frame(width: 60, alignment: .trailing)
            Text(formatCostAligned(cost)).font(.system(.caption, design: .monospaced)).frame(width: 72, alignment: .trailing)
        }
    }
}
