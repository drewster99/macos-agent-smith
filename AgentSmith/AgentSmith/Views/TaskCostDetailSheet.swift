import SwiftUI
import Charts
import AgentSmithKit
import SwiftLLMKit

// MARK: - Task Cost Detail Sheet

/// Sheet showing detailed cost and usage metrics for a single task.
struct TaskCostDetailSheet: View {
    let taskID: UUID?
    var titleOverride: String? = nil
    let task: AgentTask?
    let taskSummary: TaskSummaryEntry?
    let records: [UsageRecord]
    let taskCountInRange: Int
    let averageTaskCostUSD: Double
    let aggregator: UsageAggregator
    var onOpenTaskDetail: ((UUID) -> Void)? = nil
    var showsDoneButton: Bool = true

    @Environment(\.dismiss) private var dismiss
    @State private var showingVsAvgInfo = false
    @State private var turnDisplayLimit = TaskCostDetailSheet.initialTurnDisplayLimit
    
    // All cached data to avoid recomputing on every body recalculation
    @State private var summary: UsageSummary = .empty(scopeLabel: "")
    @State private var toolCounts: [(tool: String, count: Int)] = []
    @State private var sortedTurns: [UsageRecord] = []
    @State private var displayedTurns: [UsageRecord] = []
    @State private var contextResetsCount: Int = 0
    @State private var costByAgent: [(role: AgentRole, calls: Int, cost: Double)] = []
    @State private var tokenBreakdown: [TokenBreakdownRow] = []
    @State private var efficiencyMetrics: EfficiencyMetrics = EfficiencyMetrics()
    @State private var configRows: [ConfigRow] = []
    @State private var turnRows: [TurnRow] = []
    @State private var resolvedTitle: String = ""
    @State private var resolvedStatus: AgentTask.Status? = nil
    @State private var durationText: String? = nil
    @State private var toolMaxCount: Int = 1
    @State private var displayedTurnStartOffset: Int = 0

    struct EfficiencyMetrics {
        var avgCostUSD: Double = 0
        var avgTokensPerCall: Int = 0
        var avgLatencyMs: Int = 0
        var totalLatencyMs: Int = 0
        var totalToolExecutionMs: Int = 0
        var cacheHitRate: Double = 0
    }

    struct ConfigRow: Equatable {
        let key: String
        let model: String
        let roles: [String]
        let temperature: String
        let maxTokens: String
        let contextSize: String
        let calls: Int
        let cost: Double
    }

    struct TurnRow: Equatable {
        let displayNumber: Int
        let agentRole: AgentRole
        let inputTokens: String
        let outputTokens: String
        let cost: String
        let latency: String
        let toolNames: String
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HeaderSection(
                    resolvedTitle: resolvedTitle,
                    resolvedStatus: resolvedStatus,
                    summary: summary,
                    averageTaskCostUSD: averageTaskCostUSD,
                    taskCountInRange: taskCountInRange,
                    durationText: durationText,
                    showingVsAvgInfo: $showingVsAvgInfo
                )
                CostBreakdownSection(costByAgent: costByAgent, tokenBreakdown: tokenBreakdown, aggregator: aggregator)
                EfficiencySection(metrics: efficiencyMetrics, contextResetsCount: contextResetsCount)
                ToolUsageSection(toolCounts: toolCounts, maxCount: toolMaxCount)
                ConfigurationSection(configRows: configRows)
                TurnTimelineSection(
                    turnRows: turnRows,
                    sortedTurnsCount: sortedTurns.count,
                    displayedTurnStartOffset: displayedTurnStartOffset,
                    turnDisplayLimit: $turnDisplayLimit
                )
                TurnDisclosureControls(
                    totalTurns: sortedTurns.count,
                    displayedTurns: displayedTurns.count,
                    turnDisplayLimit: $turnDisplayLimit
                )

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
        .onChange(of: records, initial: false) { _, newRecords in
            updateCachedData(newRecords)
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
        // Update summary
        summary = aggregator.summarize(newRecords, scopeLabel: titleOverride ?? task?.title ?? taskSummary?.title ?? "Unknown")
        
        // Update resolved title and status
        resolvedTitle = titleOverride ?? task?.title ?? taskSummary?.title ?? "Unknown Task"
        resolvedStatus = task?.status ?? taskSummary?.status
        
        // Update duration text
        if let t = task, let started = t.startedAt {
            let end = t.completedAt ?? Date()
            durationText = formatDuration(end.timeIntervalSince(started))
        } else {
            durationText = nil
        }
        
        // Update tool counts
        var counts: [String: Int] = [:]
        for r in newRecords {
            for name in r.toolCallNames ?? [] { counts[name, default: 0] += 1 }
        }
        toolCounts = counts.map { (tool: $0.key, count: $0.value) }
            .sorted { lhs, rhs in lhs.count != rhs.count ? lhs.count > rhs.count : lhs.tool < rhs.tool }
        toolMaxCount = toolCounts.first?.count ?? 1
        
        // Update sorted turns
        sortedTurns = newRecords.sorted { $0.timestamp < $1.timestamp }
        
        // Update context resets count
        contextResetsCount = newRecords.filter { $0.preResetInputTokens != nil }.count
        
        // Update cost by agent
        let byAgent = aggregator.byAgent(newRecords)
            .sorted { $0.value.totalCostUSD != $1.value.totalCostUSD ? $0.value.totalCostUSD > $1.value.totalCostUSD : $0.key.rawValue < $1.key.rawValue }
        costByAgent = byAgent.map { (role: $0.key, calls: $0.value.callCount, cost: $0.value.totalCostUSD) }
        
        // Update token breakdown
        let s = summary
        tokenBreakdown = [
            TokenBreakdownRow(id: "uncached_input", label: "Uncached Input", count: s.totalUncachedInputTokens, cost: s.inputCostUSD),
            TokenBreakdownRow(id: "output", label: "Output", count: s.totalOutputTokens, cost: s.outputCostUSD),
            TokenBreakdownRow(id: "cache_read", label: "Cache Read", count: s.totalCacheReadTokens, cost: s.cacheReadCostUSD),
            TokenBreakdownRow(id: "cache_write", label: "Cache Write", count: s.totalCacheWriteTokens, cost: s.cacheWriteCostUSD)
        ]
        
        // Update efficiency metrics
        efficiencyMetrics = EfficiencyMetrics(
            avgCostUSD: s.avgCostUSD,
            avgTokensPerCall: Int(s.avgInputTokens + s.avgOutputTokens),
            avgLatencyMs: Int(s.avgLatencyMs),
            totalLatencyMs: s.totalLatencyMs,
            totalToolExecutionMs: s.totalToolExecutionMs,
            cacheHitRate: s.cacheHitRate
        )
        
        // Update config rows
        configRows = computeConfigRows(newRecords)
        
        // Update turn rows with real costs
        turnRows = computeTurnRows(sortedTurns)
        
        // Update displayed turns and offset
        updateDisplayedTurns()
    }

