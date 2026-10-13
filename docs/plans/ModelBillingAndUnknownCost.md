# Model billing kinds and unknown cost — plan (2026-10-10)

## What the user asked for

> we need to be able to mark a model as Free (like local models or ones running on our own
> infrastructure) and Subscription (like ChatGPT subscription)... with those in place, we should not
> count usage without a price as $0. We could show it as unknown and have a way to click on that to
> enter price manually.
>
> if a model doesn't have 1 hour cache pricing but we have 1 hour cache tokens used, that is again
> unknown - same as above.

## How it works today

- **Prices** are `ModelPricing` in swift-llm-kit (`base`, token-threshold tiers, service tiers,
  `extendedCacheTier` for the 1-hour cache-write rate). They reach `ModelInfo.pricing` through the
  five-layer facts merge (authoritative → empirical → downloaded overrides → LiteLLM → user
  overrides). A user's price lives in `ModelMetadataOverride.pricing`, edited in
  `PricingEditorSheet` (Settings › Models only).
- **No cost is stored.** Every figure is recomputed from a `UsageRecord`'s tokens through
  `UsageRecord+Cost.swift`, the one formula.
- **Missing price → $0, silently**, in three ways:
  1. no pricing for the model: `CostBoard.cost` does `?? 0`, so every rollup (inspector, sidebar chip,
     run history, task window average, PDF, session cost) counts it as free;
  2. a price with a rate missing for a category that has tokens: `rates.x ?? 0`;
  3. a 1-hour cache write on a model with no `extendedCacheTier`: `effectiveRates` keeps the base
     (5-minute) rate. `UsageCostTests` pins this ("falls back to the base write rate").
  Only the Spending dashboard's "Unpriced" pill and the task-cost sheet's per-turn "—" admit it.
- **Free / subscription** exist only as `isFree: Bool?` (badge text) and as a workaround: the Codex
  (ChatGPT subscription) decoder writes an explicit all-zero price so its usage isn't "unpriced".
  LM Studio and most Ollama models have no price and are counted as $0 by accident, not by fact.
- **A price edit doesn't reach the totals until a relaunch.** The app builds its price table once at
  launch; `LLMKitManager.setUserOverrides` only stores the dictionary until the next catalog refresh.

## Design

### 1. swift-llm-kit (next tag, 0.0.215) — billing is a model fact

A model's billing is metadata about the model, so it lives where pricing lives and travels the same
path. No app-side side table.

