import SwiftUI
import AgentSmithKit

/// One row in the Memory editor's Task Summaries list. Shows the task title, an optional
/// similarity-score chip, the status badge, the rendered summary, the persisted summary ID,
/// and the original task creation date. The alternating background is driven by the parent.
struct MemoryTaskSummaryRow: View {
    let summary: TaskSummaryEntry
    let similarityScore: Double?
    let isAlternateRow: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(summary.title)
                    .font(.body.bold())
                Spacer()
                // Collapse to a 0-width frame (rather than `if let score`) so the view
                // structure stays stable across renders. `.fixedSize` first forces the Text
                // to its natural width; the conditional `.frame(width:)` then clamps that
                // to 0 when no score is present, eliminating the HStack default-spacing
                // slot the empty Text would otherwise occupy.
                Text(similarityScore.map { String(format: "%.0f%%", $0 * 100) } ?? "")
                    .font(.caption.bold().monospaced())
                    .foregroundStyle(Self.similarityColor(similarityScore))
                    .fixedSize()
                    .frame(width: similarityScore == nil ? 0 : nil, alignment: .trailing)
                    .clipped()
                Text(summary.status.rawValue)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Self.statusColor(summary.status).opacity(0.15))
                    .foregroundStyle(Self.statusColor(summary.status))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }

            MarkdownText(content: summary.summary, baseFont: .callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Text("ID: \(summary.id.uuidString)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                Spacer()
                Text("Created \(Self.formatDateTime(summary.taskCreatedAt))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isAlternateRow ? AppColors.subtleRowBackgroundDim : Color.clear)
    }

    private static func similarityColor(_ score: Double?) -> Color {
        guard let score else { return .clear }
        if score >= 0.80 { return .green }
        if score >= 0.70 { return .yellow }
        if score >= 0.60 { return .orange }
        return .red
    }

    private static func statusColor(_ status: AgentTask.Status) -> Color {
        switch status {
        case .pending: return .secondary
        case .starting: return .cyan
        case .running: return .blue
        case .awaitingReview: return .orange
        case .completed: return .green
        case .failed: return .red
        case .paused: return .secondary
        case .interrupted: return .yellow
        case .scheduled: return .purple
        case .validating: return .teal
        }
    }

    private static func formatDateTime(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}
