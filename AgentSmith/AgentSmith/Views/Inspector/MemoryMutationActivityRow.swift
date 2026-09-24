import SwiftUI
import AgentSmithKit

/// A committed change to the memory corpus: badge, origin, a one-line summary, and time; expands
/// to the before / proposed / after text and, for `save_memory`, the consolidation decision.
struct MemoryMutationActivityRow: View {
    let mutation: MemoryMutationActivity
    let timestamp: Date
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button(action: toggle, label: {
                MemoryMutationActivitySummary(mutation: mutation, timestamp: timestamp, expanded: expanded)
                    .contentShape(Rectangle())
            })
            .buttonStyle(.plain)
            .help(expanded ? "Hide the change" : "Show the change")
            if expanded {
                MemoryMutationActivityDetail(mutation: mutation)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(AppColors.memoryActivity.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func toggle() {
        withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
    }
}

private struct MemoryMutationActivitySummary: View {
    let mutation: MemoryMutationActivity
    let timestamp: Date
    let expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                MemoryActivityBadge(text: MemoryActivityPresentation.mutationBadge(mutation))
                Text(MemoryActivityPresentation.originLabel(mutation.origin))
                    .font(AppFonts.inspectorBody)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                MemoryActivityTiming(latencyMs: nil, timestamp: timestamp)
            }
            Text(MemoryActivityPresentation.mutationSummary(mutation))
                .font(AppFonts.inspectorBody)
                .foregroundStyle(.primary)
                .lineLimit(expanded ? nil : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MemoryMutationActivityDetail: View {
    let mutation: MemoryMutationActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let consolidation = mutation.consolidation {
                MemoryConsolidationDetail(consolidation: consolidation)
            }
            if let before = mutation.before {
                TranscriptTextBox(title: "Before", text: MemoryMutationText.render(before), maxHeight: 160)
            }
            if let proposed = mutation.proposed {
                TranscriptTextBox(title: "Proposed (as the agent wrote it)", text: MemoryMutationText.render(proposed), maxHeight: 160)
            }
            if let after = mutation.after {
                TranscriptTextBox(title: "After (committed)", text: MemoryMutationText.render(after), maxHeight: 160)
            }
            MemoryMutationIdentifiers(mutation: mutation)
        }
    }
}

private struct MemoryConsolidationDetail: View {
    let consolidation: MemoryConsolidationContext

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(MemoryActivityPresentation.consolidationDecision(consolidation))
                .font(AppFonts.inspectorBody)
                .textSelection(.enabled)
            if let similarity = consolidation.candidateSimilarity {
                Text(String(format: "Candidate cosine similarity %.3f", similarity))
                    .font(AppFonts.microMonoBadge)
                    .foregroundStyle(.secondary)
            }
            CorrelationIDLabel(correlationID: consolidation.correlationID)
        }
    }
}

private struct MemoryMutationIdentifiers: View {
    let mutation: MemoryMutationActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(MemoryMutationText.subject(mutation.subject) + (mutation.retainedExistingID ? " · kept existing id" : ""))
            if let taskID = mutation.taskID {
                Text("task \(taskID.uuidString)")
            }
        }
        .font(AppFonts.microMonoBadge)
        .foregroundStyle(.tertiary)
        .textSelection(.enabled)
    }
}

enum MemoryMutationText {
    static func render(_ snapshot: MemoryContentSnapshot) -> String {
        snapshot.tags.isEmpty ? snapshot.text : snapshot.text + "\n\ntags: " + snapshot.tags.joined(separator: ", ")
    }

    static func subject(_ subject: MemoryMutationActivity.Subject) -> String {
        switch subject {
        case .memory(let id): return "memory \(id.uuidString)"
        case .taskSummary(let taskID, _): return "task summary \(taskID.uuidString)"
        }
    }
}
