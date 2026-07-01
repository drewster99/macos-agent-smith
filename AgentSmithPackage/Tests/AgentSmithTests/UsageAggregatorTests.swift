import Testing
import Foundation
@testable import AgentSmithKit
import SwiftLLMKit

// MARK: - Test helpers

/// Creates a UsageRecord with sensible defaults for testing. Only fields under
/// test need to be overridden; the rest default to zero/nil.
private func makeRecord(
    agentRole: AgentRole = .brown,
    taskID: UUID? = nil,
    modelID: String = "test-model",
    providerType: String = "test",
    providerID: String? = "test-provider",
    inputTokens: Int = 100,
    outputTokens: Int = 50,
    cacheReadTokens: Int = 0,
    cacheWriteTokens: Int = 0,
    latencyMs: Int = 500,
    outputCharCount: Int? = 200,
    toolCallCount: Int? = 0,
    toolCallNames: [String]? = [],
    toolCallArgumentsChars: Int? = 0,
    totalToolExecutionMs: Int? = 0,
    totalToolResultChars: Int? = 0,
    timestamp: Date = Date(),
    sessionID: UUID? = nil
) -> UsageRecord {
    UsageRecord(
        timestamp: timestamp,
        agentRole: agentRole,
        taskID: taskID,
        modelID: modelID,
        providerType: providerType,
        providerID: providerID,
        configuration: nil,
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        cacheReadTokens: cacheReadTokens,
        cacheWriteTokens: cacheWriteTokens,
        latencyMs: latencyMs,
        outputCharCount: outputCharCount,
        toolCallCount: toolCallCount,
        toolCallNames: toolCallNames,
        toolCallArgumentsChars: toolCallArgumentsChars,
        totalToolExecutionMs: totalToolExecutionMs,
        totalToolResultChars: totalToolResultChars,
        sessionID: sessionID
    )
}

/// A pricing model: $3/M input, $15/M output, $0.30/M cache read, $3.75/M cache write.
/// (Typical Anthropic Sonnet-class pricing.)
private let testPricing = ModelPricing(base: PricingTier(
    input: 3.0 / 1_000_000,
    output: 15.0 / 1_000_000,
    cacheRead: 0.30 / 1_000_000,
    cacheWrite: 3.75 / 1_000_000
))

/// Aggregator that returns testPricing for "test-provider"/"test-model" and nil otherwise.
private let testAggregator = UsageAggregator { providerID, modelID in
    (providerID == "test-provider" && modelID == "test-model") ? testPricing : nil
}

/// Aggregator with no pricing data at all.
private let noPricingAggregator = UsageAggregator { _, _ in nil }

// MARK: - Tests

@Suite("UsageAggregator Tests")
struct UsageAggregatorTests {

    // MARK: - Empty input

    @Test("Empty records produce empty summary")
    func emptyRecords() {
        let summary = testAggregator.summarize([], scopeLabel: "Empty")
        #expect(summary.callCount == 0)
        #expect(summary.totalCostUSD == 0)
        #expect(summary.firstTimestamp == nil)
        #expect(summary.lastTimestamp == nil)
        #expect(summary.cacheHitRate == 0)
        #expect(summary.avgLatencyMs == 0)
        #expect(summary.scopeLabel == "Empty")
    }

    // MARK: - Single record

    @Test("Single record produces correct totals")
    func singleRecord() {
        let r = makeRecord(
            inputTokens: 1000, outputTokens: 200,
            cacheReadTokens: 300, cacheWriteTokens: 100,
            latencyMs: 1500,
            outputCharCount: 800,
            toolCallCount: 2,
            toolCallArgumentsChars: 150,
            totalToolExecutionMs: 340,
            totalToolResultChars: 500
        )
        let s = testAggregator.summarize([r], scopeLabel: "Single")

        #expect(s.callCount == 1)
        #expect(s.totalInputTokens == 1000)
        #expect(s.totalOutputTokens == 200)
        #expect(s.totalCacheReadTokens == 300)
        #expect(s.totalCacheWriteTokens == 100)
        // Uncached = 1000 - 300 - 100 = 600
        #expect(s.totalUncachedInputTokens == 600)
        #expect(s.totalLatencyMs == 1500)
        #expect(s.totalToolCalls == 2)
        #expect(s.totalToolExecutionMs == 340)
        #expect(s.totalToolResultChars == 500)
        #expect(s.totalOutputChars == 800)
        #expect(s.totalToolArgumentChars == 150)
        #expect(s.maxInputTokens == 1000)
        #expect(s.maxOutputTokens == 200)
        #expect(s.maxLatencyMs == 1500)
    }

