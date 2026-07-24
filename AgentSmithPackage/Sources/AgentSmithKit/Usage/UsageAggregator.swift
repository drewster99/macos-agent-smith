import Foundation
import SwiftLLMKit

/// Computes ``UsageSummary`` aggregations from arrays of ``UsageRecord``.
///
/// Pricing is injected as a closure so the aggregator has no dependency on
/// `LLMKitManager`. Tests can stub it; production passes a closure that
/// calls `llmKit.modelInfo(providerID:modelID:)?.pricing`.
public struct UsageAggregator: Sendable {
    /// Returns `ModelPricing` for a given (providerID, modelID) pair, or nil if
    /// no pricing data is available. The aggregator calls this once per record
    /// when computing cost.
    public let pricingLookup: @Sendable (_ providerID: String?, _ modelID: String) -> ModelPricing?

    public init(pricingLookup: @escaping @Sendable (_ providerID: String?, _ modelID: String) -> ModelPricing?) {
        self.pricingLookup = pricingLookup
    }

    // MARK: - Single summary

    /// Summarizes an array of usage records into one ``UsageSummary``.
    public func summarize(_ records: [UsageRecord], scopeLabel: String = "") -> UsageSummary {
        guard !records.isEmpty else { return .empty(scopeLabel: scopeLabel) }

        var totalInputTokens = 0
        var totalUncachedInputTokens = 0
        var totalOutputTokens = 0
        var totalCacheReadTokens = 0
        var totalCacheWriteTokens = 0
        var totalLatencyMs = 0
        var totalToolCalls = 0
        var totalToolExecutionMs = 0
        var totalToolResultChars = 0
        var totalOutputChars = 0
        var totalToolArgumentChars = 0

        var inputCostUSD: Double = 0
        var outputCostUSD: Double = 0
        var cacheReadCostUSD: Double = 0
        var cacheWriteCostUSD: Double = 0
        var unpricedCallCount = 0

        var maxInputTokens = 0
        var maxOutputTokens = 0
        var maxLatencyMs = 0
        var maxCostUSD: Double = 0

        var firstTimestamp: Date?
        var lastTimestamp: Date?

        for record in records {
            totalInputTokens += record.inputTokens
            totalOutputTokens += record.outputTokens
            totalCacheReadTokens += record.cacheReadTokens
            totalCacheWriteTokens += record.cacheWriteTokens
            // Accumulate uncached tokens PER RECORD (same basis the input cost uses below), not
            // from an aggregate `Σinput − Σcache` clamp. On heterogeneous/older records the
            // aggregate could clamp to 0 while per-record cost was nonzero, so the token count
            // and the input cost disagreed. Clamped ≥ 0 per record keeps them consistent.
            let uncachedInput = max(0, record.inputTokens - record.cacheReadTokens - record.cacheWriteTokens)
            totalUncachedInputTokens += uncachedInput
            totalLatencyMs += record.latencyMs
            totalToolCalls += record.toolCallCount ?? 0
            totalToolExecutionMs += record.totalToolExecutionMs ?? 0
            totalToolResultChars += record.totalToolResultChars ?? 0
            totalOutputChars += record.outputCharCount ?? 0
            totalToolArgumentChars += record.toolCallArgumentsChars ?? 0

            maxInputTokens = max(maxInputTokens, record.inputTokens)
            maxOutputTokens = max(maxOutputTokens, record.outputTokens)
            maxLatencyMs = max(maxLatencyMs, record.latencyMs)

            // Cost — computed per-category so the summary carries a breakdown,
            // not just a total. Same math as ModelPricing.estimatedCost(for:) but
            // split into four accumulators.
            if let pricing = pricingLookup(record.providerID, record.modelID) {
                let rates = pricing.effectiveRates(totalInputTokens: record.inputTokens)
                let iCost = Double(uncachedInput) * (rates.input ?? 0)
                let oCost = Double(record.outputTokens) * (rates.output ?? 0)
                let crCost = Double(record.cacheReadTokens) * (rates.cacheRead ?? 0)
                let cwCost = Double(record.cacheWriteTokens) * (rates.cacheWrite ?? 0)
                inputCostUSD += iCost
                outputCostUSD += oCost
                cacheReadCostUSD += crCost
                cacheWriteCostUSD += cwCost
                let callCost = iCost + oCost + crCost + cwCost
                maxCostUSD = max(maxCostUSD, callCost)
            } else {
                unpricedCallCount += 1
            }

            // Timestamps
            let ts = record.timestamp
            if firstTimestamp == nil || ts < firstTimestamp! {
                firstTimestamp = ts
            }
            if lastTimestamp == nil || ts > lastTimestamp! {
                lastTimestamp = ts
            }
        }

        return UsageSummary(
            scopeLabel: scopeLabel,
            callCount: records.count,
            unpricedCallCount: unpricedCallCount,
            firstTimestamp: firstTimestamp,
            lastTimestamp: lastTimestamp,
            totalInputTokens: totalInputTokens,
            totalUncachedInputTokens: totalUncachedInputTokens,
            totalOutputTokens: totalOutputTokens,
            totalCacheReadTokens: totalCacheReadTokens,
            totalCacheWriteTokens: totalCacheWriteTokens,
            inputCostUSD: inputCostUSD,
            outputCostUSD: outputCostUSD,
            cacheReadCostUSD: cacheReadCostUSD,
            cacheWriteCostUSD: cacheWriteCostUSD,
            totalLatencyMs: totalLatencyMs,
            totalToolCalls: totalToolCalls,
            totalToolExecutionMs: totalToolExecutionMs,
            totalToolResultChars: totalToolResultChars,
            totalOutputChars: totalOutputChars,
            totalToolArgumentChars: totalToolArgumentChars,
            maxInputTokens: maxInputTokens,
            maxOutputTokens: maxOutputTokens,
            maxLatencyMs: maxLatencyMs,
            maxCostUSD: maxCostUSD
        )
    }

