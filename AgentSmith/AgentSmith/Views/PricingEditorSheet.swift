import SwiftUI
import SwiftLLMKit

/// Per-(provider, model) pricing override editor — the third twin alongside `BehaviorFlagsEditorSheet`
/// and `CapabilitiesEditorSheet`, covering the WHOLE `ModelPricing` model: base input/output/cache
/// read/write, context-length threshold tiers, named service tiers, and the extended-cache write
/// rate. (Reasoning/thinking has no rate of its own — every current provider bills it as output.)
///
/// **Base rates use the shared Default/Override control** (like the token limits): each shows the
/// catalog rate as a reference and is overridden per-rate, so overriding input never wipes the
/// catalog's cache/output rates. Rates are entered in USD per **1M tokens**; storage stays USD per
/// single token. Advanced tiers are carried from the resolved pricing so they survive a base-rate
/// edit. Saving force-replaces this model's pricing; Clear Override reverts to catalog pricing; an
/// unchanged visit writes nothing.
struct PricingEditorSheet: View {
    @Bindable var shared: SharedAppState
    let providerID: String
    let modelID: String

    @Environment(\.dismiss) private var dismiss

    @State private var editable = EditablePricing()
    /// The pricing built from the seed, so Done no-ops when nothing changed (never pinning a
    /// catalog-priced model just because the sheet was opened).
    @State private var initialBuilt = ModelPricing()
    /// Catalog + resolved pricing CAPTURED AT LOAD. Reused for every build so a background refresh
    /// mid-sheet can't shift the reference out from under the no-op comparison (and the reference
    /// display stays stable while the sheet is open).
    @State private var catalogAtLoad: ModelPricing?
    @State private var resolvedAtLoad: ModelPricing?
    /// Set by Clear Override so Done removes the pricing override even though the built pricing may
    /// equal the catalog (a base rate defaulting back to the catalog value is not "empty").
    @State private var explicitlyCleared = false
    /// Bumped on Clear Override so each base-rate control fully resyncs (incl. an uncommitted field).
    @State private var resetToken = 0
    @State private var expandThresholds = false
    @State private var expandService = false
    @State private var expandExtended = false

    private var key: String { "\(providerID)/\(modelID)" }

    private var resolvedPricing: ModelPricing? {
        shared.llmKit.modelInfo(providerID: providerID, modelID: modelID)?.pricing
    }

    /// Catalog pricing WITHOUT this user's override — the reference each base rate defaults to.
    ///
    /// Read from the composition's non-user layers in the SAME precedence the merge applies:
    /// `downloadedOverrides` (force) outranks the gap-fill layers authoritative → empirical →
    /// enrichment. Compositions are in-memory and empty on a cached launch that never refreshed, so
    /// when there is no user pricing override the resolved pricing IS the catalog (the fallback
    /// `reportedLimit` uses for token limits). `nil` only when no source states pricing and an
    /// override exists — the one case pre-override pricing genuinely can't be recovered.
    private func computeCatalogPricing() -> ModelPricing? {
        if let composition = shared.llmKit.metadataCompositions[key] {
            for layer in [MetadataLayer.downloadedOverrides, .authoritative, .empirical, .enrichment] {
                if let facts = composition.layers[layer], let pricing = facts.pricing { return pricing }
            }
        }
        if shared.userModelOverrides[key]?.pricing == nil { return resolvedPricing }
        return nil
    }

    private var hasPricingOverride: Bool {
        shared.userModelOverrides[key]?.pricing != nil
    }

    /// Any base rate currently overridden in the sheet — so the "$0 until you set rates" warning
    /// clears the moment the user prices a rate, rather than lingering because the CATALOG is still
    /// empty for a model that has no catalog pricing.
    private var hasCurrentBaseOverride: Bool {
        editable.inputOverride != nil || editable.outputOverride != nil
            || editable.cacheReadOverride != nil || editable.cacheWriteOverride != nil
    }