    // MARK: - Accumulation

    @Test("Multiple records accumulate correctly")
    func accumulation() {
        let records = [
            makeRecord(inputTokens: 100, outputTokens: 50, latencyMs: 200),
            makeRecord(inputTokens: 200, outputTokens: 100, latencyMs: 300),
            makeRecord(inputTokens: 150, outputTokens: 75, latencyMs: 250),
        ]
        let s = testAggregator.summarize(records)

        #expect(s.callCount == 3)
        #expect(s.totalInputTokens == 450)
        #expect(s.totalOutputTokens == 225)
        #expect(s.totalLatencyMs == 750)
        #expect(s.maxInputTokens == 200)
        #expect(s.maxOutputTokens == 100)
        #expect(s.maxLatencyMs == 300)
        #expect(s.avgInputTokens == 150.0)
        #expect(s.avgOutputTokens == 75.0)
        #expect(s.avgLatencyMs == 250.0)
    }

    // MARK: - Cost calculation

    @Test("Cost uses pricing closure correctly")
    func costCalculation() {
        // 1000 input, 200 output, no cache → uncached = 1000
        // input cost = 1000 * 3/1M = 0.003
        // output cost = 200 * 15/1M = 0.003
        let r = makeRecord(inputTokens: 1000, outputTokens: 200)
        let s = testAggregator.summarize([r])

        #expect(abs(s.inputCostUSD - 0.003) < 1e-9)
        #expect(abs(s.outputCostUSD - 0.003) < 1e-9)
        #expect(abs(s.totalCostUSD - 0.006) < 1e-9)
        #expect(s.unpricedCallCount == 0)
    }

    @Test("Cache pricing splits correctly")
    func cachePricing() {
        // 1000 total input: 400 cache read, 100 cache write, 500 uncached
        let r = makeRecord(
            inputTokens: 1000, outputTokens: 0,
            cacheReadTokens: 400, cacheWriteTokens: 100
        )
        let s = testAggregator.summarize([r])

        // uncached = 1000 - 400 - 100 = 500 → 500 * 3/1M = 0.0015
        #expect(abs(s.inputCostUSD - 0.0015) < 1e-9)
        // cache read = 400 * 0.30/1M = 0.00012
        #expect(abs(s.cacheReadCostUSD - 0.00012) < 1e-9)
        // cache write = 100 * 3.75/1M = 0.000375
        #expect(abs(s.cacheWriteCostUSD - 0.000375) < 1e-9)
    }

    @Test("Unpriced records are counted")
    func unpricedRecords() {
        let r = makeRecord(modelID: "unknown-model", providerID: "unknown-provider")
        let s = testAggregator.summarize([r])

        #expect(s.unpricedCallCount == 1)
        #expect(s.totalCostUSD == 0)
    }

    @Test("Mixed priced and unpriced records")
    func mixedPricing() {
        let records = [
            makeRecord(inputTokens: 1000, outputTokens: 200),
            makeRecord(providerID: "unknown", inputTokens: 500, outputTokens: 100),
        ]
        let s = testAggregator.summarize(records)

        #expect(s.callCount == 2)
        #expect(s.unpricedCallCount == 1)
        // Only the first record contributes cost
        #expect(abs(s.totalCostUSD - 0.006) < 1e-9)
    }

    @Test("No pricing aggregator marks all unpriced")
    func noPricing() {
        let records = [makeRecord(), makeRecord()]
        let s = noPricingAggregator.summarize(records)

        #expect(s.unpricedCallCount == 2)
        #expect(s.totalCostUSD == 0)
    }

    // MARK: - Cache hit rate

    @Test("Cache hit rate computes correctly")
    func cacheHitRate() {
        // 1000 total, 400 cache read, 100 cache write → uncached = 500
        // hit rate = cacheRead / totalInput = 400 / 1000 = 0.4
        // Cache writes count against the hit rate (they're misses that populate the cache).
        let r = makeRecord(inputTokens: 1000, cacheReadTokens: 400, cacheWriteTokens: 100)
        let s = testAggregator.summarize([r])

        #expect(abs(s.cacheHitRate - 400.0 / 1000.0) < 1e-9)
    }

