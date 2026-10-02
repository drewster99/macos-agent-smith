import SwiftUI
import AppKit
import Observation
import AgentSmithKit

/// Where a filter popover gets the messages it counts.
///
/// A closure rather than an array so the pane header that owns the button doesn't observe — and
/// re-render on — every new message; the transcript is read only when the popover counts it.
struct TranscriptFilterStatsSource {
    let messages: () -> [ChannelMessage]
    /// Moves whenever `messages` does (`AppViewModel.messagesRevision`). Only an open popover watches
    /// it, so its counts follow the transcript without the header that owns the button observing it.
    let revision: @MainActor @Sendable () -> Int
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

/// The popover's geometry in one place.
enum TranscriptFilterPopoverMetrics {
    static let listWidth: CGFloat = 420
    static let gridWidth: CGFloat = 620
    /// Tall enough that the session pane's four sections fit without scrolling while every
    /// category is collapsed; expanding rows scrolls.
    static let preferredHeight: CGFloat = 740
    /// Room kept between the popover and the screen's edges (menu bar, Dock, the anchor itself).
    static let screenMargin: CGFloat = 80

    /// The preferred height, or less on a screen too short for it, so the lower sections stay
    /// reachable by scrolling instead of running off the screen. With no screen to measure there is
    /// nothing to clamp against.
    static var height: CGFloat {
        guard let screen = NSScreen.main else { return preferredHeight }
        return min(preferredHeight, screen.visibleFrame.height - screenMargin)
    }
}

/// What the counts depend on besides the transcript itself. A change restarts counting at once —
/// including the task pane switching tasks under an open popover (a newly started task is
/// auto-selected).
private struct StatsRequest: Equatable {
    let config: TranscriptViewConfig
    let universe: TranscriptFilter.TaskScope?
    let fixedScope: TranscriptFilter.TaskScope?
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

    /// How often an open popover recounts while the transcript moves. Each recount is a full pass
    /// over the resident transcript; once a second keeps a busy worker from running them back to back.
    private static let recountInterval: Duration = .seconds(1)

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
        .frame(width: layoutBinding.wrappedValue == .byParticipant
                   ? TranscriptFilterPopoverMetrics.gridWidth : TranscriptFilterPopoverMetrics.listWidth,
               height: TranscriptFilterPopoverMetrics.height)
        // Latched once. Following the config live flipped the grid to the list — and the popover's
        // width — the moment an edit happened to make every participant agree.
        .onAppear { layoutChoice = layoutChoice ?? initialLayout }
        .task(id: StatsRequest(config: config, universe: statsSource?.universe, fixedScope: statsSource?.fixedScope)) {
            await followStats()
        }
    }

    /// A config whose participants disagree opens on the grid, where that disagreement is visible;
    /// a uniform one opens on the simpler list.
    private var initialLayout: ActivityLayout {
        config.isUniformAcrossParticipants ? .everyone : .byParticipant
    }

    private var layoutBinding: Binding<ActivityLayout> {
        Binding(get: { layoutChoice ?? initialLayout }, set: { layoutChoice = $0 })
    }

    private func toggleExpanded(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        rows = ActivityRowTree.flatten(tree, expanded: expanded)
    }

    /// Counts now, then again whenever the transcript moves, for as long as the popover is open.
    /// A config edit or a different source restarts this (the task's id), so an edit recounts at
    /// once. With no source the pane's messages aren't resident here, and the last pane's counts
    /// must not stand in for them.
    private func followStats() async {
        guard let statsSource else {
            stats = nil
            return
        }
        let revision = statsSource.revision
        let transcriptChanges = Observations { revision() }
        for await _ in transcriptChanges {
            let computed = await statsSource.compute(for: config)
            guard !Task.isCancelled else { return }
            apply(computed)
            do {
                try await Task.sleep(for: Self.recountInterval)
            } catch {
                // Only cancellation throws here: the popover closed, or the request changed.
                return
            }
        }
    }

    private func apply(_ computed: TranscriptFilterStats) {
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
                Text(Self.countLine(stats))
                    .font(AppFonts.filterCount)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.default, value: stats.shown)
            }
        }
    }
}

extension TranscriptFilterSummary {
    static func countLine(_ stats: TranscriptFilterStats) -> String {
        let base = "Showing \(stats.shown.formatted()) of \(stats.total.formatted()) messages"
        guard stats.shownOnlyAsProblems > 0 else { return base }
        return "\(base), \(stats.shownOnlyAsProblems.formatted()) only as warnings or errors"
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
            TranscriptProblemsSection(config: $config, stats: stats)
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
    let stats: TranscriptFilterStats?

    /// The policy's meaning, plus — when it is actually keeping hidden messages on screen — how
    /// many, so "I hid that, why is it still here?" has its answer right here.
    private var caption: String {
        guard let stats, stats.shownOnlyAsProblems > 0 else { return config.problems.explanation }
        let count = stats.shownOnlyAsProblems
        return "\(config.problems.explanation) Right now that keeps \(count.formatted()) hidden message\(count == 1 ? "" : "s") on screen."
    }

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
            FilterCaption(text: caption)
        }
    }
}
