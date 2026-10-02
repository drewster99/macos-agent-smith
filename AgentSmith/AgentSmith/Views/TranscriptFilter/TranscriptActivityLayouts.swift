import SwiftUI
import AgentSmithKit

/// How the activity section presents the participant × activity relation.
enum ActivityLayout: Hashable {
    /// One checkbox per row, acting on every participant at once.
    case everyone
    /// A grid: one column per participant.
    case byParticipant
}

/// The activity section's body in whichever layout is chosen.
struct ActivityLayoutContent: View {
    @Binding var config: TranscriptViewConfig
    let layout: ActivityLayout
    let rows: [FlatActivityRow]
    let stats: TranscriptFilterStats?
    let onToggleExpanded: (String) -> Void

    var body: some View {
        switch layout {
        case .everyone:
            TranscriptActivityList(config: $config, rows: rows, stats: stats, onToggleExpanded: onToggleExpanded)
        case .byParticipant:
            TranscriptActivityMatrix(config: $config, rows: rows, stats: stats, onToggleExpanded: onToggleExpanded)
        }
    }
}

// MARK: - Everyone

/// Every row acts on all participants. A row whose participants disagree shows as mixed — the hint
/// above the list points at the grid, where the disagreement is visible.
struct TranscriptActivityList: View {
    @Binding var config: TranscriptViewConfig
    let rows: [FlatActivityRow]
    let stats: TranscriptFilterStats?
    let onToggleExpanded: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                ActivityListRow(config: $config, row: row, stats: stats, onToggleExpanded: onToggleExpanded)
            }
        }
    }
}

private struct ActivityListRow: View {
    @Binding var config: TranscriptViewConfig
    let row: FlatActivityRow
    let stats: TranscriptFilterStats?
    let onToggleExpanded: (String) -> Void

    private var state: TranscriptKindSelection.GroupVisibility {
        config.visibility(of: row.node.targets, for: TranscriptViewConfig.participants)
    }

    var body: some View {
        HStack(spacing: 8) {
            DisclosureChevron(isExpandable: row.node.isExpandable, isExpanded: row.isExpanded) {
                onToggleExpanded(row.id)
            }
            Button(action: {
                config.setVisible(state != .all, targets: row.node.targets, for: TranscriptViewConfig.participants)
            }, label: {
                ActivityRowLabel(node: row.node, state: state, problemNote: problemNote)
            })
            .buttonStyle(.plain)
            .accessibilityValue(state.accessibilityDescription)
            Spacer(minLength: 8)
            Text(countText)
                .font(AppFonts.filterCount)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, CGFloat(row.depth) * 20)
        .padding(.vertical, 4)
        .opacity(isMoot ? 0.45 : 1)
        .help(isMoot ? "Takes effect when tool calls are shown" : "")
    }

    /// Messages these targets account for among the participants currently shown.
    private var countText: String {
        let shown = TranscriptViewConfig.participants.filter(config.isParticipantShown)
        return stats.map { $0.count(of: row.node.targets, for: shown).formatted() } ?? ""
    }

    /// Says so when hidden messages of this row are still on screen because they are warnings or
    /// errors — otherwise unchecking a row whose warnings stay visible looks like a broken filter.
    private var problemNote: String? {
        guard let stats, state != .all else { return nil }
        let count = stats.problemCount(of: row.node.targets, for: TranscriptViewConfig.participants)
        guard count > 0 else { return nil }
        return "\(count.formatted()) still shown as warnings or errors"
    }

    /// A tool row while no participant shows tool calls at all.
    private var isMoot: Bool {
        row.node.dependsOnToolCalls
            && config.visibility(of: TranscriptKindGroup.toolCalls.targets, for: TranscriptViewConfig.participants) == .none
    }
}

/// Checkbox glyph plus the row's title (and, for a category, its one-line description).
private struct ActivityRowLabel: View {
    let node: ActivityRowNode
    let state: TranscriptKindSelection.GroupVisibility
    let problemNote: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            TriStateGlyph(state: state)
            VStack(alignment: .leading, spacing: 0) {
                ActivityRowTitle(node: node)
                // Only categories and tool families carry a description; an empty `Text` would
                // still take a line's height and make every type row twice as tall.
                if let detail = node.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let problemNote {
                    Text(problemNote)
                        .font(.caption)
                        .foregroundStyle(AppColors.filterProblemNote)
                }
            }
        }
        .contentShape(Rectangle())
    }
}

/// A row's title in the weight its level calls for: categories regular, tools monospaced.
private struct ActivityRowTitle: View {
    let node: ActivityRowNode

    var body: some View {
        Text(node.title)
            .font(node.style == .tool ? AppFonts.filterToolName : .body)
            .lineLimit(1)
            // A tool name's distinguishing part is often its end (`mcp__server__verb`); a
            // category's is its start.
            .truncationMode(node.style == .tool ? .middle : .tail)
            .help(node.tooltip ?? node.title)
    }
}

