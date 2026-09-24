import SwiftUI
import AgentSmithKit

/// A memory query: corpus chip, origin, latency, and time; expands to the exact query, its
/// phase timings, and every returned memory and prior-task summary as snapshotted at query time.
struct MemoryQueryActivityRow: View {
    let query: MemoryQueryActivity
    let timestamp: Date
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button(action: toggle, label: {
                MemoryQueryActivitySummary(query: query, timestamp: timestamp, expanded: expanded)
                    .contentShape(Rectangle())
            })
            .buttonStyle(.plain)
            .help(MemoryActivityPresentation.corpusAccessibilityText(query))
            if expanded {
                MemoryQueryActivityDetail(query: query)
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

private struct MemoryQueryActivitySummary: View {
    let query: MemoryQueryActivity
    let timestamp: Date
    let expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                MemoryActivityBadge(text: MemoryActivityPresentation.compactCorpusLabel(query))
                    .accessibilityLabel(MemoryActivityPresentation.corpusAccessibilityText(query))
                Text(MemoryActivityPresentation.originLabel(query.origin))
                    .font(AppFonts.inspectorBody)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                MemoryActivityTiming(latencyMs: query.latencyMs, timestamp: timestamp)
            }
            Text(query.query)
                .font(AppFonts.inspectorBody)
                .foregroundStyle(.primary)
                .lineLimit(expanded ? nil : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
        }
    }
}

/// Everything a query returned, headed per corpus.
private struct MemoryQueryActivityDetail: View {
    let query: MemoryQueryActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(query.query)
                .font(AppFonts.inspectorBody)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(MemoryActivityPresentation.phaseBreakdown(query))
                .font(AppFonts.inspectorBody)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            MemoryHitsSection(outcome: query.memories)
            TaskSummaryHitsSection(outcome: query.taskSummaries)
        }
    }
}

private struct MemoryHitsSection: View {
    let outcome: CorpusSearchOutcome<MemoryHitSnapshot>

    var body: some View {
        InspectorSection(title: MemoryActivityPresentation.memoriesHeading(outcome)) {
            ForEach(outcome.hits ?? []) { hit in
                MemoryHitSnapshotRow(hit: hit)
            }
        }
    }
}

private struct TaskSummaryHitsSection: View {
    let outcome: CorpusSearchOutcome<TaskSummaryHitSnapshot>

    var body: some View {
        InspectorSection(title: MemoryActivityPresentation.taskSummariesHeading(outcome)) {
            ForEach(outcome.hits ?? []) { hit in
                TaskSummaryHitSnapshotRow(hit: hit)
            }
        }
    }
}

private struct MemoryHitSnapshotRow: View {
    let hit: MemoryHitSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("#\(hit.rank) · \(hit.source.rawValue)" + (hit.tags.isEmpty ? "" : " · " + hit.tags.joined(separator: ", ")))
                .font(AppFonts.microMonoBadge)
                .foregroundStyle(.secondary)
            Text(hit.content)
                .font(AppFonts.inspectorBody)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            MemoryHitScores(cosine: hit.cosineSimilarity, lexical: hit.lexicalScore, fusion: hit.reciprocalRankFusionScore,
                            identifier: hit.memoryID, relatedTaskID: hit.sourceTaskID)
        }
        .padding(4)
        .background(AppColors.subtleRowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

private struct TaskSummaryHitSnapshotRow: View {
    let hit: TaskSummaryHitSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("#\(hit.rank) · \(hit.title) · \(hit.status.rawValue)")
                .font(AppFonts.microMonoBadge)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text(hit.summary)
                .font(AppFonts.inspectorBody)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("task created \(hit.taskCreatedAt.formatted(date: .abbreviated, time: .shortened)) · summarized \(hit.summaryCreatedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(AppFonts.microMonoBadge)
                .foregroundStyle(.tertiary)
            MemoryHitScores(cosine: hit.cosineSimilarity, lexical: hit.lexicalScore, fusion: hit.reciprocalRankFusionScore,
                            identifier: hit.taskID, relatedTaskID: nil)
        }
        .padding(4)
        .background(AppColors.subtleRowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

private struct MemoryHitScores: View {
    let cosine: Double
    let lexical: Double
    let fusion: Double
    let identifier: UUID
    let relatedTaskID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(String(format: "cosine %.3f · lexical %.3f · RRF %.4f", cosine, lexical, fusion))
            Text("id \(identifier.uuidString)" + (relatedTaskID.map { " · task \($0.uuidString)" } ?? ""))
                .textSelection(.enabled)
        }
        .font(AppFonts.microMonoBadge)
        .foregroundStyle(.tertiary)
    }
}

/// The compact white-on-color chip leading each activity row.
struct MemoryActivityBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(AppFonts.microMonoBadge)
            .fontWeight(.bold)
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(AppColors.memoryActivity.opacity(0.8))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

/// Latency and time, trailing an activity row.
struct MemoryActivityTiming: View {
    let latencyMs: Int?
    let timestamp: Date

    var body: some View {
        HStack(spacing: 6) {
            if let latencyMs {
                Text("\(latencyMs)ms")
                    .monospacedDigit()
            }
            Text(timestamp, style: .time)
        }
        .font(AppFonts.inspectorBody)
        .foregroundStyle(.tertiary)
    }
}
