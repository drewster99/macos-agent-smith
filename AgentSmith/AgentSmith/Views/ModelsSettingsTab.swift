import AppKit
import SwiftUI
import UniformTypeIdentifiers
import AgentSmithKit
import SwiftLLMKit

/// Settings → Models tab.
///
/// Extracted from `SettingsView` so its `@Observable` dependency tracking is scoped to the model
/// catalog alone: cost-board / usage / speech ticks on `SharedAppState` (read by the other tabs)
/// no longer invalidate this view. The filtered + sorted list is cached in `displayed` and
/// recomputed only when its inputs change — filter text, sort order, catalog, or provider set —
/// never on every body evaluation. Rows read per-model metadata (`behaviorFlags`, `pricing`,
/// `capabilities`) directly off the `ModelInfo` they already hold, so no row performs a
/// full-catalog lookup.
struct ModelsSettingsTab: View {
    @Bindable var shared: SharedAppState
    let sessionManager: SessionManager

    @State private var filterText = ""
    @State private var sortOrder: ModelSortOrder = .provider

    /// The filtered + sorted catalog, cached so the sort runs on input changes (below) rather than
    /// on every render. `nil` means "not yet computed" — distinct from `[]` ("computed, nothing to
    /// show") — so the first frame renders no list rather than briefly flashing the empty-catalog
    /// message before `recompute()` runs.
    @State private var displayed: [ProviderModel]?

    @State private var editingFlagsFor: ModelEditTarget?
    @State private var editingCapabilitiesFor: ModelEditTarget?
    @State private var editingPricingFor: ModelEditTarget?
    @State private var exportError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Models")
                    .font(AppFonts.sectionHeader)
                Spacer()
            }

            ModelCatalogSection(
                providersEmpty: shared.llmKit.providers.isEmpty,
                filterText: $filterText,
                sortOrder: $sortOrder,
                displayed: displayed,
                onEditFlags: { editingFlagsFor = $0 },
                onEditCapabilities: { editingCapabilitiesFor = $0 },
                onEditPricing: { editingPricingFor = $0 }
            )

            Divider().padding(.vertical, 4)

            ModelsActionsRow(
                isRefreshing: shared.llmKit.isRefreshing,
                onRefresh: { Task { await shared.llmKit.forceRefresh() } },
                onExport: exportDefaults
            )

            ModelsRefreshErrorList(errors: shared.llmKit.refreshErrors)
        }
        .task { recompute() }
        .onChange(of: filterText) { recompute() }
        .onChange(of: sortOrder) { recompute() }
        .onChange(of: shared.llmKit.models) { recompute() }
        .onChange(of: shared.llmKit.providers) { recompute() }
        .sheet(item: $editingFlagsFor) { target in
            BehaviorFlagsEditorSheet(shared: shared, providerID: target.providerID, modelID: target.modelID)
        }
        .sheet(item: $editingCapabilitiesFor) { target in
            CapabilitiesEditorSheet(shared: shared, providerID: target.providerID, modelID: target.modelID)
        }
        .sheet(item: $editingPricingFor) { target in
            PricingEditorSheet(shared: shared, providerID: target.providerID, modelID: target.modelID)
        }
        .alert("Export Error", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        ), actions: {
            Button("OK") { exportError = nil }
        }, message: {
            Text(exportError ?? "")
        })
    }

    /// Rebuilds `displayed` from the current catalog, filter text, and sort order. Called from the
    /// lifecycle/`onChange` hooks above — never from `body` — so the O(n log n) locale-aware sort
    /// runs on real input changes, not on every render pass.
    private func recompute() {
        var pairs: [ProviderModel] = []
        for provider in shared.llmKit.providers {
            for model in shared.llmKit.models(for: provider.id) {
                pairs.append(ProviderModel(provider: provider, model: model))
            }
        }
        let query = filterText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            pairs = pairs.filter { pair in
                pair.provider.name.localizedCaseInsensitiveContains(query)
                    || pair.model.modelID.localizedCaseInsensitiveContains(query)
                    || pair.model.displayName.localizedCaseInsensitiveContains(query)
            }
        }
        switch sortOrder {
        case .provider:
            pairs.sort { lhs, rhs in
                let byProvider = lhs.provider.name.localizedCaseInsensitiveCompare(rhs.provider.name)
                if byProvider != .orderedSame {
                    return byProvider == .orderedAscending
                }
                return lhs.model.displayName.localizedCaseInsensitiveCompare(rhs.model.displayName) == .orderedAscending
            }
        case .model:
            pairs.sort { $0.model.displayName.localizedCaseInsensitiveCompare($1.model.displayName) == .orderedAscending }
        }
        displayed = pairs
    }

    private func exportDefaults() {
        // Per-session assignments/tunings are exported from the first session in the list
        // (or fall back to shared defaults if no session exists yet). The resulting
        // defaults.json is still a single flat blob — it doesn't capture per-session divergence.
        let firstVM = sessionManager.sessions.first.flatMap { sessionManager.viewModel(for: $0.id) }
        let assignments = firstVM?.agentAssignments ?? shared.defaultAgentAssignments
        let pollIntervals = firstVM?.agentPollIntervals ?? shared.defaultAgentPollIntervals
        let maxToolCalls = firstVM?.agentMaxToolCalls ?? shared.defaultAgentMaxToolCalls
        let debounceIntervals = firstVM?.agentMessageDebounceIntervals ?? shared.defaultAgentMessageDebounceIntervals

        let data: Data
        do {
            data = try DefaultsExporter.exportCurrentSettings(
                llmKit: shared.llmKit,
                agentAssignments: assignments,
                pollIntervals: pollIntervals,
                maxToolCalls: maxToolCalls,
                messageDebounceIntervals: debounceIntervals,
                speechController: shared.speechController
            )
        } catch {
            exportError = error.localizedDescription
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "defaults.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            exportError = "Failed to write file: \(error.localizedDescription)"
        }
    }
}

