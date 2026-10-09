import Testing
import Foundation
@testable import AgentSmithKit
import SwiftLLMKit

/// One per-record cost formula, priced at the cache-write rate the call actually asked for.
/// `AnthropicProvider` sends `ttl: "1h"` when the role's configuration has `extendedCacheTTL`,
/// and those writes bill at the extended rate — a record must be priced the same way (#13).
@Suite("Usage cost")
struct UsageCostTests {
    /// $1/token input, $2 output, $0.5 cache read; cache writes $4 (5-minute) or $8 (1-hour), and
    /// $16 for 1-hour writes on calls above 200k input tokens.
    private static let pricing = ModelPricing(
        base: PricingTier(input: 1, output: 2, cacheRead: 0.5, cacheWrite: 4),
        extendedCacheTier: CacheWriteOverride(
            cacheWrite: 8,
            thresholdOverrides: [TokenThresholdCacheWrite(tokenThreshold: 200_000, cacheWrite: 16)]
        )
    )

    private static func configuration(extendedCacheTTL: Bool) -> ModelConfiguration {
        ModelConfiguration(name: "test", providerID: "test-provider", modelID: "test-model", extendedCacheTTL: extendedCacheTTL)
    }

    private static func record(
        configuration: ModelConfiguration?,
        providerID: String? = "test-provider",
        input: Int = 100,
        output: Int = 10,
        cacheRead: Int = 20,
        cacheWrite: Int = 30
    ) -> UsageRecord {
        UsageRecord(
            agentRole: .brown,
            taskID: nil,
            modelID: "test-model",
            providerType: "anthropic",
            providerID: providerID,
            configuration: configuration,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            latencyMs: 1
        )
    }

    private static let aggregator = UsageAggregator { _, _ in pricing }

    @Test("A 1-hour cache write is priced at the extended rate in the usage summary")
    func summaryPricesExtendedWrites() {
        let summary = Self.aggregator.summarize([Self.record(configuration: Self.configuration(extendedCacheTTL: true))], scopeLabel: "t")
        #expect(summary.cacheWriteCostUSD == 30 * 8)
        // uncached input 100 − 20 − 30 = 50 at $1, output 10 at $2, cache read 20 at $0.5.
        #expect(summary.totalCostUSD == 50 + 20 + 10 + 240)
    }

    @Test("A 5-minute cache write keeps the base rate")
    func summaryPricesStandardWrites() {
        let summary = Self.aggregator.summarize([Self.record(configuration: Self.configuration(extendedCacheTTL: false))], scopeLabel: "t")
        #expect(summary.cacheWriteCostUSD == 30 * 4)
    }

    @Test("A record without a configuration snapshot prices at the 5-minute rate")
    func noSnapshotPricesStandard() {
        let record = Self.record(configuration: nil)
        #expect(!record.requestedExtendedCacheTTL)
        #expect(record.costBreakdown(pricing: Self.pricing).cacheWrite == 30 * 4)
    }

    @Test("The extended tier's above-threshold write rate applies to large 1-hour calls")
    func extendedThresholdOverride() {
        let record = Self.record(configuration: Self.configuration(extendedCacheTTL: true), input: 250_000)
        #expect(record.costBreakdown(pricing: Self.pricing).cacheWrite == 30 * 16)
    }

    @Test("Without an extended tier, a 1-hour write falls back to the base write rate")
    func noExtendedTierUsesBase() {
        let basePricing = ModelPricing(base: Self.pricing.base)
        let record = Self.record(configuration: Self.configuration(extendedCacheTTL: true))
        #expect(record.costBreakdown(pricing: basePricing).cacheWrite == 30 * 4)
    }

    @Test("A record with no pricing is unpriced (nil), not free")
    func unpricedIsNil() {
        let record = Self.record(configuration: nil)
        #expect(UsageRecord.cost(of: record, pricingLookup: { _, _ in nil }) == nil)
    }

    @Test("A record with no provider ID is handed to the lookup, which decides whether it is priced")
    func nilProviderIDStillPriced() {
        let record = Self.record(configuration: nil, providerID: nil)
        #expect(UsageRecord.cost(of: record, pricingLookup: { _, _ in Self.pricing }) == record.costBreakdown(pricing: Self.pricing).total)
    }

    @Test("The summary total and the per-record helper agree on an extended record")
    func summaryAndHelperAgree() {
        let record = Self.record(configuration: Self.configuration(extendedCacheTTL: true))
        let summary = Self.aggregator.summarize([record], scopeLabel: "t")
        #expect(UsageRecord.cost(of: record, pricingLookup: { _, _ in Self.pricing }) == summary.totalCostUSD)
    }

    @Test("No source outside UsageRecord+Cost.swift resolves pricing rates itself")
    func oneCostFormula() throws {
        var packageSources = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { packageSources.deleteLastPathComponent() }
        packageSources.appendPathComponent("Sources", isDirectory: true)
        var offenders: [String] = []
        for root in [packageSources, CodeStyleGuardTests.appTargetRoot] {
            let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let url as URL in enumerator where url.pathExtension == "swift" && url.lastPathComponent != "UsageRecord+Cost.swift" {
                let code = CodeStyleGuardTests.blankingCommentsAndStringContents(try String(contentsOf: url, encoding: .utf8))
                if code.contains(".effectiveRates(") || code.contains(".estimatedCost(for:") { offenders.append(url.lastPathComponent) }
            }
        }
        #expect(offenders.isEmpty, "price usage through UsageRecord.cost(of:pricingLookup:) / costBreakdown(pricing:), never a copy: \(offenders)")
    }
}