    var body: some View {
        // The reference display, the field-seed defaults, and save all read the SAME load-time
        // catalog capture, so what the user sees is exactly what a Default rate saves as — even if a
        // background refresh moves the catalog while the sheet is open. (First frame before onAppear
        // shows "no pricing" briefly; harmless, and consistent with the other sheets' onAppear load.)
        let defaults = CatalogBaseDefaults(
            input: Self.perMillion(catalogAtLoad?.base.input),
            output: Self.perMillion(catalogAtLoad?.base.output),
            cacheRead: Self.perMillion(catalogAtLoad?.base.cacheRead),
            cacheWrite: Self.perMillion(catalogAtLoad?.base.cacheWrite))
        VStack(alignment: .leading, spacing: 16) {
            OverrideSheetHeader(title: "Pricing Override", subtitle: "\(providerID) — \(modelID)",
                                onCancel: { dismiss() }, onDone: { save(); dismiss() })
            PricingForm(editable: $editable, catalogDefaults: defaults, resetToken: resetToken,
                        noPricingKnown: catalogAtLoad?.base.hasAnyRate != true && !hasCurrentBaseOverride,
                        expandThresholds: $expandThresholds, expandService: $expandService,
                        expandExtended: $expandExtended)
            OverrideSheetFooter(
                resetTitle: "Clear Override",
                explanation: "Rates in USD per 1M tokens. Overriding a rate replaces just that rate; Clear Override reverts the whole model to catalog pricing.",
                resetDisabled: !hasPricingOverride,
                onReset: { clearOverride() })
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 660, minHeight: 460, idealHeight: 680)
        .onAppear { loadFromShared() }
        .onChange(of: editable) { _, newValue in
            // A fresh edit after Clear Override cancels the clear intent.
            if explicitlyCleared, !Self.isClearedShape(newValue) {
                DispatchQueue.main.async { explicitlyCleared = false }
            }
        }
    }

    private func loadFromShared() {
        let catalog = computeCatalogPricing()
        let resolved = resolvedPricing
        let userPricing = shared.userModelOverrides[key]?.pricing
        var result = EditablePricing()
        // A base rate is an OVERRIDE only when the stored value differs from the catalog default.
        result.inputOverride = Self.baseOverride(userPricing?.base.input, catalog?.base.input)
        result.outputOverride = Self.baseOverride(userPricing?.base.output, catalog?.base.output)
        result.cacheReadOverride = Self.baseOverride(userPricing?.base.cacheRead, catalog?.base.cacheRead)
        result.cacheWriteOverride = Self.baseOverride(userPricing?.base.cacheWrite, catalog?.base.cacheWrite)
        // Advanced tiers are carried from the RESOLVED pricing so a base-rate edit doesn't drop them.
        Self.applyAdvancedSeed(resolved, to: &result)
        catalogAtLoad = catalog
        resolvedAtLoad = resolved
        editable = result
        initialBuilt = Self.pricing(from: result, catalog: catalog, resolved: resolved)
        explicitlyCleared = false
        expandThresholds = !result.thresholdTiers.isEmpty
        expandService = !result.serviceTiers.isEmpty
        expandExtended = result.extendedCacheWrite != nil || !result.extendedThresholds.isEmpty
    }

    private func clearOverride() {
        // Base overrides go back to Default, but keep the advanced tiers seeded from the resolved
        // pricing: if the user changes their mind and re-authors a base rate, those catalog tiers
        // must not vanish. A Done while the clear intent still stands stores nil — a full revert.
        var cleared = EditablePricing()
        Self.applyAdvancedSeed(resolvedAtLoad, to: &cleared)
        editable = cleared
        explicitlyCleared = true
        resetToken += 1
    }

    private func save() {
        let built = Self.pricing(from: editable, catalog: catalogAtLoad, resolved: resolvedAtLoad)
        let pricingOverride: ModelPricing?
        if explicitlyCleared {
            pricingOverride = nil
        } else {
            guard built != initialBuilt else { return }
            pricingOverride = Self.isEmpty(built) ? nil : built
        }
        let existing = shared.userModelOverrides[key]
        let merged = ModelMetadataOverride(
            displayName: existing?.displayName,
            maxInputTokens: existing?.maxInputTokens,
            maxOutputTokens: existing?.maxOutputTokens,
            sizeLabel: existing?.sizeLabel,
            capabilities: existing?.capabilities,
            pricing: pricingOverride,
            supportsChatCompletions: existing?.supportsChatCompletions,
            behaviorFlags: existing?.behaviorFlags,
            hidden: existing?.hidden,
            isAvailable: existing?.isAvailable,
            isAccessDenied: existing?.isAccessDenied
        )
        shared.setUserModelOverride(providerID: providerID, modelID: modelID, override: merged)
    }