- `public enum ModelBilling: String, Codable, Sendable, CaseIterable { case metered, free, subscription }`
  - `metered`: priced per token by `pricing`.
  - `free`: costs nothing (local, own infrastructure, a provider's free tier).
  - `subscription`: paid by a flat subscription; per-token usage costs nothing extra.
- `ModelFacts.billing: ModelBilling?` registered in `ModelFactsFieldTable` (the reflection test
  enforces registration), materialized onto `ModelInfo.billing: ModelBilling?` (Codable,
  `decodeIfPresent`, nil = no source said).
- `ModelMetadataOverride.billing: ModelBilling?` with CodingKeys, init parameter, `asFacts`, and
  `apply(to:forceReplace:)` — so a user can set it, and a downloaded override can too.
- Decoders state what they know: Codex/ChatGPT → `.subscription`; HuggingFace `is_free == true` →
  `.free`; OpenRouter `:free` variants → `.free`. The existing `isFree` and the Codex zero price stay
  (the kit is shared; nothing is removed).
- **Immediate effect of a user edit:** a new
  `LLMKitManager.setUserOverride(_ override: ModelMetadataOverride?, providerID:modelID:)` stores the
  entry and re-composes THAT model from its cached `metadataCompositions` layers (no network), then
  updates `models`. `setUserOverrides` (bulk, at launch) is unchanged.
- Tests: field-table registration, override Codable round-trip incl. absence, `asFacts`/`apply`,
  merge precedence (user `.metered` beats decoder `.subscription`), decoder outputs, re-compose
  applies an override without a refresh.

### 2. App package — one cost formula with an honest "unknown"

`UsageRecord+Cost.swift` stays the single formula; its result becomes typed:

```swift
public enum UsageCost: Sendable, Equatable {
    case priced(UsageCostBreakdown)   // metered, every needed rate known
    case free                          // ModelBilling.free
    case subscription                  // ModelBilling.subscription
    case unpriced(UnpricedReason)      // cannot be known
}
public enum UnpricedReason: Sendable, Hashable {
    case noPricing                      // metered (or unstated) and no ModelPricing at all
    case missingRate(TokenCategory)     // a category with tokens > 0 has no rate
    case noExtendedCacheRate            // 1-hour cache write tokens, no extendedCacheTier
}
```

- Inputs: the record plus a `ModelCostBasis { billing: ModelBilling?, pricing: ModelPricing? }`
  looked up by `providerID/modelID` (replaces the bare `ModelPricing?` lookup). Billing `nil` means
  no source said, which is treated as metered — and a metered model with no price is `.unpriced`,
  surfaced, never zero.
- Metered rule: for each category whose token count is > 0 (uncached input, output, cache read,
  cache write) the effective rate must be non-nil; when the record requested the 1-hour TTL and has
  cache-write tokens, `extendedCacheTier` must exist (checked here, before `effectiveRates`, which
  keeps its current kit behaviour for other consumers). A rate missing for a category with zero
  tokens doesn't matter.
- A partly priceable record is wholly `.unpriced`: its known parts are not added, so a total never
  mixes "part of a call". Totals therefore read as a lower bound when anything is unpriced.

Aggregates carry the unknown instead of hiding it — one value type used everywhere:

```swift
public struct CostTotal: Sendable, Equatable {
    public var pricedUSD: Double           // sum of .priced records (free/subscription add 0)
    public var unpricedCalls: Int          // .unpriced records
    public var unpricedModels: Set<ModelKey>  // which models to price, for the click-through
}
```

- `CostBoard` (calendar windows, per task, per run/role) and `UsageSummary` hold `CostTotal`
  where they held `Double`. `UsageSummary.unpricedCallCount` becomes `cost.unpricedCalls`.
- `CostBoard.updateCostBasis(_:)` swaps the lookup and runs the existing `rebuildFromScratch`, so a
  price entered now re-prices history now.
- `SharedAppState` builds the cost-basis table from `llmKit.models` (billing + pricing), rebuilds it
  after a catalog refresh and after `setUserModelOverride`, and pushes it to `CostBoard` and to the
  per-view consumers (task-cost sheet, dashboard, PDF) — one table, one builder.

### 3. App UI

- **One cost label view** (`CostAmountLabel`) for every spend display listed in the inventory
  (inspector grid, role cards, sidebar task chip, template totals, run history header and rows,
  task detail Cost row, task-cost window, dashboard headline/bars/ledgers, PDF):
  - all priced: `$1.23` (as today);
  - some unpriced: `≥ $1.23` plus a question-mark badge;
  - nothing priced and something unpriced: `Unknown`;
  - chips that hide at $0 hide only when the total is known to be $0.
  Monospaced digits, colors from `AppColors`, accessibility label states "at least … , N calls
  unpriced".
- **Click-through to price it:** an unknown/partial label is a `Button` that opens a popover listing
  `unpricedModels` (model, provider, why: no price / missing rate / no 1-hour cache rate), each with
  **Set Price…** → `PricingEditorSheet(providerID:modelID:)`. On save, totals update immediately
  (kit re-compose → cost-basis rebuild → `CostBoard` rebuild).
- **`PricingEditorSheet`** gains a Billing picker: Metered / Free / Subscription, with the catalog's
  value shown as the reference like the rate rows. Free/Subscription disable the rate fields (kept,
  not cleared). The "No catalog pricing" warning becomes "costs show as unknown until you set rates
  or mark the model Free or Subscription."
- Settings › Models rows show a Free / Subscription badge from `ModelInfo.billing` (replacing the
  `isFree`-only badge, which still reads `isFree` when billing is unstated).

## Edge cases

- **Tokens with zero count** in a category never require a rate.
- **Records without a configuration snapshot** keep today's rule: requested TTL unknown → 5-minute.
- **TTL is the requested one**, not a server-confirmed split (the kit keeps one
  `cacheWriteTokens`). Unchanged; noted.
- **Subscription models' usage** contributes $0, counted as known, not unpriced.
- **A model removed from the catalog** whose records remain: no basis → `.unpriced(.noPricing)`,
  listed in the popover, priceable through the editor by key.
- **Concurrency:** the cost basis is an immutable snapshot swapped on `CostBoard` (an actor);
  `rebuildFromScratch` already serializes with inserts.
- **Dashboard "Avg / Call"** divides priced cost by priced calls only.

## Validation

- swift-llm-kit: `swift test` green; new tests above.
- App package: new `UsageCostTests` cases first, proved failing — no price → `.unpriced(.noPricing)`;
  missing cache-read rate with cache-read tokens → unpriced; 1-hour write without extended tier →
  `.unpriced(.noExtendedCacheRate)` (the existing "falls back to the base write rate" test is
  rewritten — user-approved); free and subscription → $0 known; zero-token categories need no rate.
  `CostBoard` tests: unpriced calls counted per window/task, `updateCostBasis` re-prices history.
- Guard: the existing source scan (no rate resolution outside `UsageRecord+Cost.swift`) stays green;
  a new one forbids `?? 0` on a `UsageCost`/cost lookup outside that file.
- Full package suite, Xcode build with no new warnings, and an on-screen check of the label states
  and the click-through when the app is free to relaunch.

## Decisions taken without asking (to confirm)

1. **Billing is per model**, as asked; no per-provider default. A local provider's models are each
   marked (the editor makes that one click). A provider-level default can come later.
2. **Billing lives in swift-llm-kit** as a model fact, not in an app-side table.
3. **Partly priceable calls are wholly unknown**; totals with unknowns are shown as lower bounds.
4. **Subscription counts as $0** in spend totals.