    // MARK: - Grouped summaries

    /// Groups records by task ID and summarizes each group.
    public func byTask(_ records: [UsageRecord]) -> [UUID?: UsageSummary] {
        grouped(records, keyPath: \.taskID) { id in
            id.map { "Task \($0.uuidString.prefix(8))" } ?? "(no task)"
        }
    }

    /// Groups records by provider ID and summarizes each group.
    public func byProvider(_ records: [UsageRecord]) -> [String?: UsageSummary] {
        grouped(records, keyPath: \.providerID) { $0 ?? "(unknown)" }
    }

    /// Groups records by agent role and summarizes each group.
    public func byAgent(_ records: [UsageRecord]) -> [AgentRole: UsageSummary] {
        grouped(records, keyPath: \.agentRole) { $0.displayName }
    }

    /// Groups records by wire model ID and summarizes each group.
    public func byModel(_ records: [UsageRecord]) -> [String: UsageSummary] {
        grouped(records, keyPath: \.modelID) { $0 }
    }

    /// Groups records by configuration UUID and summarizes each group.
    public func byConfiguration(_ records: [UsageRecord]) -> [UUID?: UsageSummary] {
        grouped(records, keyPath: \.configuration?.id) { id in
            id.map { "Config \($0.uuidString.prefix(8))" } ?? "(unknown)"
        }
    }

    /// Groups records into time buckets (day, week, month, quarter, year).
    ///
    /// Each key is the start-of-bucket `Date` (e.g. start-of-day for `.day`).
    /// Empty buckets within the range are not generated — only buckets with
    /// at least one record appear.
    public func byTimeBucket(
        _ records: [UsageRecord],
        unit: Calendar.Component,
        calendar: Calendar = .current
    ) -> [Date: UsageSummary] {
        let formatter = DateFormatter()
        switch unit {
        case .day: formatter.dateFormat = "yyyy-MM-dd"
        case .weekOfYear: formatter.dateFormat = "'W'ww yyyy"
        case .month: formatter.dateFormat = "MMM yyyy"
        case .quarter: formatter.dateFormat = "'Q'Q yyyy"
        case .year: formatter.dateFormat = "yyyy"
        default: formatter.dateFormat = "yyyy-MM-dd HH:mm"
        }

        var groups: [Date: [UsageRecord]] = [:]
        for record in records {
            let bucketStart = calendar.dateInterval(of: unit, for: record.timestamp)?.start ?? record.timestamp
            groups[bucketStart, default: []].append(record)
        }

        var result: [Date: UsageSummary] = [:]
        for (date, group) in groups {
            result[date] = summarize(group, scopeLabel: formatter.string(from: date))
        }
        return result
    }

    /// Groups records by day of week (1 = Sunday through 7 = Saturday in Gregorian).
    public func byDayOfWeek(
        _ records: [UsageRecord],
        calendar: Calendar = .current
    ) -> [Int: UsageSummary] {
        let dayNames = calendar.weekdaySymbols // ["Sunday", "Monday", ...]
        var groups: [Int: [UsageRecord]] = [:]
        for record in records {
            let weekday = calendar.component(.weekday, from: record.timestamp)
            groups[weekday, default: []].append(record)
        }

        var result: [Int: UsageSummary] = [:]
        for (weekday, group) in groups {
            let name = weekday <= dayNames.count ? dayNames[weekday - 1] : "Day \(weekday)"
            result[weekday] = summarize(group, scopeLabel: name)
        }
        return result
    }

    // MARK: - Private

    /// Generic grouping helper. Groups records by a key extracted via `keyPath`,
    /// summarizes each group with a label from `labelForKey`.
    private func grouped<K: Hashable>(
        _ records: [UsageRecord],
        keyPath: KeyPath<UsageRecord, K>,
        labelForKey: (K) -> String
    ) -> [K: UsageSummary] {
        var groups: [K: [UsageRecord]] = [:]
        for record in records {
            groups[record[keyPath: keyPath], default: []].append(record)
        }
        var result: [K: UsageSummary] = [:]
        for (key, group) in groups {
            result[key] = summarize(group, scopeLabel: labelForKey(key))
        }
        return result
    }
}