    // MARK: - Conversions (USD per 1M ⟷ per-token ModelPricing)

    private static func perMillion(_ perToken: Double?) -> Double? { perToken.map { $0 * 1_000_000 } }
    private static func perToken(_ perMillion: Double?) -> Double? { perMillion.map { $0 / 1_000_000 } }

    /// A stored base rate is an override only when it differs from the catalog default; equal values
    /// read back as "Default" so the control shows what the user actually changed. Returns per-1M.
    private static func baseOverride(_ stored: Double?, _ catalog: Double?) -> Double? {
        guard let stored, stored != catalog else { return nil }
        return perMillion(stored)
    }

    private static func editableRates(_ tier: PricingTier) -> EditableRates {
        EditableRates(input: perMillion(tier.input), output: perMillion(tier.output),
                      cacheRead: perMillion(tier.cacheRead), cacheWrite: perMillion(tier.cacheWrite))
    }

    private static func pricingTier(_ rates: EditableRates) -> PricingTier {
        PricingTier(input: perToken(rates.input), output: perToken(rates.output),
                    cacheRead: perToken(rates.cacheRead), cacheWrite: perToken(rates.cacheWrite))
    }

    /// A non-overridden base rate falls back to the catalog rate and, if that is unknown (compositions
    /// empty on a cached launch), to the resolved rate — never to nil, so overriding ONE rate can
    /// never wipe the others.
    private static func pricing(from editable: EditablePricing, catalog: ModelPricing?, resolved: ModelPricing?) -> ModelPricing {
        let base = PricingTier(
            input: perToken(editable.inputOverride) ?? catalog?.base.input ?? resolved?.base.input,
            output: perToken(editable.outputOverride) ?? catalog?.base.output ?? resolved?.base.output,
            cacheRead: perToken(editable.cacheReadOverride) ?? catalog?.base.cacheRead ?? resolved?.base.cacheRead,
            cacheWrite: perToken(editable.cacheWriteOverride) ?? catalog?.base.cacheWrite ?? resolved?.base.cacheWrite)
        let tiers = editable.thresholdTiers.compactMap { tier -> TokenThresholdTier? in
            guard let threshold = tier.threshold else { return nil }
            let rates = pricingTier(tier.rates)
            return rates.hasAnyRate ? TokenThresholdTier(tokenThreshold: threshold, rates: rates) : nil
        }
        var services: [String: PricingTier] = [:]
        for tier in editable.serviceTiers {
            let name = tier.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let rates = pricingTier(tier.rates)
            guard !name.isEmpty, rates.hasAnyRate else { continue }
            services[name] = rates
        }
        var extended: CacheWriteOverride?
        if let cacheWrite = perToken(editable.extendedCacheWrite) {
            // Sort ascending: ModelPricing.effectiveRates applies threshold overrides last-match-wins
            // WITHOUT sorting them, so an out-of-order entry would misprice.
            let overrides = editable.extendedThresholds
                .compactMap { entry -> TokenThresholdCacheWrite? in
                    guard let threshold = entry.threshold, let rate = perToken(entry.cacheWrite) else { return nil }
                    return TokenThresholdCacheWrite(tokenThreshold: threshold, cacheWrite: rate)
                }
                .sorted { $0.tokenThreshold < $1.tokenThreshold }
            extended = CacheWriteOverride(cacheWrite: cacheWrite, thresholdOverrides: overrides)
        }
        return ModelPricing(base: base, tokenThresholdTiers: tiers, serviceTiers: services, extendedCacheTier: extended)
    }

    private static func isEmpty(_ pricing: ModelPricing) -> Bool {
        !pricing.base.hasAnyRate && pricing.tokenThresholdTiers.isEmpty
            && pricing.serviceTiers.isEmpty && pricing.extendedCacheTier == nil
    }

    /// True when every BASE rate is at Default. The clear intent is cancelled only when the user
    /// re-authors a base rate; advanced tiers are seeded on clear (so they survive a re-author) and
    /// intentionally do NOT count toward this.
    private static func isClearedShape(_ e: EditablePricing) -> Bool {
        e.inputOverride == nil && e.outputOverride == nil
            && e.cacheReadOverride == nil && e.cacheWriteOverride == nil
    }