// MARK: - By participant

/// The participant × activity grid. Each cell is one participant's answer for one row; the row's
/// own checkbox sets that row for everyone. Columns for hidden participants are dimmed — their
/// cells are kept for when they're shown again, but nothing they hold reaches the pane.
struct TranscriptActivityMatrix: View {
    @Binding var config: TranscriptViewConfig
    let rows: [FlatActivityRow]
    let stats: TranscriptFilterStats?
    let onToggleExpanded: (String) -> Void

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                ForEach(TranscriptViewConfig.participants, id: \.self) { participant in
                    MatrixColumnHeader(participant: participant, isShown: config.isParticipantShown(participant))
                }
            }
            ForEach(rows) { row in
                GridRow {
                    MatrixRowLabel(config: $config, row: row, onToggleExpanded: onToggleExpanded)
                    ForEach(TranscriptViewConfig.participants, id: \.self) { participant in
                        MatrixCell(config: $config, row: row, participant: participant, stats: stats)
                    }
                }
            }
        }
    }
}

/// Fixed geometry for the grid, in one place so the header, labels, and cells agree.
enum MatrixMetrics {
    static let labelWidth: CGFloat = 220
    static let columnWidth: CGFloat = 52
    static let rowHeight: CGFloat = 24
}

private struct MatrixColumnHeader: View {
    let participant: ChannelMessage.Sender
    let isShown: Bool

    var body: some View {
        VStack(spacing: 4) {
            Circle()
                .fill(AppColors.color(for: participant))
                .frame(width: 8, height: 8)
            Text(participant.filterShortName)
                .font(AppFonts.filterMatrixHeader)
                .lineLimit(1)
        }
        .frame(width: MatrixMetrics.columnWidth)
        .padding(.bottom, 8)
        .opacity(isShown ? 1 : 0.4)
        .help(isShown ? participant.filterName : "\(participant.filterName) is hidden — show them under Who")
    }
}

private struct MatrixRowLabel: View {
    @Binding var config: TranscriptViewConfig
    let row: FlatActivityRow
    let onToggleExpanded: (String) -> Void

    private var state: TranscriptKindSelection.GroupVisibility {
        config.visibility(of: row.node.targets, for: TranscriptViewConfig.participants)
    }

    var body: some View {
        HStack(spacing: 8) {
            DisclosureChevron(isExpandable: row.node.isExpandable, isExpanded: row.isExpanded) {
                onToggleExpanded(row.id)
            }
            Button(action: {
                config.setVisible(state != .all, targets: row.node.targets, for: TranscriptViewConfig.participants)
            }, label: {
                HStack(spacing: 8) {
                    TriStateGlyph(state: state)
                    ActivityRowTitle(node: row.node)
                }
                .contentShape(Rectangle())
            })
            .buttonStyle(.plain)
            .help("Set \(row.node.title) for everyone")
            .accessibilityValue(state.accessibilityDescription)
        }
        .padding(.leading, CGFloat(row.depth) * 16)
        .frame(width: MatrixMetrics.labelWidth, height: MatrixMetrics.rowHeight, alignment: .leading)
    }
}

private struct MatrixCell: View {
    @Binding var config: TranscriptViewConfig
    let row: FlatActivityRow
    let participant: ChannelMessage.Sender
    let stats: TranscriptFilterStats?

    private var count: Int? { stats?.count(of: row.node.targets, for: [participant]) }

    /// The participant is hidden outright, or this is a tool row and they show no tool calls.
    private var isMoot: Bool {
        !config.isParticipantShown(participant)
            || (row.node.dependsOnToolCalls
                && config.visibility(of: TranscriptKindGroup.toolCalls.targets, for: [participant]) == .none)
    }

    var body: some View {
        TriStateCheckbox(
            state: config.visibility(of: row.node.targets, for: [participant]),
            accessibilityName: "\(row.node.title), \(participant.filterName)"
        ) { visible in
            config.setVisible(visible, targets: row.node.targets, for: [participant])
        }
        .frame(width: MatrixMetrics.columnWidth, height: MatrixMetrics.rowHeight)
        // Dimmed ONLY where the cell can't take effect. Dimming empty cells too made the grid read
        // as mostly disabled; the count is in the tooltip instead.
        .opacity(isMoot ? 0.3 : 1)
        .help(helpText)
    }

    private var helpText: String {
        let base = "\(participant.filterName) · \(row.node.title)"
        guard let count, let stats else { return base }
        let problems = stats.problemCount(of: row.node.targets, for: [participant])
        let note = problems > 0 ? " (\(problems.formatted()) still shown as warnings or errors)" : ""
        return "\(base): \(count.formatted()) message\(count == 1 ? "" : "s")\(note)"
    }
}