    private func computeConfigRows(_ records: [UsageRecord]) -> [ConfigRow] {
        var order: [String] = []
        var byKey: [String: (model: String, roles: Set<AgentRole>, calls: Int, cost: Double, temperature: String, maxTokens: Int, contextSize: Int)] = [:]
        
        for record in records {
            guard let c = record.configuration else { continue }
            let key = configContentKey(c)
            if byKey[key] == nil {
                byKey[key] = (c.model, [], 0, 0, c.temperature.map { String(format: "%.1f", $0) } ?? "—", c.maxTokens, c.contextWindowSize)
                order.append(key)
            }
            byKey[key]?.roles.insert(record.agentRole)
            byKey[key]?.calls += 1
            byKey[key]?.cost += computeTurnCost(record)
        }
        
        return order.compactMap { key in
            guard let entry = byKey[key] else { return nil }
            return ConfigRow(
                key: key,
                model: entry.model,
                roles: entry.roles.sorted { $0.rawValue < $1.rawValue }.map { $0.displayName },
                temperature: entry.temperature,
                maxTokens: formatTokenCount(entry.maxTokens),
                contextSize: formatTokenCount(entry.contextSize),
                calls: entry.calls,
                cost: entry.cost
            )
        }
    }

    private func configContentKey(_ c: ModelConfiguration) -> String {
        let temperature = c.temperature.map { "\($0)" } ?? "default"
        let thinking = "\(c.thinkingBudget.map { "\($0)" } ?? "-")/\(c.effort ?? "-")/\(c.reasoningEffort ?? "-")"
        let overrides = c.extraJSONOverrides.map { dict in
            dict.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        } ?? "-"
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

    private func computeTurnRows(_ turns: [UsageRecord]) -> [TurnRow] {
        return turns.enumerated().map { index, record in
            TurnRow(
                displayNumber: index + 1,
                agentRole: record.agentRole,
                inputTokens: formatTokenCount(record.inputTokens),
                outputTokens: formatTokenCount(record.outputTokens),
                cost: formatTurnCost(computeTurnCost(record)),
                latency: formatLatency(record.latencyMs),
                toolNames: (record.toolCallNames ?? []).joined(separator: ", ")
            )
        }
    }

    private func load() async {
        // Initial load
        updateCachedData(records)
    }

    private func updateDisplayedTurns() {
        displayedTurns = Array(sortedTurns.suffix(turnDisplayLimit))
    }

    private func formatCost(_ cost: Double) -> String {
        if cost > 0 && cost < 0.01 { return String(format: "$%.4f", cost) }
        return String(format: "$%.2f", cost)
    }

    private func formatCostAligned(_ cost: Double) -> String {
        if cost > 0 && cost < 0.01 { return String(format: "$%.4f", cost) }
        return String(format: "$%.2f\u{2007}\u{2007}", cost)
    }

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

    static let initialTurnDisplayLimit = 100
}

// MARK: - Extracted View Structs

/// Header section showing task title, status, and key metrics.
struct HeaderSection: View {
    let resolvedTitle: String
    let resolvedStatus: AgentTask.Status?
    let summary: UsageSummary
    let averageTaskCostUSD: Double
    let taskCountInRange: Int
    let durationText: String?
    @Binding var showingVsAvgInfo: Bool

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