    private static func applyAdvancedSeed(_ resolved: ModelPricing?, to result: inout EditablePricing) {
        result.thresholdTiers = (resolved?.tokenThresholdTiers ?? []).map {
            EditableThresholdTier(threshold: $0.tokenThreshold, rates: editableRates($0.rates))
        }
        result.serviceTiers = (resolved?.serviceTiers ?? [:]).sorted { $0.key < $1.key }.map {
            EditableServiceTier(name: $0.key, rates: editableRates($0.value))
        }
        result.extendedCacheWrite = perMillion(resolved?.extendedCacheTier?.cacheWrite)
        result.extendedThresholds = (resolved?.extendedCacheTier?.thresholdOverrides ?? []).map {
            EditableCacheThreshold(threshold: $0.tokenThreshold, cacheWrite: perMillion($0.cacheWrite))
        }
    }
}

// MARK: - Editable model

/// USD-per-1M working copy of a `PricingTier`. `nil` = no rate.
private struct EditableRates: Equatable {
    var input: Double?
    var output: Double?
    var cacheRead: Double?
    var cacheWrite: Double?
}

private struct EditableThresholdTier: Identifiable, Equatable {
    let id = UUID()
    var threshold: Int?
    var rates = EditableRates()
}

private struct EditableServiceTier: Identifiable, Equatable {
    let id = UUID()
    var name: String = ""
    var rates = EditableRates()
}

private struct EditableCacheThreshold: Identifiable, Equatable {
    let id = UUID()
    var threshold: Int?
    var cacheWrite: Double?
}

/// Base rates carry per-rate OVERRIDES (USD per 1M); `nil` = use the catalog default. Advanced tiers
/// are carried whole from the resolved pricing.
private struct EditablePricing: Equatable {
    var inputOverride: Double?
    var outputOverride: Double?
    var cacheReadOverride: Double?
    var cacheWriteOverride: Double?
    var thresholdTiers: [EditableThresholdTier] = []
    var serviceTiers: [EditableServiceTier] = []
    var extendedCacheWrite: Double?
    var extendedThresholds: [EditableCacheThreshold] = []
}

/// Catalog base rates (USD per 1M) shown as the reference each base-rate control defaults to.
private struct CatalogBaseDefaults: Equatable {
    let input: Double?
    let output: Double?
    let cacheRead: Double?
    let cacheWrite: Double?
}

// MARK: - Form

private struct PricingForm: View {
    @Binding var editable: EditablePricing
    let catalogDefaults: CatalogBaseDefaults
    let resetToken: Int
    let noPricingKnown: Bool
    @Binding var expandThresholds: Bool
    @Binding var expandService: Bool
    @Binding var expandExtended: Bool