/// Display order for the Models list.
private enum ModelSortOrder: String, CaseIterable, Identifiable {
    case provider = "Provider"
    case model = "Model"
    var id: String { rawValue }
}

/// One (provider, model) pair — the unit the Models tab lists and edits. The config pool was
/// retired 2026-07-31, so this tab edits per-model metadata (flags / capabilities / pricing)
/// keyed on `(providerID, modelID)`, not `ModelConfiguration` objects.
private struct ProviderModel: Identifiable {
    let provider: ModelProvider
    let model: ModelInfo
    var id: String { "\(provider.id)/\(model.modelID)" }
}

/// (providerID, modelID) of the model whose per-model editor sheet is open.
private struct ModelEditTarget: Identifiable {
    let providerID: String
    let modelID: String
    var id: String { "\(providerID)/\(modelID)" }
}

/// The filter/sort controls plus the model list (or the appropriate empty-state message).
private struct ModelCatalogSection: View {
    let providersEmpty: Bool
    @Binding var filterText: String
    @Binding var sortOrder: ModelSortOrder
    let displayed: [ProviderModel]?
    let onEditFlags: (ModelEditTarget) -> Void
    let onEditCapabilities: (ModelEditTarget) -> Void
    let onEditPricing: (ModelEditTarget) -> Void

    var body: some View {
        if providersEmpty {
            ModelsCenteredMessage(text: "No providers configured. Add one in Settings → Providers.")
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    TextField("Filter by provider or model", text: $filterText)
                        .textFieldStyle(.roundedBorder)
                    Picker("Sort", selection: $sortOrder) {
                        ForEach(ModelSortOrder.allCases) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                    .fixedSize()
                }
                ModelCatalogList(
                    filterText: filterText,
                    displayed: displayed,
                    onEditFlags: onEditFlags,
                    onEditCapabilities: onEditCapabilities,
                    onEditPricing: onEditPricing
                )
            }
        }
    }
}

/// The eager list of matching model rows, or the empty-state message when nothing matches.
///
/// Rendering stays non-lazy per the project's SwiftUI rules; the surrounding view keeps the row
/// data static during scroll (no observed state changes while scrolling) so the eager tree is not
/// rebuilt on scroll.
private struct ModelCatalogList: View {
    let filterText: String
    let displayed: [ProviderModel]?
    let onEditFlags: (ModelEditTarget) -> Void
    let onEditCapabilities: (ModelEditTarget) -> Void
    let onEditPricing: (ModelEditTarget) -> Void

