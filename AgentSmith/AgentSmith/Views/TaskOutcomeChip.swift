import SwiftUI
import AgentSmithKit

/// Compact, color-coded success-measure chip derived from a task's validation ledger.
/// Shown in place of the generic lifecycle status chip once a task is terminal, so the
/// row communicates HOW WELL the task went — not merely that it finished.
struct TaskOutcomeChip: View {
    let outcome: TaskOutcome

    var body: some View {
        let color = TaskOutcomeBadge.color(for: outcome)
        HStack(spacing: 3) {
            Image(systemName: TaskOutcomeBadge.icon(for: outcome))
                .imageScale(.small)
            Text(outcome.label)
            if let fraction = outcome.fraction {
                Text(fraction)
                    .monospacedDigit()
            }
        }
        .font(.caption)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.2)))
        .foregroundStyle(color)
    }
}

/// The lifecycle-status twin of ``TaskOutcomeChip``, for a task that has not reached an outcome yet.
///
/// Same capsule, same metrics, so a header reads identically whether the task finished or is still
/// running — only the colour and wording change. The sidebar shows a bare icon in this state because
/// its rows are tight; a pane header has room for the word.
struct TaskStatusChip: View {
    let status: AgentTask.Status

    var body: some View {
        let color = TaskStatusBadge.color(for: status)
        HStack(spacing: 3) {
            Image(systemName: TaskStatusBadge.icon(for: status))
                .imageScale(.small)
            Text(status.displayName)
        }
        .font(.caption)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.2)))
        .foregroundStyle(color)
    }
}

#Preview("Outcomes") {
    VStack(alignment: .leading, spacing: 8) {
        TaskOutcomeChip(outcome: .success(total: 8))
        TaskOutcomeChip(outcome: .pass(accepted: 6, waived: 2, total: 8))
        TaskOutcomeChip(outcome: .incomplete(accepted: 2, total: 8))
        TaskOutcomeChip(outcome: .needsReview(accepted: 3, total: 8))
    }
    .padding()
}