    var body: some View {
        Form {
            Section("Base rates — USD per 1M tokens") {
                if noPricingKnown {
                    Label("No catalog pricing — cost estimates run at $0 until you set rates here.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                PricingRateRow(label: "Input", catalogDefault: catalogDefaults.input,
                               override: $editable.inputOverride, resetToken: resetToken)
                PricingRateRow(label: "Output", catalogDefault: catalogDefaults.output,
                               override: $editable.outputOverride, resetToken: resetToken)
                PricingRateRow(label: "Cache read", catalogDefault: catalogDefaults.cacheRead,
                               override: $editable.cacheReadOverride, resetToken: resetToken)
                PricingRateRow(label: "Cache write", catalogDefault: catalogDefaults.cacheWrite,
                               override: $editable.cacheWriteOverride, resetToken: resetToken)
            }
            Section("Advanced") {
                ThresholdTiersDisclosure(tiers: $editable.thresholdTiers, isExpanded: $expandThresholds)
                ServiceTiersDisclosure(tiers: $editable.serviceTiers, isExpanded: $expandService)
                ExtendedCacheDisclosure(cacheWrite: $editable.extendedCacheWrite,
                                        thresholds: $editable.extendedThresholds, isExpanded: $expandExtended)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ThresholdTiersDisclosure: View {
    @Binding var tiers: [EditableThresholdTier]
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(
            isExpanded: $isExpanded,
            content: {
                ForEach($tiers) { $tier in
                    ThresholdTierRow(tier: $tier, onDelete: { tiers.removeAll { $0.id == tier.id } })
                }
                Button("Add tier") { tiers.append(EditableThresholdTier()); isExpanded = true }
                    .controlSize(.small)
            },
            label: { Text("Context-length tiers (\(tiers.count)) — rates above a token threshold") })
    }
}

private struct ServiceTiersDisclosure: View {
    @Binding var tiers: [EditableServiceTier]
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(
            isExpanded: $isExpanded,
            content: {
                ForEach($tiers) { $tier in
                    ServiceTierRow(tier: $tier, onDelete: { tiers.removeAll { $0.id == tier.id } })
                }
                Button("Add service tier") { tiers.append(EditableServiceTier()); isExpanded = true }
                    .controlSize(.small)
            },
            label: { Text("Service tiers (\(tiers.count)) — e.g. priority, flex, batch") })
    }
}

private struct ExtendedCacheDisclosure: View {
    @Binding var cacheWrite: Double?
    @Binding var thresholds: [EditableCacheThreshold]
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(
            isExpanded: $isExpanded,
            content: {
                RateField(label: "Cache write (extended TTL)", perMillion: $cacheWrite)
                ForEach($thresholds) { $entry in
                    ExtendedThresholdRow(entry: $entry, onDelete: { thresholds.removeAll { $0.id == entry.id } })
                }
                Button("Add threshold override") { thresholds.append(EditableCacheThreshold()) }
                    .controlSize(.small)
            },
            label: { Text("Extended cache — long-TTL cache-write rate") })
    }
}

// MARK: - Rows

/// A base rate: the catalog rate as a reference in the header, edited through the shared
/// Default/Override control so overriding one rate never disturbs the others.
private struct PricingRateRow: View {
    let label: String
    let catalogDefault: Double?
    @Binding var override: Double?
    let resetToken: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.headline)
                Spacer()
                Text("Catalog: \(catalogDefault.map { OverrideValueParsing.usdLabel($0) } ?? "none")")
                    .font(.caption.monospaced())
                    .foregroundStyle(catalogDefault == nil ? AnyShapeStyle(HierarchicalShapeStyle.tertiary)
                                                           : AnyShapeStyle(HierarchicalShapeStyle.secondary))
            }
            OverrideValueControl(override: $override, defaultValue: catalogDefault,
                                 draftText: OverrideValueParsing.usdDraft,
                                 format: OverrideValueParsing.usdLabel,
                                 parse: OverrideValueParsing.usdPerMillion,
                                 resetToken: resetToken)
        }
    }
}

/// One advanced rate: label on the left, a right-aligned USD-per-1M number field. No placeholder
/// clutter; a fixed width keeps the advanced fields aligned.
private struct RateField: View {
    let label: String
    @Binding var perMillion: Double?

    var body: some View {
        LabeledContent(label) {
            TextField("", value: $perMillion, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct RateFieldsGroup: View {
    @Binding var rates: EditableRates

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RateField(label: "Input", perMillion: $rates.input)
            RateField(label: "Output", perMillion: $rates.output)
            RateField(label: "Cache read", perMillion: $rates.cacheRead)
            RateField(label: "Cache write", perMillion: $rates.cacheWrite)
        }
    }
}

private struct ThresholdTierRow: View {
    @Binding var tier: EditableThresholdTier
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Above").font(.subheadline)
                TextField("tokens", value: $tier.threshold, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                Text("tokens").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            RateFieldsGroup(rates: $tier.rates)
        }
        .padding(.vertical, 2)
    }
}

private struct ServiceTierRow: View {
    @Binding var tier: EditableServiceTier
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("tier name", text: $tier.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                Spacer()
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            RateFieldsGroup(rates: $tier.rates)
        }
        .padding(.vertical, 2)
    }
}

private struct ExtendedThresholdRow: View {
    @Binding var entry: EditableCacheThreshold
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text("Above").font(.caption)
            TextField("tokens", value: $entry.threshold, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
            Text("→ cache write").font(.caption).foregroundStyle(.secondary)
            TextField("", value: $entry.cacheWrite, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
            Spacer()
            Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
        }
    }
}