    var body: some View {
        if let rows = displayed {
            if rows.isEmpty {
                ModelsCenteredMessage(text: filterText.trimmingCharacters(in: .whitespaces).isEmpty
                    ? "No models cached. Use Refresh Models below."
                    : "No models match \u{201C}\(filterText)\u{201D}.")
            } else {
                ForEach(rows) { pair in
                    ModelRow(
                        provider: pair.provider,
                        model: pair.model,
                        onEditFlags: onEditFlags,
                        onEditCapabilities: onEditCapabilities,
                        onEditPricing: onEditPricing
                    )
                }
            }
        }
    }
}

private struct ModelsCenteredMessage: View {
    let text: String
    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 20)
    }
}

/// One model's row: name, provenance/metadata line, resolved capabilities and behavior flags, and
/// the three per-model editor buttons. Reads all metadata off the passed-in `ModelInfo` — no
/// catalog lookup — and takes plain value types so it observes nothing and re-renders only when its
/// own inputs change.
private struct ModelRow: View {
    let provider: ModelProvider
    let model: ModelInfo
    let onEditFlags: (ModelEditTarget) -> Void
    let onEditCapabilities: (ModelEditTarget) -> Void
    let onEditPricing: (ModelEditTarget) -> Void

    private var target: ModelEditTarget {
        ModelEditTarget(providerID: provider.id, modelID: model.modelID)
    }

    var body: some View {
        GroupBox {
            HStack {
                ModelRowInfo(provider: provider, model: model)
                Spacer()
                Button("Flags") { onEditFlags(target) }
                    .buttonStyle(.borderless)
                    .help("Edit per-model behavior flags (GLM salvage, max_completion_tokens, parallel tools)")
                Button("Caps") { onEditCapabilities(target) }
                    .buttonStyle(.borderless)
                    .help("Override per-model capability flags (vision, tool use, …) when the catalog is wrong")
                Button("Pricing") { onEditPricing(target) }
                    .buttonStyle(.borderless)
                    .help("View resolved pricing and override input/output rates (USD per 1M tokens)")
            }
            .padding(4)
        }
    }
}

/// The left-hand info column of a model row.
private struct ModelRowInfo: View {
    let provider: ModelProvider
    let model: ModelInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(model.displayName)
                    .font(.headline)
                if model.isNew {
                    Text("New")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
            ModelRowMetadataLine(provider: provider, model: model)
            if !model.capabilities.enabledLabels.isEmpty {
                Text(model.capabilities.enabledLabels.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !model.behaviorFlags.isAllDefault {
                ModelBehaviorFlagChips(flags: model.behaviorFlags)
            }
        }
    }
}

/// Provider chip, model ID, token limits, and pricing summary.
private struct ModelRowMetadataLine: View {
    let provider: ModelProvider
    let model: ModelInfo

    var body: some View {
        HStack(spacing: 8) {
            Text(provider.name)
                .font(.caption)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Text(model.modelID)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let maxOut = model.maxOutputTokens {
                Text("max \(formatTokenCount(maxOut))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let maxIn = model.maxInputTokens {
                Text("ctx \(formatTokenCount(maxIn))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let pricing = model.pricing, pricing.base.hasAnyRate {
                Text(PricingFormatter.summary(pricing))
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
    }
}

/// Read-only chips for the model's non-default behavior flags. Resolved value lives on the
/// `ModelInfo` (merged from bundled provider-defaults, bundled per-model entries, LiteLLM, and
/// user overrides); editing flows through the Flags editor sheet, not this row.
private struct ModelBehaviorFlagChips: View {
    let flags: BehaviorFlags

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "slider.horizontal.below.rectangle")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            ForEach(flags.displayLabels, id: \.self) { label in
                Text(label)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(AppColors.flagChipBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(AppColors.flagChipForeground)
            }
        }
        .help("Per-model behavior flags resolved from bundled defaults + user overrides. Edit via the Flags button.")
    }
}

/// Refresh + Export row beneath the model list.
private struct ModelsActionsRow: View {
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onExport: () -> Void

    var body: some View {
        HStack {
            Button("Refresh Models", action: onRefresh)
                .disabled(isRefreshing)
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
            Button("Export Current Settings as Defaults JSON\u{2026}", action: onExport)
        }
    }
}

/// Per-provider refresh errors, if any.
private struct ModelsRefreshErrorList: View {
    let errors: [String: String]

    var body: some View {
        if !errors.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(errors.sorted(by: { $0.key < $1.key }), id: \.key) { provider, error in
                    Label("\(provider): \(error)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }
}
