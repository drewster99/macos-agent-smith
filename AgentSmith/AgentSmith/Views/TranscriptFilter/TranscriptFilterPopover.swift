import SwiftUI
import AgentSmithKit

/// Where a filter popover gets the messages it counts.
///
/// A closure rather than an array so the pane header that owns the button doesn't observe — and
/// re-render on — every new message; the transcript is read only when the popover counts it.
struct TranscriptFilterStatsSource {
    let messages: () -> [ChannelMessage]
    /// The pane's whole population: `.any` for the session, `.task(id)` for a task.
    let universe: TranscriptFilter.TaskScope
    /// The pane's scope when the pane fixes it (a task); nil when the config's own switch decides.
    let fixedScope: TranscriptFilter.TaskScope?

    func compute(for config: TranscriptViewConfig) async -> TranscriptFilterStats {
        let snapshot = messages()
        let scope = fixedScope ?? (config.hideTaskScoped ? .orchestration : .any)
        return await Self.count(snapshot, config: config, universe: universe, scope: scope)
    }

    /// Off the main actor: a full pass over the resident transcript (up to its cap) per edit.
    @concurrent private static func count(
        _ messages: [ChannelMessage], config: TranscriptViewConfig,
        universe: TranscriptFilter.TaskScope, scope: TranscriptFilter.TaskScope
    ) async -> TranscriptFilterStats {
        TranscriptFilterStats.compute(messages: messages, config: config, universe: universe, scope: scope)
    }
}

/// The transcript filter: one model — scope, who, what, and how problems are treated — presented in
/// that order, with presets on top and live counts throughout. Every edit applies immediately.
struct TranscriptFilterPopover: View {
    @Binding var config: TranscriptViewConfig
    let pane: TranscriptPane
    /// nil when the pane's messages aren't resident here (a task read from another session's log).
    let statsSource: TranscriptFilterStatsSource?

    @State private var stats: TranscriptFilterStats?
    /// nil until the user picks one; until then the layout follows the config (see `layout`).
    @State private var layoutChoice: ActivityLayout?
    @State private var expanded: Set<String> = []
    @State private var tree: [ActivityRowNode] = ActivityRowTree.initial
    @State private var rows: [FlatActivityRow] = ActivityRowTree.flatten(ActivityRowTree.initial, expanded: [])

    var body: some View {
        VStack(spacing: 0) {
            TranscriptFilterHeader(config: $config, pane: pane, stats: stats)
            Divider()
            ScrollView {
                TranscriptFilterSections(
                    config: $config, pane: pane, stats: stats, layout: layoutBinding,
                    rows: rows, onToggleExpanded: toggleExpanded)
                    .padding(16)
            }
        }
        // Tall enough that the session pane's four sections fit without scrolling while every
        // category is collapsed; expanding rows scrolls.
        .frame(width: layoutBinding.wrappedValue == .byParticipant ? 600 : 420, height: 740)
        .task(id: config) { await refreshStats() }
    }

    /// A config whose participants disagree opens on the grid, where that disagreement is visible;
    /// a uniform one opens on the simpler list.
    private var layoutBinding: Binding<ActivityLayout> {
        Binding(
            get: { layoutChoice ?? (config.isUniformAcrossParticipants ? .everyone : .byParticipant) },
            set: { layoutChoice = $0 })
    }

    private func toggleExpanded(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        rows = ActivityRowTree.flatten(tree, expanded: expanded)
    }

    private func refreshStats() async {
        guard let statsSource else { return }
        let computed = await statsSource.compute(for: config)
        guard !Task.isCancelled else { return }
        stats = computed
        // The tree only changes when a tool no family claims (an MCP tool) appears.
        let rebuilt = ActivityRowTree.make(observedToolNames: computed.observedToolNames)
        guard rebuilt != tree else { return }
        tree = rebuilt
        rows = ActivityRowTree.flatten(tree, expanded: expanded)
    }
}

/// Title, Reset, the preset switcher, and the one-line "what am I looking at".
private struct TranscriptFilterHeader: View {
    @Binding var config: TranscriptViewConfig
    let pane: TranscriptPane
    let stats: TranscriptFilterStats?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(pane.title)
                    .font(.headline)
                Spacer()
                Button("Reset") {
                    config = pane.defaultConfig
                }
                .controlSize(.small)
                .disabled(!pane.isCustomized(config))
                .help("Return to this pane's default view")
            }
            TranscriptPresetPicker(config: $config, pane: pane)
            TranscriptFilterSummary(config: config, pane: pane, stats: stats)
        }
        .padding(16)
    }
}

