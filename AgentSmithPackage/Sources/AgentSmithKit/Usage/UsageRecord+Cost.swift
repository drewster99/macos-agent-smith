import Foundation
import SwiftLLMKit

/// One call's cost split by what was billed.
public struct UsageCostBreakdown: Sendable, Equatable {
    /// Cost of the input tokens neither served from nor written to the prompt cache.
    public var input: Double
    /// Cost of the output (completion) tokens.
    public var output: Double
    /// Cost of the input served from the prompt cache.
    public var cacheRead: Double
    /// Cost of the input written to the prompt cache, at the 5-minute or 1-hour rate the call asked for.
    public var cacheWrite: Double

    /// The call's whole cost.
    public var total: Double { input + output + cacheRead + cacheWrite }
}

/// The ONE per-record cost formula. Every surface that prices usage — the cost board, usage
/// summaries, the task cost sheet, the PDF export — goes through it, so they can never disagree
/// about the same call again (#13: four hand-copied formulas had all dropped the extended cache
/// rate). Synchronous on purpose: `CostBoard.recordInserted` prices inside a non-suspending
/// critical section.
extension UsageRecord {
    /// Whether this call asked for 1-hour cache writes, read from the configuration snapshot it was
    /// sent with — the provider puts `ttl: "1h"` on the wire from that same flag. A record without
    /// a snapshot (written before snapshots existed) is priced at the 5-minute rate, which is all
    /// such a call could have used.
    ///
    /// This is the TTL requested, not one the server confirmed; a route that ignores the TTL is
    /// still priced by its pricing's `extendedCacheTier`, which is absent unless the catalog (or
    /// the user) gave that model a 1-hour rate.
    public var requestedExtendedCacheTTL: Bool { configuration?.extendedCacheTTL ?? false }

    /// This record's cost at `pricing`. Cached input is billed at its own rates, so only the
    /// remainder is billed as uncached input (clamped at zero for records whose provider counts
    /// cache tokens outside the input total).
    public func costBreakdown(pricing: ModelPricing) -> UsageCostBreakdown {
        let rates = pricing.effectiveRates(totalInputTokens: inputTokens, extendedCache: requestedExtendedCacheTTL)
        return UsageCostBreakdown(
            input: Double(uncachedInputTokens) * (rates.input ?? 0),
            output: Double(outputTokens) * (rates.output ?? 0),
            cacheRead: Double(cacheReadTokens) * (rates.cacheRead ?? 0),
            cacheWrite: Double(cacheWriteTokens) * (rates.cacheWrite ?? 0)
        )
    }

    /// Input tokens billed at the uncached rate.
    public var uncachedInputTokens: Int { max(0, inputTokens - cacheReadTokens - cacheWriteTokens) }

    /// `record`'s total cost, or nil when `pricingLookup` has no pricing for its model — unpriced,
    /// which callers count separately rather than treat as free.
    public static func cost(
        of record: UsageRecord,
        pricingLookup: (String?, String) -> ModelPricing?
    ) -> Double? {
        guard let pricing = pricingLookup(record.providerID, record.modelID) else { return nil }
        return record.costBreakdown(pricing: pricing).total
    }
}
