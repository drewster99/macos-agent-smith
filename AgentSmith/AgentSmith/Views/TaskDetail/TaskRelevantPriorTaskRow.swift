import SwiftUI
import AgentSmithKit

/// Single prior-task summary entry rendered in the Task Detail window's "Prior Tasks"
/// section.
///
/// Layout matches `TaskRelevantMemoryRow`: a fixed-width `%match` column on the leading
/// edge, then a stacked title line + 2-line summary preview on the trailing edge. The
/// title is the only click target that opens the referenced task in a new detail window
/// — links inside the markdown summary remain clickable. The `(more)`/`(less)` link in
/// the bottom-right toggles between the 2-line preview and the full summary.
struct TaskRelevantPriorTaskRow: View {
    let priorTask: RelevantPriorTask
    /// Externally-driven expanded state shared with peer rows in the same section.
    @Binding var isExpanded: Bool
    /// Invoked when the user clicks the title. The parent looks up the owning session
    /// via `SessionManager.resolveSessionID(forTaskID:)` so a prior task from another tab
    /// opens scoped to its actual session, avoiding the "Task Not Found" placeholder.
    let onOpenTask: (UUID) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(String(format: "%.0f%%", priorTask.similarity * 100))
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                titleLine()
                MarkdownText(content: priorTask.summary, baseFont: .callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(isExpanded ? nil : 2)
                if hasMoreContent {
                    DisclosureMoreLessLink(isExpanded: isExpanded, font: .caption) {
                        isExpanded.toggle()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func titleLine() -> some View {
        HStack(spacing: 0) {
            if let date = priorTask.latestDate {
                Text("(\(Self.format(date))) ")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button {
                onOpenTask(priorTask.taskID)
            } label: {
                Text(priorTask.title)
                    .font(.callout.bold())
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help("Open this task in a new detail window")
            Spacer(minLength: 0)
        }
    }

    /// True when the short-mode preview hides content the user could expand to see —
    /// the summary either has multiple lines or runs longer than fits in 2 lines. The
    /// 100-char threshold is the widest single-line wrap budget at `.callout` size on
    /// this row's layout.
    private var hasMoreContent: Bool {
        priorTask.summary.contains("\n") || priorTask.summary.count > 100
    }

    private static func format(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }
}