                if let durationText {
                    HeaderStat(label: "Duration", value: durationText, color: .primary)
                }

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
}

/// Cost breakdown section showing cost by agent and token breakdown.
struct TokenBreakdownRow: Equatable, Hashable, Identifiable {
    let id: String
    let label: String
    let count: Int
    let cost: Double
}

struct CostBreakdownSection: View {
    let costByAgent: [(role: AgentRole, calls: Int, cost: Double)]
    let tokenBreakdown: [TokenBreakdownRow]
    let aggregator: UsageAggregator

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // By Agent Role
            CardView(title: "Cost by Agent") {
                ForEach(costByAgent, id: \.role) { item in
                    CostRow(
                        name: item.role.displayName,
                        cost: item.cost,
                        detail: "\(item.calls) calls",
                        color: AppColors.color(for: .agent(item.role))
                    )
                }
                if !costByAgent.contains(where: { $0.role == .smith }) {
                    Text("Smith's costs are not attributed to individual tasks (Smith orchestrates but is not assigned as a task worker).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }

            // By Token Category
            CardView(title: "Token Breakdown") {
                ForEach(tokenBreakdown, id: \.id) { row in
                    TokenRow(label: row.label, count: row.count, cost: row.cost)
                }
                Divider()
                HStack {
                    Text("Cache Hit Rate")
                        .font(.caption)
                    Spacer()
                    Text(String(format: "%.0f%%", tokenBreakdown.isEmpty ? 0 : 0))
                        .font(.caption.monospacedDigit().weight(.semibold))
                }
            }
        }
    }
}

/// Efficiency metrics section.
struct EfficiencySection: View {
    let metrics: TaskCostDetailSheet.EfficiencyMetrics
    let contextResetsCount: Int

    var body: some View {
        CardView(title: "Efficiency") {
            HStack(spacing: 24) {
                MiniStat(label: "Avg Cost / Call", value: formatCost(metrics.avgCostUSD), color: .primary)
                MiniStat(label: "Avg Tokens / Call", value: formatTokenCount(metrics.avgTokensPerCall), color: .primary)
                MiniStat(label: "Avg Latency", value: formatLatency(metrics.avgLatencyMs), color: .primary)
                MiniStat(label: "LLM Time", value: formatLatency(metrics.totalLatencyMs), color: .primary)
                MiniStat(label: "Tool Exec Time", value: formatLatency(metrics.totalToolExecutionMs), color: .primary)

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
    let maxCount: Int

    var body: some View {
        CardView(title: "Tool Usage") {
            if toolCounts.isEmpty {
                Text("No tool call data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
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
    let configRows: [TaskCostDetailSheet.ConfigRow]

    var body: some View {
        if !configRows.isEmpty {
            CardView(title: configRows.count == 1 ? "Configuration" : "Configurations (\(configRows.count))") {
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
                    ForEach(configRows, id: \.key) { row in
                        HStack(spacing: 0) {
                            Text(row.model)
                                .lineLimit(1).truncationMode(.middle)
                                .frame(width: 130, alignment: .leading)
                                .help(row.key)
                            Text(row.roles.joined(separator: ", "))
                                .lineLimit(1).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(row.temperature)
                                .monospacedDigit().frame(width: 56, alignment: .trailing)
                            Text(row.maxTokens)
                                .monospacedDigit().frame(width: 70, alignment: .trailing)
                            Text(row.contextSize)
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
}

/// Turn-by-turn timeline section.
struct TurnTimelineSection: View {
    let turnRows: [TaskCostDetailSheet.TurnRow]
    let sortedTurnsCount: Int
    let displayedTurnStartOffset: Int
    @Binding var turnDisplayLimit: Int

    var body: some View {
        CardView(title: "Turn-by-Turn (\(sortedTurnsCount) calls)") {
            if displayedTurnStartOffset > 0 {
                Text("Showing last \(turnRows.count) of \(sortedTurnsCount) turns")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            TurnDisclosureControls(
                totalTurns: sortedTurnsCount,
                displayedTurns: turnRows.count,
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

            ForEach(turnRows, id: \.displayNumber) { row in
                TaskCostTurnRow(
                    displayNumber: row.displayNumber,
                    agentRole: row.agentRole,
                    inputTokensFormatted: row.inputTokens,
                    outputTokensFormatted: row.outputTokens,
                    costFormatted: row.cost,
                    latencyFormatted: row.latency,
                    toolNames: row.toolNames
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
}

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
