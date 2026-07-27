import SwiftUI
import AgentSmithKit

/// Debug window: a side-by-side, message-aware visual diff of a captured context compaction.
/// Left is the FULL pre-compaction history (every message, every role, unfiltered); right is the
/// post-compaction history. Changed lines are highlighted in place at word granularity; ↑/↓ jump
/// between change hunks. Populated by the Debug → "Capture Compaction Diffs" toggle and the
/// "Compact Smith Now & Show Diff" one-shot.
struct CompactionDiffWindow: View {
    let viewModel: AppViewModel

    @State private var selectedCaptureID: UUID?

    private var captures: [CompactionDiffCapture] {
        // Newest first.
        viewModel.compactionCaptures.reversed()
    }

    private var selectedCapture: CompactionDiffCapture? {
        if let id = selectedCaptureID, let match = captures.first(where: { $0.id == id }) {
            return match
        }
        return captures.first
    }

    var body: some View {
        HSplitView {
            captureList()
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)

            if let capture = selectedCapture {
                CompactionDiffDetailView(capture: capture)
                    .frame(minWidth: 640, maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyState()
                    .frame(minWidth: 640, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 900, minHeight: 500)
        .navigationTitle("Compaction Diff — \(viewModel.session.name)")
    }

    private func captureList() -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if captures.isEmpty {
                    Text("No compactions captured yet.\nEnable Debug → “Capture Compaction Diffs”, or use “Compact Smith Now & Show Diff”.")
                        .font(AppFonts.channelTimestamp)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                } else {
                    ForEach(captures) { capture in
                        Button {
                            selectedCaptureID = capture.id
                        } label: {
                            CaptureRow(
                                capture: capture,
                                isSelected: capture.id == (selectedCapture?.id)
                            )
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
        }
        .background(AppColors.secondaryBackground)
    }

    private func emptyState() -> some View {
        ContentUnavailableView(
            "No Compaction Selected",
            systemImage: "arrow.left.arrow.right",
            description: Text("Capture a compaction to inspect its before/after diff.")
        )
    }

    /// One capture in the sidebar list.
    private struct CaptureRow: View {
        let capture: CompactionDiffCapture
        let isSelected: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(capture.trigger.displayLabel)
                        .font(AppFonts.channelTimestamp.weight(.semibold))
                    Spacer(minLength: 0)
                    Text("\(capture.beforeCount) → \(capture.afterCount)")
                        .font(AppFonts.channelTimestamp.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(capture.capturedAt.formatted(date: .abbreviated, time: .standard))
                    .font(AppFonts.channelTimestamp)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? AppColors.selectedRowBackground : Color.clear)
        }
    }
}

/// The side-by-side diff for one capture: a header with change navigation, then the aligned rows.
private struct CompactionDiffDetailView: View {
    let capture: CompactionDiffCapture

    @State private var rows: [ConversationDiff.Row] = []
    @State private var changeRowIDs: [Int] = []
    @State private var currentChangeIndex: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            header()
            Divider()
            ScrollViewReader { proxy in
                ScrollView([.vertical]) {
                    VStack(spacing: 0) {
                        columnHeaders()
                        ForEach(rows) { row in
                            CompactionDiffRowView(row: row)
                                .id(row.id)
                            Divider().opacity(0.4)
                        }
                    }
                    .padding(.bottom, 24)
                }
                .onChange(of: currentChangeIndex) { _, newValue in
                    guard changeRowIDs.indices.contains(newValue) else { return }
                    withAnimation(.easeInOut(duration: 0.15)) {
                        proxy.scrollTo(changeRowIDs[newValue], anchor: .center)
                    }
                }
            }
        }
        .task(id: capture.id) {
            let built = ConversationDiff.build(before: capture.before, after: capture.after)
            rows = built
            changeRowIDs = built.filter(\.isChange).map(\.id)
            currentChangeIndex = 0
        }
    }

