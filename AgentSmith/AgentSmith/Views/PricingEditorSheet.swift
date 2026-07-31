import SwiftUI
import SwiftLLMKit

/// Per-(provider, model) pricing override editor — the third twin alongside `BehaviorFlagsEditorSheet`
/// and `CapabilitiesEditorSheet`, now covering the WHOLE `ModelPricing` model, not just base
/// input/output: cache read/write, context-length threshold tiers, named service tiers, and the
/// extended-cache write rate. (Reasoning/thinking has no rate of its own — every current provider
/// bills it as output tokens.)
///
/// Fields are seeded from the RESOLVED pricing (catalog + any existing override) so nothing is
/// hidden and cache/tier rates aren't silently wiped by editing input/output. Rates are entered in
/// USD per **1M tokens** (the industry quoting unit); storage stays USD per single token, like all
/// of `ModelPricing`. Saving force-replaces this model's pricing; Clear Override reverts to catalog
/// pricing. A no-op visit (nothing changed) writes nothing, so opening the sheet never pins pricing.
struct PricingEditorSheet: View {
    @Bindable var shared: SharedAppState
    let providerID: String
    let modelID: String

    @Environment(\.dismiss) private var dismiss

    @State private var editable = EditablePricing()
    /// The pricing built from the seed, so Done can no-op when nothing changed (never pinning a
    /// catalog-priced model just because the sheet was opened and closed).
    @State private var initialBuilt: ModelPricing = ModelPricing()
    @State private var expandThresholds = false
    @State private var expandService = false
    @State private var expandExtended = false

    private var key: String { "\(providerID)/\(modelID)" }

    private var resolvedPricing: ModelPricing? {
        shared.llmKit.modelInfo(providerID: providerID, modelID: modelID)?.pricing
    }

    private var hasPricingOverride: Bool {
        shared.userModelOverrides[key]?.pricing != nil
    }

    private var noPricingKnown: Bool {
        resolvedPricing?.base.hasAnyRate != true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            OverrideSheetHeader(title: "Pricing Override", subtitle: "\(providerID) — \(modelID)",
                                onCancel: { dismiss() }, onDone: { save(); dismiss() })
            PricingForm(editable: $editable, noPricingKnown: noPricingKnown,
                        expandThresholds: $expandThresholds, expandService: $expandService,
                        expandExtended: $expandExtended)
            OverrideSheetFooter(
                resetTitle: "Clear Override",
                explanation: "Rates in USD per 1M tokens. Saving replaces the catalog's pricing for this model; Clear Override reverts to catalog pricing.",
                resetDisabled: !hasPricingOverride,
                onReset: { editable = EditablePricing() })
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 660, minHeight: 460, idealHeight: 680)
        .onAppear { loadFromShared() }
    }

    private func loadFromShared() {
        editable = Self.editable(from: resolvedPricing)
        initialBuilt = Self.pricing(from: editable)
        expandThresholds = !editable.thresholdTiers.isEmpty
        expandService = !editable.serviceTiers.isEmpty
        expandExtended = editable.extendedCacheWrite != nil || !editable.extendedThresholds.isEmpty
    }

    /// Writes the edited pricing as the user override — force-replacing the catalog's pricing.
    /// Unchanged from the seed → no write. Emptied → the override's pricing is cleared (nil), which
    /// reverts to catalog pricing. Every non-pricing field on the existing override is preserved.
    private func save() {
        let built = Self.pricing(from: editable)
        guard built != initialBuilt else { return }
        let pricingOverride: ModelPricing? = Self.isEmpty(built) ? nil : built
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

    private static func editableRates(_ tier: PricingTier) -> EditableRates {
        EditableRates(input: perMillion(tier.input), output: perMillion(tier.output),
                      cacheRead: perMillion(tier.cacheRead), cacheWrite: perMillion(tier.cacheWrite))
    }

    private static func pricingTier(_ rates: EditableRates) -> PricingTier {
        PricingTier(input: perToken(rates.input), output: perToken(rates.output),
                    cacheRead: perToken(rates.cacheRead), cacheWrite: perToken(rates.cacheWrite))
    }

    private static func editable(from pricing: ModelPricing?) -> EditablePricing {
        var result = EditablePricing()
        result.base = editableRates(pricing?.base ?? PricingTier())
        result.thresholdTiers = (pricing?.tokenThresholdTiers ?? []).map {
            EditableThresholdTier(threshold: $0.tokenThreshold, rates: editableRates($0.rates))
        }
        result.serviceTiers = (pricing?.serviceTiers ?? [:]).sorted { $0.key < $1.key }.map {
            EditableServiceTier(name: $0.key, rates: editableRates($0.value))
        }
        result.extendedCacheWrite = perMillion(pricing?.extendedCacheTier?.cacheWrite)
        result.extendedThresholds = (pricing?.extendedCacheTier?.thresholdOverrides ?? []).map {
            EditableCacheThreshold(threshold: $0.tokenThreshold, cacheWrite: perMillion($0.cacheWrite))
        }
        return result
    }

    private static func pricing(from editable: EditablePricing) -> ModelPricing {
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
            let overrides = editable.extendedThresholds.compactMap { entry -> TokenThresholdCacheWrite? in
                guard let threshold = entry.threshold, let rate = perToken(entry.cacheWrite) else { return nil }
                return TokenThresholdCacheWrite(tokenThreshold: threshold, cacheWrite: rate)
            }
            extended = CacheWriteOverride(cacheWrite: cacheWrite, thresholdOverrides: overrides)
        }
        return ModelPricing(base: pricingTier(editable.base), tokenThresholdTiers: tiers,
                            serviceTiers: services, extendedCacheTier: extended)
    }

    private static func isEmpty(_ pricing: ModelPricing) -> Bool {
        !pricing.base.hasAnyRate && pricing.tokenThresholdTiers.isEmpty
            && pricing.serviceTiers.isEmpty && pricing.extendedCacheTier == nil
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

private struct EditablePricing: Equatable {
    var base = EditableRates()
    var thresholdTiers: [EditableThresholdTier] = []
    var serviceTiers: [EditableServiceTier] = []
    var extendedCacheWrite: Double?
    var extendedThresholds: [EditableCacheThreshold] = []
}

// MARK: - Form

private struct PricingForm: View {
    @Binding var editable: EditablePricing
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
                RateField(label: "Input", perMillion: $editable.base.input, placeholder: "e.g. 3.00")
                RateField(label: "Output", perMillion: $editable.base.output, placeholder: "e.g. 15.00")
                RateField(label: "Cache read", perMillion: $editable.base.cacheRead, placeholder: "e.g. 0.30")
                RateField(label: "Cache write", perMillion: $editable.base.cacheWrite, placeholder: "e.g. 3.75")
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
                RateField(label: "Cache write (extended TTL)", perMillion: $cacheWrite, placeholder: "e.g. 6.00")
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

/// One rate: label on the left, a right-aligned USD-per-1M number field.
private struct RateField: View {
    let label: String
    @Binding var perMillion: Double?
    var placeholder: String = "—"

    var body: some View {
        LabeledContent(label) {
            TextField(placeholder, value: $perMillion, format: .number)
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
                TextField("tokens, e.g. 200000", value: $tier.threshold, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
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
                TextField("tier name, e.g. priority", text: $tier.name)
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
            TextField("per 1M", value: $entry.cacheWrite, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)
            Spacer()
            Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
        }
    }
}