    @Test("Cache hit rate is 0 with no cache")
    func noCacheHitRate() {
        let r = makeRecord(inputTokens: 1000, cacheReadTokens: 0, cacheWriteTokens: 0)
        let s = testAggregator.summarize([r])

        #expect(s.cacheHitRate == 0)
    }

    // MARK: - Timestamps

    @Test("Timestamps track first and last")
    func timestamps() {
        let t1 = Date(timeIntervalSinceReferenceDate: 1000)
        let t2 = Date(timeIntervalSinceReferenceDate: 2000)
        let t3 = Date(timeIntervalSinceReferenceDate: 3000)
        let records = [
            makeRecord(timestamp: t2),
            makeRecord(timestamp: t1),
            makeRecord(timestamp: t3),
        ]
        let s = testAggregator.summarize(records)

        #expect(s.firstTimestamp == t1)
        #expect(s.lastTimestamp == t3)
    }

    // MARK: - Max cost tracking

    @Test("Max cost tracks the most expensive single call")
    func maxCost() {
        let records = [
            makeRecord(inputTokens: 100, outputTokens: 50),   // low
            makeRecord(inputTokens: 10000, outputTokens: 5000), // high
            makeRecord(inputTokens: 500, outputTokens: 200),   // medium
        ]
        let s = testAggregator.summarize(records)

        // High call: 10000 * 3/1M + 5000 * 15/1M = 0.03 + 0.075 = 0.105
        #expect(abs(s.maxCostUSD - 0.105) < 1e-9)
    }

    // MARK: - Group by agent

    @Test("Group by agent partitions correctly")
    func groupByAgent() {
        let records = [
            makeRecord(agentRole: .brown, inputTokens: 100),
            makeRecord(agentRole: .smith, inputTokens: 200),
            makeRecord(agentRole: .brown, inputTokens: 300),
            makeRecord(agentRole: .securityAgent, inputTokens: 50),
        ]
        let grouped = testAggregator.byAgent(records)

        #expect(grouped.count == 3)
        #expect(grouped[.brown]?.callCount == 2)
        #expect(grouped[.brown]?.totalInputTokens == 400)
        #expect(grouped[.smith]?.callCount == 1)
        #expect(grouped[.smith]?.totalInputTokens == 200)
        #expect(grouped[.securityAgent]?.callCount == 1)
        #expect(grouped[.securityAgent]?.totalInputTokens == 50)
    }

    // MARK: - Group by provider

    @Test("Group by provider partitions correctly")
    func groupByProvider() {
        let records = [
            makeRecord(providerID: "anthropic", inputTokens: 100),
            makeRecord(providerID: "openai", inputTokens: 200),
            makeRecord(providerID: "anthropic", inputTokens: 300),
        ]
        let grouped = testAggregator.byProvider(records)

        #expect(grouped.count == 2)
        #expect(grouped["anthropic"]?.callCount == 2)
        #expect(grouped["anthropic"]?.totalInputTokens == 400)
        #expect(grouped["openai"]?.callCount == 1)
    }

    // MARK: - Group by task

    @Test("Group by task separates nil task IDs")
    func groupByTask() {
        let task1 = UUID()
        let task2 = UUID()
        let records = [
            makeRecord(taskID: task1),
            makeRecord(taskID: task2),
            makeRecord(taskID: task1),
            makeRecord(taskID: nil),
        ]
        let grouped = testAggregator.byTask(records)

        #expect(grouped.count == 3)
        #expect(grouped[task1]?.callCount == 2)
        #expect(grouped[task2]?.callCount == 1)
        #expect(grouped[nil]?.callCount == 1)
    }

    // MARK: - Group by time bucket

    @Test("Group by day buckets records correctly")
    func groupByDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!

        // Two records on 2026-04-09, one on 2026-04-10
        let day1a = cal.date(from: DateComponents(year: 2026, month: 4, day: 9, hour: 10))!
        let day1b = cal.date(from: DateComponents(year: 2026, month: 4, day: 9, hour: 22))!
        let day2 = cal.date(from: DateComponents(year: 2026, month: 4, day: 10, hour: 5))!

        let records = [
            makeRecord(inputTokens: 100, timestamp: day1a),
            makeRecord(inputTokens: 200, timestamp: day1b),
            makeRecord(inputTokens: 300, timestamp: day2),
        ]
        let grouped = testAggregator.byTimeBucket(records, unit: .day, calendar: cal)

