import Foundation
import AgentSmithKit

/// What one Spending Dashboard load asks for: plain bounds and a bucket unit, resolved on the main
/// actor from the selected range so the off-main pass needs nothing view-owned.
nonisolated struct DashboardAggregationRequest: Sendable {
    /// Inclusive bounds of the selected range.
    let currentBounds: DateInterval
    /// Start (inclusive) and end (EXCLUSIVE) of the equivalent prior period; nil for All.
    let priorBounds: (start: Date, end: Date)?
    let scopeLabel: String
    let bucketUnit: Calendar.Component

    @MainActor
    init(range: SpendingDashboardView.TimeRange) {
        let interval = range.dateInterval()
        if range == .all {
            currentBounds = DateInterval(start: .distantPast, end: .distantFuture)
            priorBounds = nil
        } else {
            currentBounds = DateInterval(start: interval.current.start, end: interval.current.end)
            priorBounds = (interval.prior.start, interval.prior.end)
        }
        scopeLabel = range.rawValue
        switch range {
        case .today: bucketUnit = .hour
        case .week, .month: bucketUnit = .day
        case .all: bucketUnit = .month
        }
    }
}

/// Everything the Spending Dashboard shows, computed in one pass OFF the main thread from the
/// selected range's records. The records themselves are fetched inside `compute` and released when
/// it returns, so the window never holds them.
nonisolated struct DashboardAggregate: Sendable {
    /// One provider's cost in one time bucket.
    struct ChartBucket: Sendable {
        let providerID: String
        let date: Date
        let cost: Double
    }

    let currentBounds: DateInterval
    let current: UsageSummary
    let prior: UsageSummary
    /// Per task; the `nil` key is the Orchestration bucket (records attributed to no task).
    let byTask: [UUID?: UsageSummary]
    let byProvider: [String?: UsageSummary]
    let byAgent: [AgentRole: UsageSummary]
    let byModel: [String: UsageSummary]
    let toolCallCounts: [String: Int]
    let bucketUnit: Calendar.Component
    let chartBuckets: [ChartBucket]

    /// Fetches the range's records from the store and aggregates them. `@concurrent` because this
    /// file is in the app target, where everything defaults to the main actor and a plain `async`
    /// function would run its aggregation there.
    ///
    /// `records(from:to:)` returns a filtered, independently owned array, so nothing here shares the
    /// store's live buffer (see `UsageStore.allRecords()` for why that matters).
    @concurrent
    static func compute(
        _ request: DashboardAggregationRequest,
        store: UsageStore,
        aggregator: UsageAggregator
    ) async -> DashboardAggregate {
        let records = await store.records(from: request.currentBounds.start, to: request.currentBounds.end)
        let priorRecords: [UsageRecord]
        if let prior = request.priorBounds {
            // The prior period's end is exclusive: it is the current period's start.
            priorRecords = await store.records(from: prior.start, to: prior.end)
                .filter { $0.timestamp < prior.end }
        } else {
            priorRecords = []
        }

        let byProvider = aggregator.byProvider(records)
        var chartBuckets: [ChartBucket] = []
        for providerID in byProvider.keys.compactMap({ $0 }).sorted() {
            let providerRecords = records.filter { $0.providerID == providerID }
            for (date, summary) in aggregator.byTimeBucket(providerRecords, unit: request.bucketUnit) {
                chartBuckets.append(ChartBucket(providerID: providerID, date: date, cost: summary.totalCostUSD))
            }
        }

        var toolCallCounts: [String: Int] = [:]
        for record in records {
            guard let names = record.toolCallNames else { continue }
            for name in names {
                toolCallCounts[name, default: 0] += 1
            }
        }

        return DashboardAggregate(
            currentBounds: request.currentBounds,
            current: aggregator.summarize(records, scopeLabel: request.scopeLabel),
            prior: aggregator.summarize(priorRecords, scopeLabel: "Prior \(request.scopeLabel)"),
            byTask: aggregator.byTask(records),
            byProvider: byProvider,
            byAgent: aggregator.byAgent(records),
            byModel: aggregator.byModel(records),
            toolCallCounts: toolCallCounts,
            bucketUnit: request.bucketUnit,
            chartBuckets: chartBuckets
        )
    }
}
