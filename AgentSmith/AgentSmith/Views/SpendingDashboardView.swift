import SwiftUI
import Charts
import AgentSmithKit
import SwiftLLMKit

/// Spending Dashboard — dedicated analytics window showing cost, token usage,
/// and tool statistics across configurable time ranges.
///
/// Built in sections:
///   1. Headline card — big cost number, delta vs prior period, quick stats
///   2. Cost over time chart (stacked by provider)
///   3. Breakdown panels (provider, agent, model, tools)
///   4. Task ledger (sortable table)
///
/// Opened via View → Spending Dashboard (⌘⇧D).
struct SpendingDashboardView: View {
    @Bindable var shared: SharedAppState

    // MARK: - State

    @State private var selectedRange: TimeRange = .week
    @State private var allRecords: [UsageRecord] = []
    /// The date bucket currently hovered in the cost-over-time chart (nil = none).
    @State private var chartHoveredDate: Date?
    /// What the cost-detail sheet is drilling into (nil = no sheet). A specific task, or the
    /// Orchestration bucket (records not attributed to any task).
    @State private var costDetail: CostDetail?
    /// Row currently hovered for visual highlight (task id, or the orchestration sentinel).
    @State private var hoveredRow: String?

    /// Selection for the cost-detail drill-down sheet.
    private enum CostDetail: Identifiable {
        case task(UUID)
        case orchestration
        var id: String {
            switch self {
            case .task(let id): return id.uuidString
            case .orchestration: return "orchestration"
            }
        }
    }
    /// Snapshot of pricing data, captured on load so the aggregator closure doesn't
    /// need to cross actor boundaries.
    @State private var pricingSnapshot: [String: ModelPricing] = [:]
    /// Provider ID → display name lookup, captured on load.
    @State private var providerNames: [String: String] = [:]
    @State private var isLoading = true

    // MARK: - Cached derived state (recomputed on load and range change)

    /// Filtered to the selected time range. Recomputed via `recomputeDerivedState()`.
    @State private var filteredRecords: [UsageRecord] = []
    /// Records from the equivalent prior period (for delta comparison).
    @State private var priorRecords: [UsageRecord] = []
    /// Aggregated summary of `filteredRecords`.
    @State private var currentSummary: UsageSummary = .empty()
    /// Aggregated summary of `priorRecords`.
    @State private var priorSummary: UsageSummary = .empty()

    // MARK: - Time range

    enum TimeRange: String, CaseIterable, Identifiable {
        case today = "Today"
        case week = "Week"
        case month = "Month"
        case all = "All"

        var id: String { rawValue }

        /// Returns the (start, end) date interval for this range, and the equivalent
        /// prior period for delta calculation.
        func dateInterval(calendar: Calendar = .current) -> (current: (start: Date, end: Date), prior: (start: Date, end: Date)) {
            let now = Date()
            let start: Date
            let priorStart: Date
            let priorEnd: Date

            switch self {
            case .today:
                start = calendar.startOfDay(for: now)
                priorStart = calendar.date(byAdding: .day, value: -1, to: start) ?? start
                priorEnd = start
            case .week:
                start = calendar.date(byAdding: .day, value: -7, to: now) ?? now
                priorStart = calendar.date(byAdding: .day, value: -7, to: start) ?? start
                priorEnd = start
            case .month:
                start = calendar.date(byAdding: .month, value: -1, to: now) ?? now
                priorStart = calendar.date(byAdding: .month, value: -1, to: start) ?? start
                priorEnd = start
            case .all:
                start = .distantPast
                priorStart = .distantPast
                priorEnd = .distantPast
            }
            return (current: (start, now), prior: (priorStart, priorEnd))
        }
    }

    // MARK: - Computed

