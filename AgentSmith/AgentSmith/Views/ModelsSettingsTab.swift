import AppKit
import SwiftUI
import UniformTypeIdentifiers
import AgentSmithKit
import SwiftLLMKit

/// Settings → Models tab.
///
/// Extracted from `SettingsView` so its `@Observable` dependency tracking is scoped to the model
/// catalog alone. The list derives in two stages:
///
/// 1. **Build + sort** (`buildSortedRows`, off the main actor): every (provider, model) becomes a
///    `ModelRowContent` — display segments plus the derived searchable strings — sorted once. Runs
///    only when the provider set, catalog, or sort order changes.
/// 2. **Filter** (`applyFilter`, on the main actor): the pre-sorted rows are filtered by the parsed
///    query on every keystroke. Filtering preserves order, so no re-sort per keystroke; matching is
///    substring tests over precomputed strings, so it stays realtime.
///
/// Matched text is highlighted live: each on-screen row maps the parsed query back to per-segment
/// character ranges (`ModelRowContent.highlightRanges`) and renders them as attributed runs.
struct ModelsSettingsTab: View {
    @Bindable var shared: SharedAppState
    let sessionManager: SessionManager

    @State private var filterText = ""
    @State private var sortOrder: ModelSortOrder = .provider

    /// Provider chosen in the left-hand dropdown; `nil` = "All".
    @State private var providerFilterID: String?

    /// Every (provider, model) built and sorted, off-main. `nil` until the first build completes.
    @State private var sortedRows: [ModelRowContent]?

    /// `sortedRows` filtered by the current query — what the list renders. `nil` = not yet built
    /// (renders no list rather than flashing the empty message before the first build).
    @State private var displayed: [ModelRowContent]?

    /// The parsed query, kept so on-screen rows can compute their highlights.
    @State private var search = PreparedModelSearch([])

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
                providers: shared.llmKit.providers,
                filterText: $filterText,
                sortOrder: $sortOrder,
                providerFilterID: $providerFilterID,
                displayed: displayed,
                search: search,
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
        .task(id: buildInputs) { await rebuild() }
        .onChange(of: filterText) { applyFilter() }
        .onChange(of: providerFilterID) { applyFilter() }
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

    /// The inputs the built+sorted rows derive from. Used as the `.task(id:)` key so a catalog
    /// refresh, a provider edit, or a sort-order change cancels the in-flight build and starts fresh.
    /// The query is deliberately absent — it only drives the (cheap, on-main) filter, not the build.
    private var buildInputs: BuildInputs {
        BuildInputs(
            providers: shared.llmKit.providers,
            catalog: shared.llmKit.models,
            order: sortOrder
        )
    }

    /// Builds + sorts the rows off the main actor, publishes them, then applies the current filter.
    /// Runs inside `.task(id:)`, so a change to any build input cancels this before it can publish.
    private func rebuild() async {
        let inputs = buildInputs
        let rows = await Self.buildSortedRows(
            providers: inputs.providers,
            catalog: inputs.catalog,
            order: inputs.order
        )
        if Task.isCancelled { return }
        sortedRows = rows
        applyFilter()
    }

    /// Filters the pre-sorted rows by the selected provider AND the parsed query. Cheap enough to run
    /// on the main actor on every keystroke (substring tests over precomputed strings); keeps
    /// `displayed` and `search` updated together so highlighting never lags the filtered set.
    private func applyFilter() {
        let prepared = PreparedModelSearch(parseModelSearchQuery(filterText))
        search = prepared
        guard let sortedRows else { return }
        let providerID = providerFilterID
        if providerID == nil && prepared.isEmpty {
            displayed = sortedRows
        } else {
            displayed = sortedRows.filter { row in
                (providerID == nil || row.provider.id == providerID)
                    && (prepared.isEmpty || row.matches(prepared))
            }
        }
    }