    private func header() -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(capture.trigger.displayLabel) · \(capture.agentRole.displayName)")
                    .font(AppFonts.channelBody.weight(.semibold))
                Text("\(capture.beforeCount) messages → \(capture.afterCount) messages · \(changeRowIDs.count) change\(changeRowIDs.count == 1 ? "" : "s")")
                    .font(AppFonts.channelTimestamp)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !changeRowIDs.isEmpty {
                HStack(spacing: 6) {
                    Text("\(min(currentChangeIndex + 1, changeRowIDs.count)) / \(changeRowIDs.count)")
                        .font(AppFonts.channelTimestamp.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button {
                        currentChangeIndex = max(0, currentChangeIndex - 1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(currentChangeIndex <= 0)
                    Button {
                        currentChangeIndex = min(changeRowIDs.count - 1, currentChangeIndex + 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(currentChangeIndex >= changeRowIDs.count - 1)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func columnHeaders() -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text("BEFORE")
                .font(AppFonts.channelTimestamp.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            Divider()
            Text("AFTER")
                .font(AppFonts.channelTimestamp.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        .background(AppColors.secondaryBackground)
    }
}

/// Renders one aligned diff row across both columns. Equal/removed/added rows show whole-message
/// blocks; changed rows lay out line-by-line so old and new stay vertically aligned, with word-level
/// inline highlighting.
private struct CompactionDiffRowView: View {
    let row: ConversationDiff.Row

    var body: some View {
        switch row.kind {
        case .equal:
            wholeMessagePair(left: row.left, right: row.right, leftTint: .none, rightTint: .none)
        case .removed:
            wholeMessagePair(left: row.left, right: nil, leftTint: .removed, rightTint: .none)
        case .added:
            wholeMessagePair(left: nil, right: row.right, leftTint: .none, rightTint: .added)
        case .changed:
            changedMessage()
        }
    }

    // MARK: Whole-message rows

    private func wholeMessagePair(
        left: ConversationDiff.MessageRef?,
        right: ConversationDiff.MessageRef?,
        leftTint: LineTint,
        rightTint: LineTint
    ) -> some View {
        HStack(alignment: .top, spacing: 0) {
            messageColumn(left, tint: leftTint)
            Divider()
            messageColumn(right, tint: rightTint)
        }
    }

    private func messageColumn(_ ref: ConversationDiff.MessageRef?, tint: LineTint) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let ref {
                RoleChip(label: ref.roleLabel)
                Text(ref.text.isEmpty ? " " : ref.text)
                    .font(AppFonts.channelBody.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Color.clear.frame(height: 1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.background)
    }

    // MARK: Changed message (line-by-line)

    private func changedMessage() -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                RoleChip(label: row.left?.roleLabel ?? "")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.top, 6)
                Divider()
                RoleChip(label: row.right?.roleLabel ?? "")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.top, 6)
            }
            ForEach(row.lineRows ?? []) { line in
                HStack(alignment: .top, spacing: 0) {
                    lineCell(spans: line.oldSpans, kind: line.kind, side: .old)
                    Divider()
                    lineCell(spans: line.newSpans, kind: line.kind, side: .new)
                }
            }
        }
        .padding(.bottom, 4)
    }

    private func lineCell(spans: [InlineDiff.Span]?, kind: ConversationDiff.LineRow.Kind, side: LineSide) -> some View {
        let tint = lineTint(kind: kind, side: side, hasContent: spans != nil)
        return Group {
            if let spans, !spans.isEmpty {
                Text(Self.attributed(spans))
                    .font(AppFonts.channelBody.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if spans != nil {
                Text(" ").font(AppFonts.channelBody.monospaced())
            } else {
                Color.clear.frame(height: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 1)
        .background(tint.background)
    }

    private func lineTint(kind: ConversationDiff.LineRow.Kind, side: LineSide, hasContent: Bool) -> LineTint {
        switch kind {
        case .equal: return .none
        case .removed: return side == .old ? .removed : .none
        case .added: return side == .new ? .added : .none
        case .changed: return .none // inline spans carry the highlight; no whole-line tint
        }
    }

    // MARK: Inline attributed rendering

    private static func attributed(_ spans: [InlineDiff.Span]) -> AttributedString {
        var result = AttributedString()
        for span in spans {
            var piece = AttributedString(span.text)
            switch span.kind {
            case .equal:
                break
            case .removed:
                piece.backgroundColor = AppColors.diffRemovedBackground
                piece.foregroundColor = AppColors.diffRemovedForeground
            case .added:
                piece.backgroundColor = AppColors.diffAddedBackground
                piece.foregroundColor = AppColors.diffAddedForeground
            }
            result += piece
        }
        return result
    }

    private enum LineSide { case old, new }

    private enum LineTint {
        case none, removed, added

        var background: Color {
            switch self {
            case .none: return .clear
            case .removed: return AppColors.diffRemovedBackground
            case .added: return AppColors.diffAddedBackground
            }
        }
    }

    private struct RoleChip: View {
        let label: String
        var body: some View {
            Text(label.uppercased())
                .font(AppFonts.channelTimestamp.weight(.bold))
                .foregroundStyle(.secondary)
        }
    }
}