/// The presets as one segmented control. When the config matches none, nothing is selected and the
/// summary below says "Custom".
private struct TranscriptPresetPicker: View {
    @Binding var config: TranscriptViewConfig
    let pane: TranscriptPane

    var body: some View {
        Picker("View", selection: selection) {
            ForEach(pane.presets) { preset in
                Text(preset.title).tag(String?.some(preset.id))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var selection: Binding<String?> {
        Binding(
            get: { pane.preset(matching: config)?.id },
            set: { id in
                guard let preset = pane.presets.first(where: { $0.id == id }) else { return }
                config = preset.config
            })
    }
}

private struct TranscriptFilterSummary: View {
    let config: TranscriptViewConfig
    let pane: TranscriptPane
    let stats: TranscriptFilterStats?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(pane.preset(matching: config)?.summary ?? "Custom view")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let stats {
                Text("Showing \(stats.shown.formatted()) of \(stats.total.formatted()) messages")
                    .font(AppFonts.filterCount)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.default, value: stats.shown)
            }
        }
    }
}

/// The four sections, in reading order: where, who, what, and the exception for problems.
private struct TranscriptFilterSections: View {
    @Binding var config: TranscriptViewConfig
    let pane: TranscriptPane
    let stats: TranscriptFilterStats?
    @Binding var layout: ActivityLayout
    let rows: [FlatActivityRow]
    let onToggleExpanded: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if pane.offersTaskScopeControl {
                TranscriptScopeSection(config: $config, stats: stats)
            }
            TranscriptParticipantsSection(config: $config, stats: stats)
            TranscriptActivitySection(
                config: $config, layout: $layout, rows: rows, stats: stats, onToggleExpanded: onToggleExpanded)
            TranscriptProblemsSection(config: $config)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Session pane only: keep this pane to the orchestration layer.
private struct TranscriptScopeSection: View {
    @Binding var config: TranscriptViewConfig
    let stats: TranscriptFilterStats?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FilterSectionHeader(title: "Scope")
            Toggle(isOn: $config.hideTaskScoped) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hide per-task work")
                    FilterCaption(text: caption)
                }
            }
        }
    }

    private var caption: String {
        let base = "Each task's work is shown in its own pane above."
        guard let stats, config.hideTaskScoped, stats.scopeExcluded > 0 else { return base }
        return "\(base) Hiding \(stats.scopeExcluded.formatted()) messages."
    }
}

private struct TranscriptParticipantsSection: View {
    @Binding var config: TranscriptViewConfig
    let stats: TranscriptFilterStats?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FilterSectionHeader(title: "Who")
            FlowLayout(spacing: 8) {
                ForEach(TranscriptViewConfig.participants, id: \.self) { participant in
                    ParticipantChip(config: $config, participant: participant,
                                    count: stats.map { $0.involving[participant] ?? 0 })
                }
            }
            FilterCaption(text: "Hiding someone hides the messages they send and the ones sent to them.")
        }
    }
}

private struct TranscriptActivitySection: View {
    @Binding var config: TranscriptViewConfig
    @Binding var layout: ActivityLayout
    let rows: [FlatActivityRow]
    let stats: TranscriptFilterStats?
    let onToggleExpanded: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                FilterSectionHeader(title: "Activity")
                Spacer()
                Picker("Layout", selection: $layout) {
                    Text("Everyone").tag(ActivityLayout.everyone)
                    Text("By participant").tag(ActivityLayout.byParticipant)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            if layout == .everyone && !config.isUniformAcrossParticipants {
                FilterCaption(text: "Some participants are set differently — a dash marks those rows. See By participant.")
            }
            ActivityLayoutContent(config: $config, layout: layout, rows: rows, stats: stats, onToggleExpanded: onToggleExpanded)
        }
    }
}

/// One choice for how warnings and errors relate to everything above.
private struct TranscriptProblemsSection: View {
    @Binding var config: TranscriptViewConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FilterSectionHeader(title: "Problems")
            Picker("Problems", selection: $config.problems) {
                ForEach(TranscriptProblemPolicy.allCases, id: \.self) { policy in
                    Text(policy.displayName).tag(policy)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            FilterCaption(text: config.problems.explanation)
        }
    }
}
