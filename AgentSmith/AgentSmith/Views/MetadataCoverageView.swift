import SwiftUI
import SwiftLLMKit

/// Shows, for every configured provider, whether LiteLLM actually has metadata for each of its
/// models — and lets a wrong provider mapping be fixed in place.
///
/// This is the editor for `ModelProvider.liteLLMProviderName`, not merely a report. That mapping
/// is matched against the `litellm_provider` FIELD of LiteLLM's catalog (never a key prefix), and
/// when it's wrong the model silently loses its context/output limits, pricing, AND capability
/// flags — including `vision`, which decides whether images are sent at all. A ✗ here is the only
/// place that's visible.
///
/// A ✗ is not automatically a bug: LiteLLM genuinely doesn't catalogue Hugging Face, LM Studio, or
/// local endpoints, and it lags new model releases. The point is to tell "we mapped it wrong" apart
/// from "upstream simply doesn't have it".
struct MetadataCoverageView: View {
    @Bindable var shared: SharedAppState
    /// Supplied by the Settings tab so the deep-link (inspector "Resolve…") can scroll to the
    /// focused provider's section.
    var scrollProxy: ScrollViewProxy?

    /// providerID → (modelID → resolution). Recomputed on appear and after any mapping edit.
    @State private var resolutions: [String: [String: ModelMetadataService.Resolution]] = [:]
    /// Which `litellm_provider` values LiteLLM has data for, with model counts.
    @State private var availableNames: [(name: String, modelCount: Int)] = []
    @State private var expandedProviderIDs: Set<String> = []
    @State private var editingMappingFor: MappingEditTarget?
    @State private var isLoading = true
    /// "providerID/modelID" briefly highlighted after a deep-link, so the eye lands on the row.
    @State private var highlightedModelKey: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header()
            Divider()
            if isLoading {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                ForEach(shared.llmKit.providers) { provider in
                    providerSection(provider)
                }
            }
        }
        .task { await reload() }
        .onChange(of: shared.metadataFocusProviderID) {
            // Re-fired if the user hits Resolve again while Settings is already open.
            DispatchQueue.main.async { honorFocusTarget() }
        }
        .sheet(item: $editingMappingFor) { target in
            LiteLLMProviderPickerSheet(
                shared: shared,
                target: target,
                availableNames: availableNames,
                onSaved: { Task { await reload() } }
            )
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func header() -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("LiteLLM Metadata Coverage")
                .font(.title3.bold())
            Text("Limits, pricing, and capability flags (including vision) come from LiteLLM. A model with no match keeps only what its provider's API reported. Fix a mapping by clicking Change.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(totalsSummary)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func providerSection(_ provider: ModelProvider) -> some View {
        let modelResolutions = resolutions[provider.id] ?? [:]
        let hits = modelResolutions.values.filter { $0 == .resolved }.count
        let total = modelResolutions.count
        let isExpanded = expandedProviderIDs.contains(provider.id)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: { toggle(provider.id) }, label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .frame(width: 12)
                })
                .buttonStyle(.plain)
                .disabled(total == 0)

                statusIcon(providerIsMapped: provider.liteLLMProviderName != nil, hits: hits, total: total)

                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.name).font(.headline)
                    Text(mappingLabel(for: provider))
                        .font(.caption.monospaced())
                        .foregroundStyle(provider.liteLLMProviderName == nil ? .orange : .secondary)
                }
                Spacer()
                Text(total == 0 ? "no models" : "\(hits)/\(total)")
                    .font(.caption.monospaced())
                    .foregroundStyle(hits == total && total > 0 ? .green : .secondary)
                Button("Change\u{2026}") {
                    editingMappingFor = MappingEditTarget(provider: provider, modelID: nil)
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(shared.llmKit.models(for: provider.id), id: \.modelID) { model in
                        modelRow(provider: provider, modelID: model.modelID, resolution: modelResolutions[model.modelID])
                    }
                }
                .padding(.leading, 32)
            }
        }
        .padding(.vertical, 4)
        .id(provider.id)
    }

    @ViewBuilder
    private func modelRow(provider: ModelProvider, modelID: String, resolution: ModelMetadataService.Resolution?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: resolution == .resolved ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(resolution == .resolved ? .green : .red)
                .font(.caption)
            Text(modelID)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Spacer()
            if let resolution, resolution != .resolved {
                Text(explanation(for: resolution))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Button("Fix\u{2026}") {
                    editingMappingFor = MappingEditTarget(provider: provider, modelID: modelID)
                }
                .font(.caption2)
            }
        }
        .padding(.horizontal, 4)
        .background(
            highlightedModelKey == "\(provider.id)/\(modelID)" ? Color.yellow.opacity(0.18) : Color.clear,
            in: RoundedRectangle(cornerRadius: 4)
        )
    }

    @ViewBuilder
    private func statusIcon(providerIsMapped: Bool, hits: Int, total: Int) -> some View {
        if !providerIsMapped {
            Image(systemName: "minus.circle.fill").foregroundStyle(.orange)
        } else if total == 0 {
            // No models listed (no key, or never fetched) — there is nothing to match, which is
            // not a mapping failure and must not read as one.
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        } else if hits == total {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if hits == 0 {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        } else {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        }
    }

    // MARK: - Labels

    private var totalsSummary: String {
        let all = resolutions.values.flatMap(\.values)
        let hits = all.filter { $0 == .resolved }.count
        return "\(hits) of \(all.count) models have LiteLLM metadata"
    }

    private func mappingLabel(for provider: ModelProvider) -> String {
        guard let name = provider.liteLLMProviderName else { return "not mapped to a LiteLLM provider" }
        return "litellm_provider: \(name)"
    }

    private func explanation(for resolution: ModelMetadataService.Resolution) -> String {
        switch resolution {
        case .resolved: return ""
        case .providerNotMapped: return "provider not mapped"
        case .providerNotFound: return "no such litellm_provider"
        case .modelNotFound: return "not in LiteLLM"
        }
    }

    // MARK: - Actions

    private func toggle(_ providerID: String) {
        if expandedProviderIDs.contains(providerID) {
            expandedProviderIDs.remove(providerID)
        } else {
            expandedProviderIDs.insert(providerID)
        }
    }

    private func reload() async {
        availableNames = await shared.llmKit.allLiteLLMProviderNames()
        var next: [String: [String: ModelMetadataService.Resolution]] = [:]
        for provider in shared.llmKit.providers {
            next[provider.id] = await shared.llmKit.liteLLMResolutions(forProviderID: provider.id)
        }
        resolutions = next
        isLoading = false
        honorFocusTarget()
    }

    /// Consumes the one-shot deep-link from the inspector's Resolve button: expand the target
    /// provider, scroll its section into view, and briefly highlight the model row so "Resolve"
    /// lands ON the entry instead of merely on the tab.
    private func honorFocusTarget() {
        guard let providerID = shared.metadataFocusProviderID else { return }
        let modelID = shared.metadataFocusModelID
        shared.metadataFocusProviderID = nil
        shared.metadataFocusModelID = nil

        expandedProviderIDs.insert(providerID)
        if let modelID {
            highlightedModelKey = "\(providerID)/\(modelID)"
        }
        // Let the expansion lay out before scrolling to the section anchor.
        DispatchQueue.main.async {
            withAnimation {
                scrollProxy?.scrollTo(providerID, anchor: .top)
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(3))
            highlightedModelKey = nil
        }
    }
}

/// Identifies which provider's mapping is being edited, and (when the edit was started from a
/// failing model row) which model to offer candidate providers for.
struct MappingEditTarget: Identifiable {
    let provider: ModelProvider
    let modelID: String?
    var id: String { "\(provider.id)/\(modelID ?? "")" }
}