        #expect(grouped.count == 2)
        let day1Start = cal.startOfDay(for: day1a)
        let day2Start = cal.startOfDay(for: day2)
        #expect(grouped[day1Start]?.callCount == 2)
        #expect(grouped[day1Start]?.totalInputTokens == 300)
        #expect(grouped[day2Start]?.callCount == 1)
        #expect(grouped[day2Start]?.totalInputTokens == 300)
    }

    @Test("Group by month buckets records correctly")
    func groupByMonth() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!

        let march = cal.date(from: DateComponents(year: 2026, month: 3, day: 15))!
        let april1 = cal.date(from: DateComponents(year: 2026, month: 4, day: 1))!
        let april30 = cal.date(from: DateComponents(year: 2026, month: 4, day: 30))!

        let records = [
            makeRecord(timestamp: march),
            makeRecord(timestamp: april1),
            makeRecord(timestamp: april30),
        ]
        let grouped = testAggregator.byTimeBucket(records, unit: .month, calendar: cal)

        #expect(grouped.count == 2)
        // March and April should be distinct buckets
        let marchStart = cal.dateInterval(of: .month, for: march)!.start
        let aprilStart = cal.dateInterval(of: .month, for: april1)!.start
        #expect(grouped[marchStart]?.callCount == 1)
        #expect(grouped[aprilStart]?.callCount == 2)
    }

    // MARK: - Group by day of week

    @Test("Group by day of week uses weekday numbers")
    func groupByDayOfWeek() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!

        // 2026-04-06 is a Monday (weekday 2 in Gregorian)
        let monday = cal.date(from: DateComponents(year: 2026, month: 4, day: 6, hour: 12))!
        // 2026-04-07 is a Tuesday (weekday 3)
        let tuesday = cal.date(from: DateComponents(year: 2026, month: 4, day: 7, hour: 12))!
        // 2026-04-13 is the next Monday
        let nextMonday = cal.date(from: DateComponents(year: 2026, month: 4, day: 13, hour: 12))!

        let records = [
            makeRecord(inputTokens: 100, timestamp: monday),
            makeRecord(inputTokens: 200, timestamp: tuesday),
            makeRecord(inputTokens: 300, timestamp: nextMonday),
        ]
        let grouped = testAggregator.byDayOfWeek(records, calendar: cal)

        // Two Mondays grouped together, one Tuesday separate
        #expect(grouped.count == 2)
        #expect(grouped[2]?.callCount == 2) // Monday
        #expect(grouped[2]?.totalInputTokens == 400)
        #expect(grouped[3]?.callCount == 1) // Tuesday
    }

    // MARK: - Group by model

    @Test("Group by model partitions correctly")
    func groupByModel() {
        let records = [
            makeRecord(modelID: "claude-sonnet", inputTokens: 100),
            makeRecord(modelID: "gpt-4o", inputTokens: 200),
            makeRecord(modelID: "claude-sonnet", inputTokens: 300),
            makeRecord(modelID: "gemini-flash", inputTokens: 50),
        ]
        let grouped = testAggregator.byModel(records)

        #expect(grouped.count == 3)
        #expect(grouped["claude-sonnet"]?.callCount == 2)
        #expect(grouped["claude-sonnet"]?.totalInputTokens == 400)
        #expect(grouped["gpt-4o"]?.callCount == 1)
        #expect(grouped["gpt-4o"]?.totalInputTokens == 200)
        #expect(grouped["gemini-flash"]?.callCount == 1)
    }

    // MARK: - Group by configuration

    @Test("Group by configuration partitions by config UUID")
    func groupByConfiguration() {
        let configA = ModelConfiguration(
            name: "Config A", providerID: "test", modelID: "model-a"
        )
        let configB = ModelConfiguration(
            name: "Config B", providerID: "test", modelID: "model-b"
        )

        let records = [
            UsageRecord(
                agentRole: .brown, taskID: nil, modelID: "model-a",
                providerType: "test", providerID: "test",
                configuration: configA,
                inputTokens: 100, outputTokens: 50, latencyMs: 200
            ),
            UsageRecord(
                agentRole: .brown, taskID: nil, modelID: "model-b",
                providerType: "test", providerID: "test",
                configuration: configB,
                inputTokens: 200, outputTokens: 100, latencyMs: 300
            ),
            UsageRecord(
                agentRole: .brown, taskID: nil, modelID: "model-a",
                providerType: "test", providerID: "test",
                configuration: configA,
                inputTokens: 150, outputTokens: 75, latencyMs: 250
            ),
        ]
        let grouped = testAggregator.byConfiguration(records)

        #expect(grouped.count == 2)
        #expect(grouped[configA.id]?.callCount == 2)
        #expect(grouped[configA.id]?.totalInputTokens == 250)
        #expect(grouped[configB.id]?.callCount == 1)
        #expect(grouped[configB.id]?.totalInputTokens == 200)
    }

    // MARK: - Group by week

    @Test("Group by week buckets records correctly")
    func groupByWeek() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!

        // 2026-04-06 (Mon) and 2026-04-08 (Wed) are in the same week
        let mon = cal.date(from: DateComponents(year: 2026, month: 4, day: 6, hour: 12))!
        let wed = cal.date(from: DateComponents(year: 2026, month: 4, day: 8, hour: 12))!
        // 2026-04-13 (Mon) is the next week
        let nextMon = cal.date(from: DateComponents(year: 2026, month: 4, day: 13, hour: 12))!

        let records = [
            makeRecord(inputTokens: 100, timestamp: mon),
            makeRecord(inputTokens: 200, timestamp: wed),
            makeRecord(inputTokens: 300, timestamp: nextMon),
        ]
        let grouped = testAggregator.byTimeBucket(records, unit: .weekOfYear, calendar: cal)

        #expect(grouped.count == 2)
        let week1Start = cal.dateInterval(of: .weekOfYear, for: mon)!.start
        let week2Start = cal.dateInterval(of: .weekOfYear, for: nextMon)!.start
        #expect(grouped[week1Start]?.callCount == 2)
        #expect(grouped[week1Start]?.totalInputTokens == 300)
        #expect(grouped[week2Start]?.callCount == 1)
        #expect(grouped[week2Start]?.totalInputTokens == 300)
    }

    // MARK: - Group by quarter

    @Test("Group by quarter buckets records correctly")
    func groupByQuarter() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!

        let q1 = cal.date(from: DateComponents(year: 2026, month: 2, day: 15))! // Q1
        let q2a = cal.date(from: DateComponents(year: 2026, month: 4, day: 1))! // Q2
        let q2b = cal.date(from: DateComponents(year: 2026, month: 6, day: 30))! // Q2

        let records = [
            makeRecord(inputTokens: 100, timestamp: q1),
            makeRecord(inputTokens: 200, timestamp: q2a),
            makeRecord(inputTokens: 300, timestamp: q2b),
        ]
        let grouped = testAggregator.byTimeBucket(records, unit: .quarter, calendar: cal)

        #expect(grouped.count == 2)
        let q1Start = cal.dateInterval(of: .quarter, for: q1)!.start
        let q2Start = cal.dateInterval(of: .quarter, for: q2a)!.start
        #expect(grouped[q1Start]?.callCount == 1)
        #expect(grouped[q2Start]?.callCount == 2)
        #expect(grouped[q2Start]?.totalInputTokens == 500)
    }

    // MARK: - Group by year

    @Test("Group by year buckets records correctly")
    func groupByYear() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!

        let y2025 = cal.date(from: DateComponents(year: 2025, month: 11, day: 1))!
        let y2026a = cal.date(from: DateComponents(year: 2026, month: 1, day: 15))!
        let y2026b = cal.date(from: DateComponents(year: 2026, month: 12, day: 31))!

        let records = [
            makeRecord(inputTokens: 100, timestamp: y2025),
            makeRecord(inputTokens: 200, timestamp: y2026a),
            makeRecord(inputTokens: 300, timestamp: y2026b),
        ]
        let grouped = testAggregator.byTimeBucket(records, unit: .year, calendar: cal)

        #expect(grouped.count == 2)
        let y2025Start = cal.dateInterval(of: .year, for: y2025)!.start
        let y2026Start = cal.dateInterval(of: .year, for: y2026a)!.start
        #expect(grouped[y2025Start]?.callCount == 1)
        #expect(grouped[y2026Start]?.callCount == 2)
        #expect(grouped[y2026Start]?.totalInputTokens == 500)
    }

    // MARK: - Tool stats accumulation

    @Test("Tool stats accumulate across records")
    func toolStatsAccumulation() {
        let records = [
            makeRecord(
                toolCallCount: 3, toolCallNames: ["file_read", "file_write", "bash"],
                toolCallArgumentsChars: 500,
                totalToolExecutionMs: 1200, totalToolResultChars: 3000
            ),
            makeRecord(
                toolCallCount: 1, toolCallNames: ["grep"],
                toolCallArgumentsChars: 100,
                totalToolExecutionMs: 50, totalToolResultChars: 800
            ),
        ]
        let s = testAggregator.summarize(records)

        #expect(s.totalToolCalls == 4)
        #expect(s.totalToolExecutionMs == 1250)
        #expect(s.totalToolResultChars == 3800)
        #expect(s.totalToolArgumentChars == 600)
    }

    // MARK: - Output char accumulation

    @Test("Output chars accumulate across records")
    func outputCharAccumulation() {
        let records = [
            makeRecord(outputCharCount: 500),
            makeRecord(outputCharCount: 1200),
            makeRecord(outputCharCount: nil), // legacy record
        ]
        let s = testAggregator.summarize(records)

        #expect(s.totalOutputChars == 1700)
    }

    // MARK: - Cost accumulates across multiple records

    @Test("Cost accumulates across multiple records")
    func costAccumulatesAcrossRecords() {
        // Two identical records, cost should be 2x single
        let r = makeRecord(inputTokens: 1000, outputTokens: 200)
        let single = testAggregator.summarize([r])
        let double = testAggregator.summarize([r, r])

        #expect(abs(double.totalCostUSD - single.totalCostUSD * 2) < 1e-9)
        #expect(abs(double.inputCostUSD - single.inputCostUSD * 2) < 1e-9)
        #expect(abs(double.outputCostUSD - single.outputCostUSD * 2) < 1e-9)
    }

    // MARK: - All averages are zero for empty input

    @Test("All averages are zero for empty input")
    func emptyAverages() {
        let s = testAggregator.summarize([])
        #expect(s.avgInputTokens == 0)
        #expect(s.avgOutputTokens == 0)
        #expect(s.avgLatencyMs == 0)
        #expect(s.avgCostUSD == 0)
    }

    // MARK: - Session grouping via byTimeBucket doesn't cross sessions

    @Test("Records from different sessions in the same day stay in one day bucket")
    func sessionsInSameDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!

        let session1 = UUID()
        let session2 = UUID()
        let t1 = cal.date(from: DateComponents(year: 2026, month: 4, day: 9, hour: 8))!
        let t2 = cal.date(from: DateComponents(year: 2026, month: 4, day: 9, hour: 20))!

        let records = [
            makeRecord(inputTokens: 100, timestamp: t1, sessionID: session1),
            makeRecord(inputTokens: 200, timestamp: t2, sessionID: session2),
        ]
        let grouped = testAggregator.byTimeBucket(records, unit: .day, calendar: cal)

        // Both in the same day bucket, despite different sessions
        #expect(grouped.count == 1)
        let dayStart = cal.startOfDay(for: t1)
        #expect(grouped[dayStart]?.callCount == 2)
        #expect(grouped[dayStart]?.totalInputTokens == 300)
    }

    // MARK: - Tool stats from nil fields (legacy records)

    @Test("Legacy records with nil tool fields contribute 0")
    func legacyRecordsNilToolFields() {
        let r = UsageRecord(
            agentRole: .brown, taskID: nil,
            modelID: "test-model", providerType: "test",
            providerID: "test-provider", configuration: nil,
            inputTokens: 100, outputTokens: 50, latencyMs: 500
            // All tool/char fields default to nil
        )
        let s = testAggregator.summarize([r])

        #expect(s.totalToolCalls == 0)
        #expect(s.totalToolExecutionMs == 0)
        #expect(s.totalToolResultChars == 0)
        #expect(s.totalOutputChars == 0)
        #expect(s.totalToolArgumentChars == 0)
    }

    // MARK: - Scope label propagation

    @Test("Scope label is set on grouped summaries")
    func scopeLabels() {
        let records = [
            makeRecord(agentRole: .brown),
            makeRecord(agentRole: .smith),
        ]
        let grouped = testAggregator.byAgent(records)

        #expect(grouped[.brown]?.scopeLabel == "Brown")
        #expect(grouped[.smith]?.scopeLabel == "Smith")
    }
}
