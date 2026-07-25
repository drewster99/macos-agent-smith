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
    @Environment(\.openWindow) private var openWindow

    // MARK: - State

    @State private var selectedRange: TimeRange = .week
    @State private var allRecords: [UsageRecord] = []
    /// What the cost-detail sheet is drilling into (nil = no sheet). A specific task, or the
    /// Orchestration bucket (records not attributed to any task).
    @State private var costDetail: CostDetail?

    /// Selection for the cost-detail drill-down sheet.
    /// Only the Orchestration bucket uses the modal sheet now — it's range-scoped and
    /// dashboard-specific. A specific task opens the standalone, resizable Task Cost WINDOW instead.
    private enum CostDetail: Identifiable {
        case orchestration
        var id: String { "orchestration" }
    }

    // MARK: Task ledger (pre-computed rows)

    /// One task's row in the Tasks ledger, computed ONCE per data/range change into `ledgerRows`
    /// (not in the view body) so scrolling a large list doesn't re-aggregate per frame. Carries
    /// every displayed and derived value, including the right-hand calculated columns.
    struct TaskLedgerRow: Identifiable {
        let id: String
        let taskID: UUID
        let title: String
        let summary: UsageSummary

        var started: Date? { summary.firstTimestamp }
        var cost: Double { summary.totalCostUSD }
        var calls: Int { summary.callCount }
        var tokens: Int { summary.totalInputTokens + summary.totalOutputTokens }
        var latencyMs: Int { summary.totalLatencyMs }
        var tools: Int { summary.totalToolCalls }
        var costPerCall: Double { calls > 0 ? cost / Double(calls) : 0 }
        var costPerMTok: Double { tokens > 0 ? cost * 1_000_000 / Double(tokens) : 0 }
        var msPerKTok: Double { tokens > 0 ? Double(latencyMs) * 1_000 / Double(tokens) : 0 }
        var costPerTool: Double { tools > 0 ? cost / Double(tools) : 0 }
    }

    /// Columns in the Tasks ledger, in display order. `title` is the flexible leading column;
    /// the rest are fixed-width and right-aligned.
    enum LedgerColumn: String, CaseIterable {
        case title, started, cost, calls, tokens, latency, tools
        case costPerCall, costPerMTok, msPerKTok, costPerTool

        var header: String {
            switch self {
            case .title: return "Task"
            case .started: return "Started"
            case .cost: return "Cost"
            case .calls: return "Calls"
            case .tokens: return "Tokens"
            case .latency: return "Latency"
            case .tools: return "Tools"
            case .costPerCall: return "$/call"
            case .costPerMTok: return "$/Mtok"
            case .msPerKTok: return "ms/Ktok"
            case .costPerTool: return "$/tool"
            }
        }
        var width: CGFloat? {
            switch self {
            case .title: return nil          // flexible
            case .started: return 100
            case .cost: return 66
            case .calls: return 52
            case .tokens: return 66
            case .latency: return 62
            case .tools: return 46
            case .costPerCall, .costPerMTok, .msPerKTok, .costPerTool: return 66
            }
        }
        /// Default sort direction when this column is first selected (descending for magnitudes).
        var defaultAscending: Bool { self == .title }
    }

    @State private var ledgerRows: [TaskLedgerRow] = []
    /// `ledgerRows` after search filter + current sort, precomputed into state so the ledger body
    /// never sorts 245 rows during a view update (e.g. a hover or chart move). Refreshed by
    /// `recomputeDisplayRows()` whenever rows, search text, or sort change.
    @State private var displayRows: [TaskLedgerRow] = []
    @State private var orchestrationSummary: UsageSummary?
    @State private var ledgerSearch: String = ""
    @State private var sortColumn: LedgerColumn = .cost
    @State private var sortAscending: Bool = false
    /// Throttle guard for the live-refresh: true while a coalesced reload is pending.
    @State private var liveReloadScheduled: Bool = false
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

    /// Cost-over-time bars (stacked by provider), precomputed so chart hover doesn't re-aggregate.
    @State private var chartSeries: [ChartItem] = []
    /// `chartSeries` grouped by bucket date, for the hover tooltip's O(1) lookup.
    @State private var chartItemsByDate: [Date: [ChartItem]] = [:]
    /// The calendar bucket the current range charts by (hour/day/month).
    @State private var chartBucketUnit: Calendar.Component = .day

    /// Breakdown-card datasets, one per card, precomputed so a chart hover or filter keystroke
    /// doesn't re-aggregate `filteredRecords` four times.
    @State private var providerBreakdown: [BreakdownBar] = []
    @State private var agentBreakdown: [BreakdownBar] = []
    @State private var modelBreakdown: [ModelBreakdownRow] = []
    @State private var toolBreakdown: [ToolBreakdownRow] = []

    /// One bar in the By-Provider / By-Agent cards: display name, cost, share of total, and tint.
    private struct BreakdownBar: Identifiable {
        let id: String
        let name: String
        let cost: Double
        let fraction: Double
        let color: Color
    }
    /// One row in the By-Model card.
    private struct ModelBreakdownRow: Identifiable {
        let id: String
        let model: String
        let cost: Double
        let calls: Int
    }
    /// One row in the Tool Calls card.
    private struct ToolBreakdownRow: Identifiable {
        let id: String
        let tool: String
        let count: Int
    }

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
                CostOverTimeChart(
                    series: chartSeries,
                    itemsByDate: chartItemsByDate,
                    bucketUnit: chartBucketUnit,
                    formatCost: formatCost
                )
                breakdownPanels()
                orchestrationLedger()
                taskLedger()
            }
            .padding(20)
        }
        .frame(minWidth: 1000, minHeight: 500)
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
            // `asOf` ticks on EVERY usage insert (once per LLM turn across all agents), so a
            // naive reload-per-tick would re-read + re-aggregate the whole store many times a
            // second during active runs. Coalesce to at most one SILENT reload per 1.5s: the
            // first tick schedules a trailing reload; ticks inside that window are dropped.
            DispatchQueue.main.async {
                guard !liveReloadScheduled else { return }
                liveReloadScheduled = true
                // @MainActor so the flag reset and the @State writes in loadRecords stay on the
                // main actor (a bare Task would be non-isolated → off-main @State mutation).
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.5))
                    liveReloadScheduled = false
                    await loadRecords(silent: true)
                }
            }
        }
        .refreshable {
            await loadRecords()
        }
        .onChange(of: selectedRange) {
            // Project rule: defer @State mutations out of .onChange.
            DispatchQueue.main.async { recomputeDerivedState() }
        }
        .onChange(of: ledgerSearch) {
            DispatchQueue.main.async { recomputeDisplayRows() }
        }
        // Title sources (summaries + archived + deleted tasks) load asynchronously after launch.
        // When any grows, re-resolve the ledger's titles so late names fill in without the user
        // having to switch ranges. Keyed on the combined count — these stores only grow here.
        .onChange(of: shared.storedTaskSummaries.count + shared.archivedTasks.count + shared.deletedTasks.count) {
            DispatchQueue.main.async { remapLedgerTitles() }
        }
        .overlay {
            if isLoading {
                ProgressView("Loading usage data...")
            }
        }
        .sheet(item: $costDetail) { _ in
            // Orchestration is not a task, so "vs Average" (a per-task comparison) is hidden (0).
            TaskCostDetailSheet(
                taskID: nil,
                titleOverride: "Orchestration",
                task: nil,
                taskSummary: nil,
                records: filteredRecords.filter { $0.taskID == nil },
                taskCountInRange: max(1, ledgerRows.count),
                averageTaskCostUSD: 0,
                aggregator: aggregator
            )
        }
    }

    /// Loads all usage records and recomputes derived state. `silent` skips the loading overlay,
    /// used by the throttled live-refresh so it doesn't flash a spinner on every insert burst.
    private func loadRecords(silent: Bool = false) async {
        if !silent { isLoading = true }
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

        // Pre-compute the ledger rows ONCE here (the expensive per-task aggregation) so the
        // Tasks section only sorts/filters a small array in its body — no re-aggregation while
        // scrolling. `nil` is the Orchestration bucket, kept separate.
        let grouped = agg.byTask(filteredRecords)
        orchestrationSummary = grouped[nil].flatMap { $0.callCount > 0 ? $0 : nil }
        let taskLookup = taskTitleLookup()
        ledgerRows = grouped.compactMap { key, value in
            guard let key else { return nil }
            return TaskLedgerRow(id: key.uuidString, taskID: key, title: ledgerTitle(for: key, using: taskLookup), summary: value)
        }
        recomputeDisplayRows()
        recomputeChartSeries(agg)
        recomputeBreakdowns(agg)
    }

    /// Builds the four breakdown-card datasets once per data/range change (one pass each over
    /// `filteredRecords`), so the cards render from ready arrays. Shares run before the ledger so
    /// `currentSummary` (the denominator) is already set.
    private func recomputeBreakdowns(_ agg: UsageAggregator) {
        let total = currentSummary.totalCostUSD
        func share(_ cost: Double) -> Double { total > 0 ? cost / total : 0 }

        providerBreakdown = agg.byProvider(filteredRecords)
            .compactMap { key, value -> BreakdownBar? in
                guard let key else { return nil }
                return BreakdownBar(id: key, name: providerDisplayName(key), cost: value.totalCostUSD,
                                    fraction: share(value.totalCostUSD), color: .accentColor)
            }
            .sorted { $0.cost > $1.cost }

        agentBreakdown = agg.byAgent(filteredRecords)
            .map { role, value in
                BreakdownBar(id: role.rawValue, name: role.displayName, cost: value.totalCostUSD,
                             fraction: share(value.totalCostUSD), color: AppColors.color(for: .agent(role)))
            }
            .sorted { $0.cost > $1.cost }

        modelBreakdown = Array(
            agg.byModel(filteredRecords)
                .map { ModelBreakdownRow(id: $0.key, model: $0.key, cost: $0.value.totalCostUSD, calls: $0.value.callCount) }
                .sorted { $0.cost > $1.cost }
                .prefix(8)
        )

        toolBreakdown = Array(
            toolFrequencyFromRecords(filteredRecords)
                .map { ToolBreakdownRow(id: $0.key, tool: $0.key, count: $0.value) }
                .sorted { $0.count > $1.count }
                .prefix(8)
        )
    }

    /// Task titles keyed by task id, merged from every global source that carries one. A title needs
    /// no summary — every task already has one — so we don't depend on the (slow, async) summary
    /// store: the inactive-task store holds the real title for archived, interrupted, failed, and
    /// recently-deleted tasks and loads from `inactive_tasks.json` independently of the semantic
    /// engine. Summaries are folded in first; the task's own title then wins where both exist.
    private func taskTitleLookup() -> [UUID: String] {
        var lookup: [UUID: String] = [:]
        for summary in shared.storedTaskSummaries { lookup[summary.id] = summary.title }
        for task in shared.archivedTasks { lookup[task.id] = task.title }
        for task in shared.deletedTasks { lookup[task.id] = task.title }
        return lookup
    }

    /// A task's display title, or a stable hex fallback for the rare task whose title is in none of
    /// the global stores (e.g. its records outlived the task object entirely).
    private func ledgerTitle(for taskID: UUID, using lookup: [UUID: String]) -> String {
        lookup[taskID] ?? "Task \(taskID.uuidString.prefix(8))"
    }

    /// Re-resolves ledger titles against the current summary store WITHOUT re-aggregating, then
    /// refreshes the display rows. Called when `storedTaskSummaries` grows after the initial load so
    /// late-arriving names fill in on their own, instead of only when the user switches ranges.
    private func remapLedgerTitles() {
        guard !ledgerRows.isEmpty else { return }
        let lookup = taskTitleLookup()
        var changed = false
        let updated = ledgerRows.map { row -> TaskLedgerRow in
            let title = ledgerTitle(for: row.taskID, using: lookup)
            guard title != row.title else { return row }
            changed = true
            return TaskLedgerRow(id: row.id, taskID: row.taskID, title: title, summary: row.summary)
        }
        guard changed else { return }
        ledgerRows = updated
        recomputeDisplayRows()
    }

    /// Recomputes the sorted + filtered display rows into `@State`. Cheap (one sort of the pre-built
    /// array), but kept out of the view body so a hover or unrelated update never triggers it.
    private func recomputeDisplayRows() {
        displayRows = sortedFilteredRows
    }

    /// The ledger rows after applying the search filter and the current sort. Cheap — sorts a
    /// pre-built array, no aggregation. `title` sorts case-insensitively; every other column by
    /// its numeric value, with title as a stable tie-breaker.
    private var sortedFilteredRows: [TaskLedgerRow] {
        let needle = ledgerSearch.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = needle.isEmpty ? ledgerRows : ledgerRows.filter { $0.title.lowercased().contains(needle) }
        let asc = sortAscending
        func lift(_ a: Bool) -> Bool { asc ? a : !a }
        return filtered.sorted { l, r in
            if sortColumn == .title {
                let c = l.title.localizedCaseInsensitiveCompare(r.title)
                if c != .orderedSame { return asc ? c == .orderedAscending : c == .orderedDescending }
                return l.id < r.id
            }
            let lv = numericValue(l, sortColumn), rv = numericValue(r, sortColumn)
            if lv != rv { return lift(lv < rv) }
            return l.title.localizedCaseInsensitiveCompare(r.title) == .orderedAscending
        }
    }

    private func numericValue(_ row: TaskLedgerRow, _ column: LedgerColumn) -> Double {
        switch column {
        case .title: return 0
        case .started: return row.started?.timeIntervalSince1970 ?? 0
        case .cost: return row.cost
        case .calls: return Double(row.calls)
        case .tokens: return Double(row.tokens)
        case .latency: return Double(row.latencyMs)
        case .tools: return Double(row.tools)
        case .costPerCall: return row.costPerCall
        case .costPerMTok: return row.costPerMTok
        case .msPerKTok: return row.msPerKTok
        case .costPerTool: return row.costPerTool
        }
    }

    /// Click a column header to sort by it; click the active column again to reverse.
    private func toggleSort(_ column: LedgerColumn) {
        if sortColumn == column {
            sortAscending.toggle()
        } else {
            sortColumn = column
            sortAscending = column.defaultAscending
        }
        recomputeDisplayRows()
    }

    /// Fixed-width trailing cell for a ledger column, or a flexible leading cell for the title.
    private struct LedgerCellFrame: ViewModifier {
        let width: CGFloat?
        let leading: Bool
        func body(content: Content) -> some View {
            if let width {
                content.frame(width: width, alignment: .trailing)
            } else {
                content.frame(maxWidth: .infinity, alignment: leading ? .leading : .trailing)
            }
        }
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

    /// Builds the cost-over-time bars once per data/range change (multiple O(n) passes over
    /// `filteredRecords`), so chart hover and unrelated body updates don't re-aggregate them.
    private func recomputeChartSeries(_ agg: UsageAggregator) {
        let bucketUnit: Calendar.Component
        switch selectedRange {
        case .today: bucketUnit = .hour
        case .week, .month: bucketUnit = .day
        case .all: bucketUnit = .month
        }
        chartBucketUnit = bucketUnit

        let providerIDs = agg.byProvider(filteredRecords).keys.compactMap { $0 }.sorted()
        var items: [ChartItem] = []
        for providerID in providerIDs {
            let providerRecords = filteredRecords.filter { $0.providerID == providerID }
            let buckets = agg.byTimeBucket(providerRecords, unit: bucketUnit)
            let displayName = providerDisplayName(providerID)
            for (date, summary) in buckets {
                items.append(ChartItem(
                    id: "\(displayName)|\(date.timeIntervalSinceReferenceDate)",
                    date: date, provider: displayName, cost: summary.totalCostUSD
                ))
            }
        }
        items.sort { $0.date < $1.date }
        chartSeries = items
        chartItemsByDate = Dictionary(grouping: items, by: \.date)
    }

    /// The cost-over-time chart, extracted so its hover state is LOCAL. The pointer crosses this
    /// chart continuously while the dashboard scrolls; keeping `hoveredDate` here means that only
    /// this view re-renders on hover, not the whole dashboard body (which would rebuild the Chart and
    /// replay Swift Charts' entrance animation — the "redrawing one bar at a time" jump). Two more
    /// guards keep it stable: the hover write is gated to actual bucket changes (not every pixel),
    /// and implicit Chart animation is disabled so a re-render snaps to state instead of animating.
    private struct CostOverTimeChart: View {
        let series: [ChartItem]
        let itemsByDate: [Date: [ChartItem]]
        let bucketUnit: Calendar.Component
        let formatCost: (Double) -> String

        @State private var hoveredDate: Date?

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("Cost Over Time")
                    .font(AppFonts.sectionHeader)

                if series.isEmpty {
                    ContentUnavailableView(
                        "No cost data",
                        systemImage: "chart.bar",
                        description: Text("No priced records in the selected range.")
                    )
                    .frame(height: 200)
                } else {
                    Chart {
                        ForEach(series) { item in
                            BarMark(
                                x: .value("Date", item.date, unit: bucketUnit),
                                y: .value("Cost", item.cost)
                            )
                            .foregroundStyle(by: .value("Provider", item.provider))
                        }

                        // Hover indicator: single RuleMark + annotation, rendered once
                        // (outside the ForEach so it doesn't duplicate per provider).
                        if let hoveredDate {
                            RuleMark(x: .value("Hovered", hoveredDate, unit: bucketUnit))
                                .foregroundStyle(.gray.opacity(0.3))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 2]))
                                .annotation(
                                    position: .top,
                                    spacing: 4,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                                ) {
                                    tooltip(for: hoveredDate)
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
                                            let snapped = Calendar.current.dateInterval(of: bucketUnit, for: date)?.start ?? date
                                            // Only write when the bucket actually changes — onContinuousHover
                                            // fires per pixel, but the highlighted bar changes per bucket.
                                            if snapped != hoveredDate { hoveredDate = snapped }
                                        }
                                    case .ended:
                                        if hoveredDate != nil { hoveredDate = nil }
                                    }
                                }
                        }
                    }
                    .frame(height: 220)
                    // Snap to state on any re-render instead of replaying the bars' entrance animation.
                    .transaction { $0.animation = nil }
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(AppColors.secondaryBackground)
            )
        }

        /// Tooltip shown when hovering over a bar in the cost-over-time chart.
        private func tooltip(for date: Date) -> some View {
            let items = itemsByDate[date] ?? []
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
    }

    // MARK: - Section 3: Breakdown Panels

    private func breakdownPanels() -> some View {
        // Static 2x2 grid via two HStacks. The card set is fixed at four; a non-lazy layout
        // sidesteps the lazy-grid project-rule violation while preserving visual structure. Each
        // card reads its precomputed dataset — the aggregation happens in `recomputeBreakdowns`.
        return VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
            breakdownCard(title: "By Provider") {
                ForEach(providerBreakdown) { bar in
                    providerBar(name: bar.name, cost: bar.cost, fraction: bar.fraction, color: bar.color)
                }
            }

            breakdownCard(title: "By Agent") {
                ForEach(agentBreakdown) { bar in
                    providerBar(name: bar.name, cost: bar.cost, fraction: bar.fraction, color: bar.color)
                }
            }
            }

            HStack(alignment: .top, spacing: 16) {
            breakdownCard(title: "By Model") {
                ForEach(modelBreakdown) { row in
                    SpendingByModelRow(
                        modelName: row.model,
                        costFormatted: formatCost(row.cost),
                        callCount: row.calls
                    )
                }
            }

            breakdownCard(title: "Tool Calls") {
                if toolBreakdown.isEmpty {
                    Text("No tool call data")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(toolBreakdown) { row in
                        SpendingToolCountRow(toolName: row.tool, count: row.count)
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

    /// A tappable ledger row with LOCAL hover-highlight state. Hovering happens constantly while
    /// scrolling a 245-row table; keeping the hover flag here means only the hovered row re-renders,
    /// not the whole dashboard body (which would otherwise re-sort and rebuild every row per pointer
    /// move — the cause of the choppy scroll).
    private struct LedgerRowButton<Content: View>: View {
        let onTap: () -> Void
        @ViewBuilder let content: () -> Content
        @State private var isHovered = false

        var body: some View {
            Button(action: onTap, label: { content().contentShape(Rectangle()) })
                .buttonStyle(.plain)
                .background(isHovered ? Color.accentColor.opacity(0.08) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .onHover { isHovered = $0 }
        }
    }

    private func taskLedger() -> some View {
        let rows = displayRows
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tasks").font(AppFonts.sectionHeader)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                    TextField("Filter tasks", text: $ledgerSearch)
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .frame(width: 180)
                    if !ledgerSearch.isEmpty {
                        Button(action: { ledgerSearch = "" }, label: { Image(systemName: "xmark.circle.fill") })
                            .buttonStyle(.plain).font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(AppColors.background))
            }

            if ledgerRows.isEmpty {
                Text("No task data in selected range").font(.caption).foregroundStyle(.secondary)
            } else {
                ledgerHeader()
                Divider()
                if rows.isEmpty {
                    Text("No tasks match \u{201C}\(ledgerSearch)\u{201D}").font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
                } else {
                    ForEach(rows) { row in
                        LedgerRowButton(onTap: { AgentSmithApp.showOrOpenTaskCostDetail(taskID: row.taskID, openWindow: openWindow) }, content: {
                            ledgerRow(title: row.title, summary: row.summary)
                        })
                    }
                    Text("\(rows.count) task\(rows.count == 1 ? "" : "s")")
                        .font(.caption2).foregroundStyle(.tertiary).padding(.top, 4)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(AppColors.secondaryBackground))
    }

    /// Cost not attributed to any single task: mostly Smith's orchestration turns (planning,
    /// replying, deciding what to run), plus non-task-specific helper calls (e.g. the summarizer's
    /// memory reconciliation and web-content extraction). Its own card ABOVE Tasks, clickable for a
    /// drill-down. Empty → nothing shown.
    @ViewBuilder
    private func orchestrationLedger() -> some View {
        if let planningSummary = orchestrationSummary {
            VStack(alignment: .leading, spacing: 8) {
                Text("Orchestration").font(AppFonts.sectionHeader)
                Text("Cost not tied to a specific task — Smith's orchestration turns (planning, replying, deciding what to run) plus non-task helper calls.")
                    .font(.caption).foregroundStyle(.secondary)

                ledgerHeader(sortable: false)
                Divider()

                LedgerRowButton(onTap: { costDetail = .orchestration }, content: {
                    ledgerRow(title: "Orchestration", summary: planningSummary)
                })
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(AppColors.secondaryBackground))
        }
    }

    /// Column header. When `sortable`, each column is a button: click to sort by it, click the
    /// active one again to reverse (active column bold + direction arrow). The Orchestration
    /// section passes `sortable: false` — it's a single row, so a sort control there would
    /// confusingly reorder the Tasks table below it instead.
    private func ledgerHeader(sortable: Bool = true) -> some View {
        HStack(spacing: 0) {
            ForEach(LedgerColumn.allCases, id: \.self) { col in
                let isActive = sortable && sortColumn == col
                let label = HStack(spacing: 2) {
                    if col != .title { Spacer(minLength: 0) }
                    Text(col.header).lineLimit(1)
                    if isActive {
                        Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                            .font(.caption2).imageScale(.small)
                    }
                    if col == .title { Spacer(minLength: 0) }
                }
                .contentShape(Rectangle())
                .font(.caption.weight(isActive ? .bold : .semibold))
                .foregroundStyle(isActive ? Color.primary : Color.secondary)

                Group {
                    if sortable {
                        Button(action: { toggleSort(col) }, label: { label }).buttonStyle(.plain)
                    } else {
                        label
                    }
                }
                .modifier(LedgerCellFrame(width: col.width, leading: col == .title))
            }
        }
        .padding(.horizontal, 8)
    }

    private func ledgerRow(title: String, summary: UsageSummary) -> some View {
        let tokens = summary.totalInputTokens + summary.totalOutputTokens
        let calls = summary.callCount
        let tools = summary.totalToolCalls
        let cost = summary.totalCostUSD
        let costPerCall = calls > 0 ? cost / Double(calls) : 0
        let costPerMTok = tokens > 0 ? cost * 1_000_000 / Double(tokens) : 0
        let msPerKTok = tokens > 0 ? Double(summary.totalLatencyMs) * 1_000 / Double(tokens) : 0
        let costPerTool = tools > 0 ? cost / Double(tools) : 0
        return HStack(spacing: 0) {
            cell(.title) { Text(title).lineLimit(1) }
            cell(.started) { Text(formatStarted(summary.firstTimestamp)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) }
            cell(.cost) { Text(formatCost(cost)).monospacedDigit() }
            cell(.calls) { Text("\(calls)").monospacedDigit() }
            cell(.tokens) { Text(formatTokenCount(tokens)).monospacedDigit() }
            cell(.latency) { Text(formatLatency(summary.totalLatencyMs)).monospacedDigit() }
            cell(.tools) { Text("\(tools)").monospacedDigit() }
            cell(.costPerCall) { derivedText(formatCost(costPerCall)) }
            cell(.costPerMTok) { derivedText(formatCost(costPerMTok)) }
            cell(.msPerKTok) { derivedText(tokens > 0 ? String(format: "%.1f", msPerKTok) : "—") }
            cell(.costPerTool) { derivedText(tools > 0 ? formatCost(costPerTool) : "—") }
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func cell<Content: View>(_ column: LedgerColumn, @ViewBuilder _ content: () -> Content) -> some View {
        content().modifier(LedgerCellFrame(width: column.width, leading: column == .title))
    }

    private func derivedText(_ s: String) -> some View {
        Text(s).monospacedDigit().foregroundStyle(.secondary)
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

    /// The run's start (earliest record) as a FIXED-WIDTH `M/dd  h:mmam` string so the column's
    /// columns line up under a monospaced font: month space-padded, day zero-padded, hour
    /// space-padded, 12-hour with lowercase am/pm. Year is omitted for compactness (runs are
    /// disambiguated by day + time). E.g. " 7/21  9:42am", "12/03  1:15pm".
    private func formatStarted(_ date: Date?) -> String {
        guard let date else { return "" }
        let c = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: date)
        let month = c.month ?? 1
        let day = c.day ?? 1
        let rawHour = c.hour ?? 0
        var hour12 = rawHour % 12
        if hour12 == 0 { hour12 = 12 }
        let ampm = rawHour < 12 ? "am" : "pm"
        return String(format: "%2d/%02d %2d:%02d%@", month, day, hour12, c.minute ?? 0, ampm)
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

