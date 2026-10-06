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
/// Read from the saved transcript, so it spans earlier runs too (the call log above covers only
/// this run); each row is dated, and the heading says so.
private struct SummarizerProblemHistory: View {
    let messages: [ChannelMessage]

    var body: some View {
        // Errors and retry warnings are capped separately: a single retry storm posts up to 50
        // warnings, and the card's "New error" link opens this list — the error must be in it.
        let errors = Array(messages.filter { $0.severity >= .error }.prefix(20))
        let retries = Array(messages.filter { $0.severity == .warning }.prefix(20))
        SummarizerProblemSection(title: "Errors — all runs (newest \(errors.count))", messages: errors)
        SummarizerProblemSection(title: "Retries and warnings — all runs (newest \(retries.count))", messages: retries)
    }
}

private struct SummarizerProblemSection: View {
    let title: String
    let messages: [ChannelMessage]

    var body: some View {
        if !messages.isEmpty {
            InspectorSection(title: title) {
                ForEach(messages) { message in
                    SummarizerActivityRow(message: message)
                }
            }
        }
    }
}
