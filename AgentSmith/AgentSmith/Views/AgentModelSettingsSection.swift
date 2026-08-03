import SwiftUI
import SwiftLLMKit
import AgentSmithKit

/// Agent-centric model picker — choose the `(provider, model)` this role runs.
///
/// Mounted at the top of `AgentConfigSheet` (the gear-icon sheet on each agent card).
/// The user picks a model from a single dropdown sectioned by provider; the choice is written
/// straight to `viewModel.agentAssignments[role]` as a ``ModelAssignment``. The shared-config
/// pool and its clone-on-edit / UUID indirection were retired 2026-07-31 — there is no longer a
/// `ModelConfiguration` object to own per role.
///
/// Runtime tuning (temperature, token ceilings, thinking, effort) is a separate per-`(role, model)`
/// override, edited just below by ``RoleModelConfigOverrideEditor`` and resolved fresh against the
/// model's live facts when providers are (re)built.
struct AgentModelSettingsSection: View {
    @Bindable var viewModel: AppViewModel
    let role: AgentRole

    @State private var providerID: String = ""
    @State private var modelID: String = ""

    private var llmKit: LLMKitManager { viewModel.shared.llmKit }

    private var selectedProvider: ModelProvider? {
        llmKit.providers.first { $0.id == providerID }
    }

    private var selectedModelInfo: ModelInfo? {
        llmKit.modelInfo(providerID: providerID, modelID: modelID)
    }