    /// The gather + build + sort, run off the main actor (`@concurrent`). Groups the catalog by
    /// provider once (O(n)), builds each `ModelRowContent` (display segments + searchable strings),
    /// then locale-sorts. Everything it touches is a value snapshot, never `shared`/`llmKit`.
    @concurrent
    nonisolated private static func buildSortedRows(
        providers: [ModelProvider],
        catalog: [ModelInfo],
        order: ModelSortOrder
    ) async -> [ModelRowContent] {
        var modelsByProvider: [String: [ModelInfo]] = [:]
        for model in catalog {
            modelsByProvider[model.providerID, default: []].append(model)
        }
        var rows: [ModelRowContent] = []
        for provider in providers {
            for model in modelsByProvider[provider.id] ?? [] {
                rows.append(ModelRowContent(provider: provider, model: model))
            }
        }
        switch order {
        case .provider:
            rows.sort { lhs, rhs in
                let byProvider = lhs.provider.name.localizedCaseInsensitiveCompare(rhs.provider.name)
                if byProvider != .orderedSame {
                    return byProvider == .orderedAscending
                }
                return lhs.model.displayName.localizedCaseInsensitiveCompare(rhs.model.displayName) == .orderedAscending
            }
        case .model:
            rows.sort { $0.model.displayName.localizedCaseInsensitiveCompare($1.model.displayName) == .orderedAscending }
        }
        return rows
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

/// The value snapshot the built+sorted rows derive from — the `.task(id:)` key that drives rebuild.
private struct BuildInputs: Equatable {
    let providers: [ModelProvider]
    let catalog: [ModelInfo]
    let order: ModelSortOrder
}

/// (providerID, modelID) of the model whose per-model editor sheet is open.
private struct ModelEditTarget: Identifiable {
    let providerID: String
    let modelID: String
    var id: String { "\(providerID)/\(modelID)" }
}

/// Detailed search-syntax help shown as the search field's tooltip.
private let modelSearchHelp = """
Filter the model list. Terms are combined with AND.

• Unquoted words match anywhere in the row, case-insensitively (e.g. vision, 128k, $10).
• "Quoted text" matches exactly and case-sensitively, within one display line (e.g. "max 6").

Example: vis "max 6" — models with "vision" AND an exact "max 6…".
"""

/// The provider dropdown + search field + sort control, plus the model list (or the appropriate
/// empty-state message).
private struct ModelCatalogSection: View {
    let providers: [ModelProvider]
    @Binding var filterText: String
    @Binding var sortOrder: ModelSortOrder
    @Binding var providerFilterID: String?
    let displayed: [ModelRowContent]?
    let search: PreparedModelSearch
    let onEditFlags: (ModelEditTarget) -> Void
    let onEditCapabilities: (ModelEditTarget) -> Void
    let onEditPricing: (ModelEditTarget) -> Void

    var body: some View {
        if providers.isEmpty {
            ModelsCenteredMessage(text: "No providers configured. Add one in Settings → Providers.")
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ProviderFilterPicker(providers: providers, selection: $providerFilterID)
                    MacSearchField(text: $filterText, placeholder: "Search", help: modelSearchHelp)
                        .frame(maxWidth: .infinity)
                    Picker("Sort", selection: $sortOrder) {
                        ForEach(ModelSortOrder.allCases) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                ModelCatalogList(
                    filterText: filterText,
                    displayed: displayed,
                    search: search,
                    onEditFlags: onEditFlags,
                    onEditCapabilities: onEditCapabilities,
                    onEditPricing: onEditPricing
                )
            }
        }
    }
}

/// Left-hand "All / <provider>" dropdown. Providers are listed alphabetically; `nil` = All.
private struct ProviderFilterPicker: View {
    let providers: [ModelProvider]
    @Binding var selection: String?

    var body: some View {
        let sorted = providers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        Picker("Provider", selection: $selection) {
            Text("All").tag(String?.none)
            ForEach(sorted) { provider in
                Text(provider.name).tag(Optional(provider.id))
            }
        }
        .labelsHidden()
        .fixedSize()
    }
}

/// The list of matching model rows, or the empty-state message when nothing matches.
///
/// A `LazyVStack` (user-approved 2026-07-31, overriding the project's default "avoid lazy" rule):
/// the catalog runs to ~1,700 rows, so eager realization froze the tab. Rows are short and uniform,
/// well under a screen dimension, so the sizing pitfall that rule guards against does not apply.
/// Only on-screen rows realize, so both opening the tab and scrolling stay smooth — and only
/// on-screen rows compute their search highlights.
private struct ModelCatalogList: View {
    let filterText: String
    let displayed: [ModelRowContent]?
    let search: PreparedModelSearch
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
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(rows) { content in
                        ModelRow(
                            content: content,
                            search: search,
                            onEditFlags: onEditFlags,
                            onEditCapabilities: onEditCapabilities,
                            onEditPricing: onEditPricing
                        )
                    }
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
/// the three per-model editor buttons. Renders from precomputed display segments and highlights the
/// current query's matches. Takes plain value types, so it observes nothing.
private struct ModelRow: View {
    let content: ModelRowContent
    let search: PreparedModelSearch
    let onEditFlags: (ModelEditTarget) -> Void
    let onEditCapabilities: (ModelEditTarget) -> Void
    let onEditPricing: (ModelEditTarget) -> Void

    private var target: ModelEditTarget {
        ModelEditTarget(providerID: content.provider.id, modelID: content.model.modelID)
    }

    var body: some View {
        // Only on-screen rows exist (LazyVStack), so computing highlights here is bounded to the
        // visible set — a few hundred character comparisons per row, per keystroke.
        let highlights = content.highlightRanges(search)
        return GroupBox {
            HStack {
                ModelRowInfo(lines: content.lines, highlights: highlights)
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

/// The left-hand info column of a model row, rendered from precomputed segments with highlighting.
private struct ModelRowInfo: View {
    let lines: [[ModelRowSegment]]
    let highlights: [ModelRowSegmentKey: IndexSet]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ModelSegmentsLine(segments: lines[0], lineIndex: 0, spacing: 6, highlights: highlights)
            ModelSegmentsLine(segments: lines[1], lineIndex: 1, spacing: 8, highlights: highlights)
            if !lines[2].isEmpty {
                ModelSegmentsLine(segments: lines[2], lineIndex: 2, spacing: 8, highlights: highlights)
            }
            if !lines[3].isEmpty {
                ModelRowFlagChips(segments: lines[3], highlights: highlights)
            }
        }
    }
}

/// A single row-line laid out as its segments, each highlighted per the query.
private struct ModelSegmentsLine: View {
    let segments: [ModelRowSegment]
    let lineIndex: Int
    let spacing: CGFloat
    let highlights: [ModelRowSegmentKey: IndexSet]

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                ModelSegmentView(
                    segment: segment,
                    highlightOffsets: highlights[ModelRowSegmentKey(line: lineIndex, segment: index)]
                )
            }
        }
    }
}

/// The behavior-flags line: the icon followed by the flag chips (line index 3).
private struct ModelRowFlagChips: View {
    let segments: [ModelRowSegment]
    let highlights: [ModelRowSegmentKey: IndexSet]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                ModelSegmentView(
                    segment: segment,
                    highlightOffsets: highlights[ModelRowSegmentKey(line: 3, segment: index)]
                )
            }
        }
        .help("Per-model behavior flags resolved from bundled defaults + user overrides. Edit via the Flags button.")
    }
}

/// One styled text segment, rendered with the query's matched characters highlighted. Styling is
/// driven by `segment.kind` so the look matches the original per-element formatting exactly.
private struct ModelSegmentView: View {
    let segment: ModelRowSegment
    let highlightOffsets: IndexSet?

    private var attributed: AttributedString {
        attributedHighlighting(
            segment.text,
            highlightedOffsets: highlightOffsets,
            background: AppColors.searchMatchBackground
        )
    }

    var body: some View {
        switch segment.kind {
        case .title:
            Text(attributed)
                .font(.headline)
        case .newBadge:
            Text(attributed)
                .font(.caption2)
                .foregroundStyle(.green)
        case .providerChip:
            Text(attributed)
                .font(.caption)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(AppColors.providerChipBackground)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        case .modelID, .maxTokens, .ctxTokens, .capabilities:
            Text(attributed)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .pricing:
            Text(attributed)
                .font(.caption)
                .foregroundStyle(.green)
        case .flagChip:
            Text(attributed)
                .font(.caption2)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(AppColors.flagChipBackground)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(AppColors.flagChipForeground)
        }
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
