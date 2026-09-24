import SwiftUI
import AgentSmithKit

/// Summarizer: an overview of its operations, its provider calls (a completed call with its exact
/// request, a failed attempt with its error), and its errors/retries. The call log covers every
/// operation billed to the Summarizer — task summaries, memory consolidation, web extraction, and
/// Smith's context compaction — over the same runs the session cost covers.
struct SummarizerInspectorSections: View {
    let callLog: InspectorCallLog?
    /// The Summarizer's own channel messages, newest first.
    let recentMessages: [ChannelMessage]
    @Binding var expandedCallIDs: Set<UUID>

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SummarizerOperationOverview(callLog: callLog)
                if let callLog, callLog.lifetimeCount > 0 {
                    LLMCallLogSection(log: callLog, expandedCallIDs: $expandedCallIDs, expandsNewestCall: true)
                }
                SummarizerProblemHistory(messages: recentMessages)
            }
            .padding(16)
        }
    }
}

private struct SummarizerOperationOverview: View {
    let callLog: InspectorCallLog?

    var body: some View {
        let tallies = callLog?.retainedOperationTallies() ?? []
        InspectorSection(title: SummarizerOverviewHeading.title(for: callLog)) {
            if tallies.isEmpty {
                Text("No Summarizer calls this run.")
                    .font(AppFonts.inspectorBody)
                    .foregroundStyle(.tertiary)
            }
            ForEach(tallies, id: \.operation.displayLabel) { tally in
                SummarizerOperationTallyRow(tally: tally)
            }
        }
    }
}

enum SummarizerOverviewHeading {
    static func title(for log: InspectorCallLog?) -> String {
        guard let log, log.evictedCount > 0 else { return "Operations" }
        return "Operations — in the latest \(log.entries.count) of \(log.lifetimeCount) calls"
    }
}

private struct SummarizerOperationTallyRow: View {
    let tally: InspectorCallLog.OperationTally

    var body: some View {
        HStack(spacing: 8) {
            LLMCallOperationBadge(operation: tally.operation)
            Text("\(tally.completed) completed")
                .font(AppFonts.inspectorBody)
                .foregroundStyle(.secondary)
            if tally.failed > 0 {
                Text("\(tally.failed) failed")
                    .font(AppFonts.inspectorBody)
                    .foregroundStyle(AppColors.inspectorCallFailed)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}

/// The Summarizer's warnings and errors from the transcript — retry notices and final failures.
private struct SummarizerProblemHistory: View {
    let messages: [ChannelMessage]

    var body: some View {
        let problems = Array(messages.filter { $0.severity >= .warning }.prefix(20))
        if !problems.isEmpty {
            InspectorSection(title: "Errors and retries (newest \(problems.count))") {
                ForEach(problems) { message in
                    SummarizerActivityRow(message: message)
                }
            }
        }
    }
}