    /// All configured providers, sorted alphabetically. Every provider is shown (even one whose
    /// model fetch hasn't run) with a refresh affordance, so a user can recover without leaving
    /// the sheet.
    private var sortedProviders: [ModelProvider] {
        llmKit.providers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Model")
                    .font(AppFonts.inspectorLabel.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            modelDropdown()

            if let info = selectedModelInfo {
                modelInfoBar(for: info)
                effectiveSettingsBar(for: info)
            } else if !modelID.isEmpty {
                Text("Model '\(modelID)' not found in the catalog. Refresh models from the provider's submenu above.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if !modelID.isEmpty, !providerID.isEmpty {
                Divider().padding(.vertical, 2)
                RoleModelConfigOverrideEditor(shared: viewModel.shared, role: role,
                                              providerID: providerID, modelID: modelID)
                    // Remount on model change so the editor reloads that model's stored override
                    // (its state loads once in onAppear).
                    .id("\(providerID)/\(modelID)")
            }
        }
        .onAppear { loadFromViewModel() }
        // Reflect external mutations of this role's assignment (undo, a change made in another
        // window) back into the local drafts.
        .onChange(of: viewModel.agentAssignments[role]) { _, newValue in
            guard let newValue else { return }
            providerID = newValue.providerID
            modelID = newValue.modelID
        }
    }

    /// Human-readable summary of the current selection for the dropdown's closed-state label.
    /// Leads with the model id (the part the user actually picks per agent) and trails with the
    /// provider name for disambiguation. Falls back to a hint when nothing is selected yet.
    private var menuLabelText: String {
        let providerName = selectedProvider?.name
        if modelID.isEmpty {
            return providerName.map { "Select a model… (\($0))" } ?? "Select a model…"
        }
        if let providerName {
            return "\(modelID)  ·  \(providerName)"
        }
        return modelID
    }

    // MARK: - Model dropdown (hierarchical: provider → models submenu)

    @ViewBuilder
    private func modelDropdown() -> some View {
        Menu(content: {
            if sortedProviders.isEmpty {
                Text("No providers configured. Add one in Settings → Providers.")
            } else {
                ForEach(sortedProviders) { provider in
                    providerSubmenu(for: provider)
                }
            }
        }, label: {
            HStack {
                Text(menuLabelText)
                    .foregroundStyle(modelID.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(AppColors.subtleRowBackgroundLift)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        })
        .menuStyle(.borderlessButton)
    }

    /// One provider's submenu in the model dropdown. Providers with a populated catalog get their
    /// model list. Providers with an empty catalog get a single "Refresh" action and a warning
    /// label so the user can pull models without leaving the sheet. A prior refresh error (from
    /// `llmKit.refreshErrors`) is shown inline so the failure mode is visible.
    @ViewBuilder
    private func providerSubmenu(for provider: ModelProvider) -> some View {
        // The role's qualifying models for this provider, via the shared `availableModels(role)` filter
        // (tri-state — only a model KNOWN to fail is dropped), minus hidden ones. No "keep the current
        // selection" escape hatch: a model that no longer qualifies (or no longer exists) is simply not
        // offered, and the config gate hard-fails until a valid one is picked.
        let providerModels = llmKit.availableModels(role)
            .filter { $0.providerID == provider.id && $0.hidden != true }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        let refreshError = llmKit.refreshErrors[provider.name]
        let isEmpty = providerModels.isEmpty

        Menu(
            content: {
                if isEmpty {
                    if let refreshError {
                        Text("Last refresh failed: \(refreshError)")
                    } else {
                        Text("No models available for \(role.displayName).")
                    }
                    Button("Refresh \(provider.name)") {
                        refreshProvider(provider)
                    }
                    .disabled(llmKit.isRefreshing)
                } else {
                    ForEach(providerModels) { model in
                        Button(
                            action: { selectModel(provider: provider, model: model) },
                            label: { modelMenuLabel(for: model) }
                        )
                    }
                    Divider()
                    Button("Refresh \(provider.name)") {
                        refreshProvider(provider)
                    }
                    .disabled(llmKit.isRefreshing)
                }
            },
            label: {
                HStack(spacing: 4) {
                    Text(provider.name)
                    if isEmpty || refreshError != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
        )
    }

    /// Kicks off a per-provider model refresh. `refreshModels(forProviderID:)` sets
    /// `llmKit.isRefreshing = true` for the duration, which the Refresh buttons key off via
    /// `.disabled(llmKit.isRefreshing)` so double-taps are prevented.
    private func refreshProvider(_ provider: ModelProvider) {
        let providerID = provider.id
        Task { @MainActor in
            await llmKit.refreshModels(forProviderID: providerID)
        }
    }

    private func modelMenuLabel(for model: ModelInfo) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(model.displayName)
                HStack(spacing: 6) {
                    if let size = model.sizeLabel {
                        Text(size).foregroundStyle(.secondary)
                    }
                    if let quant = model.quantizationLabel {
                        Text(quant).foregroundStyle(.secondary)
                    }
                    if !model.capabilities.enabledLabels.isEmpty {
                        Text(model.capabilities.enabledLabels.joined(separator: ", "))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
            Spacer()
            if model.isNew {
                Text("New")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
        }
    }

    // MARK: - Model info bar

    private func modelInfoBar(for info: ModelInfo) -> some View {
        // A wrapping flow so the chips ride to subsequent rows when the sheet is narrow rather
        // than truncating into "Max ou…", "Conte…", etc.
        WrappingHStack(spacing: 8, lineSpacing: 4) {
            if info.isDeprecated {
                Text("Deprecated")
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(AppColors.warningRowBackground)
                    .foregroundStyle(.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            if let maxOut = info.maxOutputTokens {
                Text("Max output: \(formatTokenCount(maxOut))")
                    .foregroundStyle(.secondary)
            }
            if let maxIn = info.maxInputTokens {
                Text("Context: \(formatTokenCount(maxIn))")
                    .foregroundStyle(.secondary)
            }
            ForEach(info.capabilities.enabledLabels, id: \.self) { label in
                Text(label)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            if let priceText = pricingText(for: info) {
                Text(priceText)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            let value = Double(count) / 1_000_000.0
            let formatted = String(format: "%.1f", value)
            let label = formatted.hasSuffix(".0") ? String(formatted.dropLast(2)) : formatted
            return "\(label)M"
        } else if count >= 1_000 {
            return "\(count / 1_000)K"
        }
        return "\(count)"
    }

    /// Model pricing as a compact "$in · $out / 1M" chip, or nil when the model has no rates. Rates
    /// are stored USD-per-token; the display converts to per-1M (the app's convention).
    private func pricingText(for info: ModelInfo) -> String? {
        guard let tier = info.pricing?.base, tier.hasAnyRate else { return nil }
        let parts = [
            tier.input.map { "$\(formatUSD($0 * 1_000_000)) in" },
            tier.output.map { "$\(formatUSD($0 * 1_000_000)) out" }
        ].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ") + " / 1M"
    }

    private func formatUSD(_ value: Double) -> String {
        value < 1 ? String(format: "%.3f", value) : String(format: "%.2f", value)
    }

    // MARK: - Effective (resolved) settings

    /// A read-only summary of the RESOLVED per-(role, model) runtime settings — what this role will
    /// actually run with (the override edited below, resolved against the model's facts). Surfaces the
    /// knobs that are NOT model facts: temperature, thinking, effort, and any token ceilings overridden
    /// below the model's own maxima.
    private func effectiveSettingsBar(for info: ModelInfo) -> some View {
        let override = viewModel.shared.roleModelConfigOverride(role: role, providerID: providerID, modelID: modelID)
        let resolved = override.resolved(against: info, name: info.displayName)
        return WrappingHStack(spacing: 8, lineSpacing: 4) {
            Text("Effective:").foregroundStyle(.tertiary)
            Text(resolved.temperature.map { "temp \(String(format: "%.2f", $0))" } ?? "temp default")
                .foregroundStyle(.secondary)
            Text(resolved.thinkingBudget.map { "thinking \(formatTokenCount($0))" } ?? "thinking off")
                .foregroundStyle(.secondary)
            if let effort = resolved.effort, !effort.isEmpty {
                Text("effort \(effort)").foregroundStyle(.secondary)
            }
            if let reasoningEffort = resolved.reasoningEffort, !reasoningEffort.isEmpty {
                Text("reasoning \(reasoningEffort)").foregroundStyle(.secondary)
            }
            // Show a cap only when the user explicitly overrode it (keyed on the override's presence,
            // not resolved-vs-model — the model may report no max, which the resolved fallback hides).
            if let cap = override.maxOutputTokens {
                Text("output cap \(formatTokenCount(cap))").foregroundStyle(.secondary)
            }
            if let cap = override.maxContextTokens {
                Text("context cap \(formatTokenCount(cap))").foregroundStyle(.secondary)
            }
            if resolved.extendedCacheTTL {
                Text("1h cache").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Load / select

    private func loadFromViewModel() {
        guard let assignment = viewModel.agentAssignments[role] else { return }
        providerID = assignment.providerID
        modelID = assignment.modelID
    }

    private func selectModel(provider: ModelProvider, model: ModelInfo) {
        providerID = provider.id
        modelID = model.modelID
        viewModel.agentAssignments[role] = ModelAssignment(providerID: provider.id, modelID: model.modelID)
    }
}

/// Horizontal stack that wraps to additional rows when its proposed width is too narrow for the
/// next subview. Drop-in replacement for a single-row `HStack` in places like the model-info chips
/// bar where truncation is worse than wrapping.
private struct WrappingHStack: Layout {
    let spacing: CGFloat
    let lineSpacing: CGFloat

    init(spacing: CGFloat = 8, lineSpacing: CGFloat = 4) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var lineWidth: CGFloat = 0
        var lineMaxHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var maxLineWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let widthIfAppended = lineWidth == 0 ? size.width : lineWidth + spacing + size.width
            if widthIfAppended <= maxWidth || lineWidth == 0 {
                lineWidth = widthIfAppended
                lineMaxHeight = max(lineMaxHeight, size.height)
            } else {
                totalHeight += lineMaxHeight + lineSpacing
                maxLineWidth = max(maxLineWidth, lineWidth)
                lineWidth = size.width
                lineMaxHeight = size.height
            }
        }
        totalHeight += lineMaxHeight
        maxLineWidth = max(maxLineWidth, lineWidth)
        return CGSize(width: min(maxLineWidth, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var lineMaxHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let widthIfAppended = x == bounds.minX ? size.width : (x - bounds.minX) + spacing + size.width
            if widthIfAppended > maxWidth && x > bounds.minX {
                x = bounds.minX
                y += lineMaxHeight + lineSpacing
                lineMaxHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += (x == bounds.minX ? 0 : spacing) + size.width
            lineMaxHeight = max(lineMaxHeight, size.height)
        }
    }
}