    private var aggregator: UsageAggregator {
        let snapshot = pricingSnapshot
        return UsageAggregator { providerID, modelID in
            guard let providerID, !providerID.isEmpty, !modelID.isEmpty else { return nil }
            return snapshot["\(providerID)/\(modelID)"]
        }
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headlineCard()
                costOverTimeChart()
                breakdownPanels()
                orchestrationLedger()
                taskLedger()
            }
            .padding(20)
        }
        .frame(minWidth: 700, minHeight: 500)
        .background(AppColors.background)
        .task {
            await loadRecords()
        }
        .onChange(of: shared.hasLoadedPersistedState, initial: false) {
            Task { await loadRecords() }
        }
        // Live refresh: `costBoardSnapshot` is the main-thread mirror of the CostBoard actor's
        // snapshot, republished on every usage insert. Its `asOf` ticks whenever a record lands,
        // so reload then — a run that completes while this window is open now shows up without a
        // manual refresh.
        .onChange(of: shared.costBoardSnapshot.asOf) {
            Task { await loadRecords() }
        }
        .refreshable {
            await loadRecords()
        }
        .onChange(of: selectedRange) {
            // Project rule: defer @State mutations out of .onChange.
            DispatchQueue.main.async { recomputeDerivedState() }
        }
        .overlay {
            if isLoading {
                ProgressView("Loading usage data...")
            }
        }
        .sheet(item: $costDetail) { detail in
            let taskCount = aggregator.byTask(filteredRecords).keys.compactMap({ $0 }).count
            switch detail {
            case .task(let taskID):
                // The dashboard doesn't hold live AgentTask objects (those live per-session).
                // Use the global task-summary store to resolve the title/status; the sheet
                // gracefully degrades when neither is present.
                let summaryEntry = shared.storedTaskSummaries.first(where: { $0.id == taskID })
                TaskCostDetailSheet(
                    taskID: taskID,
                    titleOverride: nil,
                    task: nil,
                    taskSummary: summaryEntry,
                    records: filteredRecords.filter { $0.taskID == taskID },
                    allRecordsSummary: currentSummary,
                    taskCountInRange: max(1, taskCount),
                    aggregator: aggregator,
                    providerNames: providerNames
                )
            case .orchestration:
                TaskCostDetailSheet(
                    taskID: nil,
                    titleOverride: "Orchestration",
                    task: nil,
                    taskSummary: nil,
                    records: filteredRecords.filter { $0.taskID == nil },
                    allRecordsSummary: currentSummary,
                    taskCountInRange: max(1, taskCount),
                    aggregator: aggregator,
                    providerNames: providerNames
                )
            }
        }
    }

    private func loadRecords() async {
        isLoading = true
        allRecords = await shared.usageStore.allRecords()
        // Snapshot pricing keyed by "providerID/modelID" so the aggregator closure
        // doesn't need to cross the main-actor boundary at query time.
        var pricing: [String: ModelPricing] = [:]
        for model in shared.llmKit.models {
            // model.id == "providerID/modelID"; skip entries with empty components
            // that would produce nonsensical keys like "providerID/" or "/modelID".
            if let p = model.pricing, !model.id.hasSuffix("/"), !model.id.hasPrefix("/") {
                pricing[model.id] = p
            }
        }
        pricingSnapshot = pricing
        // Snapshot provider display names so we can resolve "builtin.mistral" → "Mistral".
        var names: [String: String] = [:]
        for provider in shared.llmKit.providers {
            names[provider.id] = provider.name
        }
        providerNames = names
        recomputeDerivedState()
        isLoading = false
    }

    /// Recomputes cached derived state from `allRecords`, `selectedRange`, and
    /// `pricingSnapshot`. Called after data loads and when the time range changes.
    /// Avoids redundant O(n) passes — without caching, each computed property
    /// was recalculated on every body evaluation (5-7 accesses per render).
    /// NOTE: If `allRecords` is ever set outside `loadRecords()`, this must be
    /// called afterward (or an `.onChange(of: allRecords)` handler added).
    private func recomputeDerivedState() {
        let interval = selectedRange.dateInterval()
        if selectedRange == .all {
            filteredRecords = allRecords
            priorRecords = []
        } else {
            filteredRecords = allRecords.filter { $0.timestamp >= interval.current.start && $0.timestamp <= interval.current.end }
            priorRecords = allRecords.filter { $0.timestamp >= interval.prior.start && $0.timestamp < interval.prior.end }
        }
        let agg = aggregator
        currentSummary = agg.summarize(filteredRecords, scopeLabel: selectedRange.rawValue)
        priorSummary = agg.summarize(priorRecords, scopeLabel: "Prior \(selectedRange.rawValue)")
    }

    // MARK: - Section 1: Headline Card

    @ViewBuilder

    private func headlineCard() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                // Big cost number
                Text(formatCost(currentSummary.totalCostUSD))
                    .font(AppFonts.dashboardHeadline)
                    .foregroundStyle(.primary)

                // Delta vs prior period
                if selectedRange != .all {
                    deltaLabel()
                }

                Spacer()

                // Time range picker
                Picker("Range", selection: $selectedRange) {
                    ForEach(TimeRange.allCases) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
            }

            // Quick stats row
            HStack(spacing: 24) {
                statPill(
                    label: "Calls",
                    value: "\(currentSummary.callCount.formatted())"
                )
                statPill(
                    label: "Tokens",
                    value: formatTokenCount(currentSummary.totalInputTokens + currentSummary.totalOutputTokens)
                )
                statPill(
                    label: "Avg / Call",
                    value: formatCost(currentSummary.avgCostUSD)
                )
                statPill(
                    label: "Cache Hit",
                    value: String(format: "%.0f%%", currentSummary.cacheHitRate * 100)
                )
                if currentSummary.unpricedCallCount > 0 {
                    statPill(
                        label: "Unpriced",
                        value: "\(currentSummary.unpricedCallCount)",
                        color: .orange
                    )
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(AppColors.secondaryBackground)
        )
    }

    @ViewBuilder

    private func deltaLabel() -> some View {
        let delta = currentSummary.totalCostUSD - priorSummary.totalCostUSD
        let isUp = delta >= 0
        let arrow = isUp ? "arrow.up.right" : "arrow.down.right"
        let color: Color = isUp ? .red : .green

        HStack(spacing: 2) {
            Image(systemName: arrow)
                .font(.caption)
            Text(formatCost(abs(delta)))
                .font(.callout.weight(.medium))
            Text("vs prior")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(priorSummary.callCount > 0 ? color : .secondary)
    }

    private func statPill(label: String, value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .rounded, weight: .semibold))
                .foregroundStyle(color)
        }
    }

    // MARK: - Section 2: Cost Over Time Chart

    /// Chart data item with a stable identity for SwiftUI Charts.
    private struct ChartItem: Identifiable {
        let id: String  // "providerName|date"
        let date: Date
        let provider: String
        let cost: Double
    }

    private func costOverTimeChart() -> some View {
        let bucketUnit: Calendar.Component = {
            switch selectedRange {
            case .today: return .hour
            case .week, .month: return .day
            case .all: return .month
            }
        }()
        let byProvider = aggregator.byProvider(filteredRecords)
        let providerIDs = byProvider.keys.compactMap { $0 }.sorted()

        // Build time-series data: for each provider, get daily/monthly buckets
        var chartItems: [ChartItem] = []
        for providerID in providerIDs {
            let providerRecords = filteredRecords.filter { $0.providerID == providerID }
            let buckets = aggregator.byTimeBucket(providerRecords, unit: bucketUnit)
            let displayName = providerDisplayName(providerID)
            for (date, summary) in buckets {
                chartItems.append(ChartItem(
                    id: "\(displayName)|\(date.timeIntervalSinceReferenceDate)",
                    date: date, provider: displayName, cost: summary.totalCostUSD
                ))
            }
        }
        chartItems.sort { $0.date < $1.date }

        // Group by date for the hover tooltip
        let itemsByDate = Dictionary(grouping: chartItems, by: \.date)

        return VStack(alignment: .leading, spacing: 8) {
            Text("Cost Over Time")
                .font(AppFonts.sectionHeader)

            if chartItems.isEmpty {
                ContentUnavailableView(
                    "No cost data",
                    systemImage: "chart.bar",
                    description: Text("No priced records in the selected range.")
                )
                .frame(height: 200)
            } else {
                Chart {
                    ForEach(chartItems) { item in
                        BarMark(
                            x: .value("Date", item.date, unit: bucketUnit),
                            y: .value("Cost", item.cost)
                        )
                        .foregroundStyle(by: .value("Provider", item.provider))
                    }

                    // Hover indicator: single RuleMark + annotation, rendered once
                    // (outside the ForEach so it doesn't duplicate per provider).
                    if let hoveredDate = chartHoveredDate {
                        RuleMark(x: .value("Hovered", hoveredDate, unit: bucketUnit))
                            .foregroundStyle(.gray.opacity(0.3))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 2]))
                            .annotation(
                                position: .top,
                                spacing: 4,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                            ) {
                                chartTooltip(for: hoveredDate, items: itemsByDate[hoveredDate] ?? [], bucketUnit: bucketUnit)
                            }
                    }
                }
                .chartYAxis {
                    AxisMarks(format: .currency(code: "USD"))
                }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    guard let plotFrame = proxy.plotFrame else { return }
                                    let origin = geo[plotFrame].origin
                                    let x = location.x - origin.x
                                    if let date: Date = proxy.value(atX: x) {
                                        let cal = Calendar.current
                                        let snapped = cal.dateInterval(of: bucketUnit, for: date)?.start ?? date
                                        chartHoveredDate = snapped
                                    }
                                case .ended:
                                    chartHoveredDate = nil
                                }
                            }
                    }
                }
                .frame(height: 220)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(AppColors.secondaryBackground)
        )
    }

    /// Tooltip shown when hovering over a bar in the cost-over-time chart.
    private func chartTooltip(for date: Date, items: [ChartItem], bucketUnit: Calendar.Component) -> some View {
        let formatter = DateFormatter()
        switch bucketUnit {
        case .month: formatter.dateFormat = "MMM yyyy"
        case .hour: formatter.dateFormat = "h a, MMM d"
        default: formatter.dateFormat = "MMM d, yyyy"
        }
        let total = items.reduce(0.0) { $0 + $1.cost }

        return VStack(alignment: .leading, spacing: 4) {
            Text(formatter.string(from: date))
                .font(.caption.weight(.semibold))
            ForEach(items.sorted(by: { $0.cost > $1.cost })) { item in
                SpendingChartTooltipRow(provider: item.provider, costFormatted: formatCost(item.cost))
            }
            if items.count > 1 {
                Divider()
                HStack {
                    Text("Total")
                        .font(.caption2.weight(.semibold))
                    Spacer(minLength: 8)
                    Text(formatCost(total))
                        .font(.caption2.monospacedDigit().weight(.semibold))
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.ultraThickMaterial)
                .shadow(radius: 4)
        )
    }

    // MARK: - Section 3: Breakdown Panels

    private func breakdownPanels() -> some View {
        let summary = currentSummary

        // Static 2x2 grid via two HStacks. The card set is fixed at four; a non-lazy layout
        // sidesteps the lazy-grid project-rule violation while preserving visual structure.
        return VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
            breakdownCard(title: "By Provider") {
                let byProvider = aggregator.byProvider(filteredRecords)
                    .compactMap { k, v -> (String, String, UsageSummary)? in
                        guard let k else { return nil }
                        return (k, providerDisplayName(k), v)
                    }
                    .sorted { $0.2.totalCostUSD > $1.2.totalCostUSD }

                ForEach(byProvider, id: \.0) { _, displayName, provSummary in
                    providerBar(
                        name: displayName,
                        cost: provSummary.totalCostUSD,
                        fraction: summary.totalCostUSD > 0 ? provSummary.totalCostUSD / summary.totalCostUSD : 0
                    )
                }
            }

            // By Agent
            breakdownCard(title: "By Agent") {
                let byAgent = aggregator.byAgent(filteredRecords)
                    .sorted { $0.value.totalCostUSD > $1.value.totalCostUSD }

                ForEach(byAgent, id: \.key) { role, agentSummary in
                    providerBar(
                        name: role.displayName,
                        cost: agentSummary.totalCostUSD,
                        fraction: summary.totalCostUSD > 0 ? agentSummary.totalCostUSD / summary.totalCostUSD : 0,
                        color: AppColors.color(for: .agent(role))
                    )
                }
            }
            }

            HStack(alignment: .top, spacing: 16) {
            breakdownCard(title: "By Model") {
                let byModel = aggregator.byModel(filteredRecords)
                    .sorted { $0.value.totalCostUSD > $1.value.totalCostUSD }
                    .prefix(8)

                ForEach(Array(byModel), id: \.key) { model, modelSummary in
                    SpendingByModelRow(
                        modelName: model,
                        costFormatted: formatCost(modelSummary.totalCostUSD),
                        callCount: modelSummary.callCount
                    )
                }
            }

            // Tool distribution
            breakdownCard(title: "Tool Calls") {
                let toolCounts = toolFrequencyFromRecords(filteredRecords)
                    .sorted { $0.value > $1.value }
                    .prefix(8)

                if toolCounts.isEmpty {
                    Text("No tool call data")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(toolCounts), id: \.key) { tool, count in
                        SpendingToolCountRow(toolName: tool, count: count)
                    }
                }
            }
            }
        }
    }

    private func breakdownCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(AppFonts.sectionHeader)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(AppColors.secondaryBackground)
        )
    }

    private func providerBar(name: String, cost: Double, fraction: Double, color: Color = .accentColor) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Text(name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(formatCost(cost))
                    .font(.caption.monospacedDigit())
                    .frame(width: 70, alignment: .trailing)
                Text(String(format: "%3.0f%%", fraction * 100))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
            // Bar constrained to the name area — stops before the cost/% columns
            // (106 = 70 cost + 36 percentage widths from the HStack above)
            HStack(spacing: 0) {
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(0.7))
                        .frame(width: max(2, geo.size.width * fraction))
                }
                .frame(height: 6)
                Spacer()
                    .frame(width: 106)
            }
        }
    }

    // MARK: - Section 4: Task Ledger

    private func taskLedger() -> some View {
        // Live AgentTask objects are per-session and not threaded into the dashboard.
        // Resolve titles from the global task-summary store; in-progress tasks without
        // a summary yet still fall back to a truncated UUID.
        let taskLookup: [UUID: TaskSummaryEntry] = Dictionary(
            uniqueKeysWithValues: shared.storedTaskSummaries.map { ($0.id, $0) }
        )
        let grouped = aggregator.byTask(filteredRecords)
        let byTask = grouped
            .compactMap { k, v -> (UUID, String, UsageSummary)? in
                guard let k else { return nil }
                let title = taskLookup[k]?.title ?? "Task \(k.uuidString.prefix(8))"
                return (k, title, v)
            }
            .sorted { $0.2.totalCostUSD > $1.2.totalCostUSD }

        return VStack(alignment: .leading, spacing: 8) {
            Text("Tasks")
                .font(AppFonts.sectionHeader)

            if byTask.isEmpty {
                Text("No task data in selected range")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ledgerHeader()

                Divider()

                ForEach(byTask.prefix(50), id: \.0) { taskID, title, taskSummary in
                    Button(action: { costDetail = .task(taskID) }, label: {
                        taskRow(title: title, summary: taskSummary)
                            .contentShape(Rectangle())
                    })
                    .buttonStyle(.plain)
                    .background(hoveredRow == taskID.uuidString ? Color.accentColor.opacity(0.08) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .onHover { hovering in hoveredRow = hovering ? taskID.uuidString : nil }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(AppColors.secondaryBackground)
        )
    }

    /// Smith's cost that isn't attributable to any single task — turns spent orchestrating
    /// with no task-targeting tool call (idling, planning, replying, deciding what to run).
    /// Rendered as its own card ABOVE Tasks, clickable for a drill-down. Empty → nothing shown.
    @ViewBuilder
    private func orchestrationLedger() -> some View {
        let planningSummary = aggregator.byTask(filteredRecords)[nil]
        if let planningSummary, planningSummary.callCount > 0 {
            VStack(alignment: .leading, spacing: 8) {
                Text("Orchestration")
                    .font(AppFonts.sectionHeader)
                Text("Smith's turns not tied to a specific task — planning, replying, deciding what to run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ledgerHeader()
                Divider()

                Button(action: { costDetail = .orchestration }, label: {
                    taskRow(title: "Orchestration", summary: planningSummary)
                        .contentShape(Rectangle())
                })
                .buttonStyle(.plain)
                .background(hoveredRow == "orchestration" ? Color.accentColor.opacity(0.08) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .onHover { hovering in hoveredRow = hovering ? "orchestration" : nil }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(AppColors.secondaryBackground))
        }
    }

    /// Shared column header for the task/orchestration ledgers.
    private func ledgerHeader() -> some View {
        HStack(spacing: 0) {
            Text("Task").frame(maxWidth: .infinity, alignment: .leading)
            Text("Started").frame(width: 96, alignment: .trailing)
            Text("Cost").frame(width: 80, alignment: .trailing)
            Text("Calls").frame(width: 60, alignment: .trailing)
            Text("Tokens").frame(width: 80, alignment: .trailing)
            Text("Latency").frame(width: 80, alignment: .trailing)
            Text("Tools").frame(width: 60, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
    }

    private func taskRow(title: String, summary: UsageSummary) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.caption)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(formatStarted(summary.firstTimestamp))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .trailing)
            Text(formatCost(summary.totalCostUSD))
                .font(.caption.monospacedDigit())
                .frame(width: 80, alignment: .trailing)
            Text("\(summary.callCount)")
                .font(.caption.monospacedDigit())
                .frame(width: 60, alignment: .trailing)
            Text(formatTokenCount(summary.totalInputTokens + summary.totalOutputTokens))
                .font(.caption.monospacedDigit())
                .frame(width: 80, alignment: .trailing)
            Text(formatLatency(summary.totalLatencyMs))
                .font(.caption.monospacedDigit())
                .frame(width: 80, alignment: .trailing)
            Text("\(summary.totalToolCalls)")
                .font(.caption.monospacedDigit())
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }

    // MARK: - Helpers

    /// Resolves a provider ID to its display name, falling back to the raw ID.
    private func providerDisplayName(_ id: String) -> String {
        providerNames[id] ?? id
    }

    /// Counts tool invocations across all records by flattening toolCallNames.
    private func toolFrequencyFromRecords(_ records: [UsageRecord]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for record in records {
            guard let names = record.toolCallNames else { continue }
            for name in names {
                counts[name, default: 0] += 1
            }
        }
        return counts
    }

    private func formatCost(_ cost: Double) -> String {
        if cost > 0 && cost < 0.01 { return String(format: "$%.4f", cost) }
        return String(format: "$%.2f", cost)
    }

    /// The run's start (earliest record). Time-only for today, else short date — enough to
    /// tell same-name template runs apart without widening the column much.
    private func formatStarted(_ date: Date?) -> String {
        guard let date else { return "—" }
        if Calendar.current.isDateInToday(date) {
            return date.formatted(.dateTime.hour().minute())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.0fK", Double(count) / 1_000)
        } else {
            return "\(count)"
        }
    }

    private func formatLatency(_ ms: Int) -> String {
        if ms >= 60_000 {
            return String(format: "%.1fm", Double(ms) / 60_000)
        } else if ms >= 1_000 {
            return String(format: "%.1fs", Double(ms) / 1_000)
        } else {
            return "\(ms)ms"
        }
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let totalSeconds = Int(interval)
        if totalSeconds >= 3600 {
            return "\(totalSeconds / 3600)h \((totalSeconds % 3600) / 60)m"
        } else if totalSeconds >= 60 {
            return "\(totalSeconds / 60)m \(totalSeconds % 60)s"
        } else {
            return "\(totalSeconds)s"
        }
    }
}

// MARK: - UUID + Identifiable (for .sheet(item:))

extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}

