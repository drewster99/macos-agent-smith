import SwiftUI
import AgentSmithKit

/// How much of an evaluation record a row reveals when expanded.
enum EvaluationRecordDetail {
    /// Sidebar: a few parameter lines and the start of the response.
    case compact
    /// Inspector window: the full stored parameters, prompt, and response, selectable.
    case full
}

extension EvaluationRecord {
    /// Per-task tool-scoping records aren't a SAFE/UNSAFE verdict on one call — they're a
    /// "here's the approved tool set" decision — so they get their own label/color.
    var isToolScoping: Bool { kind == .toolScoping }

    var dispositionLabel: String {
        if isToolScoping, disposition.wasJudged {
            return disposition.approved ? "SCOPED" : "NO TOOLS"
        }
        switch disposition.outcome {
        case .reviewCancelled:          return "CANCELLED"
        // Orange, not grey: a reviewer that cannot answer is an operational fault the user has to
        // act on, not a neutral outcome to be skimmed past.
        case .reviewerUnavailable:      return "NOT REVIEWED"
        case .autoApproved:             return "AUTO"
        case .approvedWithoutReview:    return "NOT REVIEWED (review off)"
        case .approved:                 return "SAFE"
        case .warned:                   return "WARN"
        case .refused(.abort):          return "ABORT"
        case .refused(.unsafe):         return "UNSAFE"
        }
    }

    var dispositionColor: Color {
        if isToolScoping, disposition.wasJudged {
            return disposition.approved ? .blue : .red
        }
        switch disposition.outcome {
        case .reviewCancelled:                        return .secondary
        case .reviewerUnavailable:                    return .orange
        case .approved, .autoApproved:                return .green
        case .approvedWithoutReview:                  return .orange
        case .warned:                                 return .orange
        case .refused:                                return .red
        }
    }
}

/// A row showing a single security evaluation result from SecurityEvaluator.
struct EvaluationRecordRow: View {
    let record: EvaluationRecord
    let detail: EvaluationRecordDetail
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button(action: toggle, label: {
                EvaluationRecordHeaderLine(record: record)
                    .contentShape(Rectangle())
            })
            .buttonStyle(.plain)
            .help(expanded ? "Hide evaluation detail" : "Show evaluation detail")
            .accessibilityLabel("\(record.dispositionLabel) evaluation of \(record.toolName), \(record.latencyMs) milliseconds, \(record.timestamp.formatted(date: .omitted, time: .shortened))")
            .accessibilityValue(expanded ? "expanded" : "collapsed")
            .accessibilityHint(expanded ? "Hides the evaluation detail" : "Shows the evaluation detail")
            if expanded {
                EvaluationRecordExpandedDetail(record: record, detail: detail)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(record.dispositionColor.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func toggle() {
        withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
    }
}

/// Disposition badge, tool name, latency, and time.
private struct EvaluationRecordHeaderLine: View {
    let record: EvaluationRecord

    var body: some View {
        HStack(spacing: 6) {
            EvaluationDispositionBadge(record: record)
            Text(record.toolName)
                .font(AppFonts.inspectorBody.bold())
                .foregroundStyle(.primary)
            Spacer()
            Text("\(record.latencyMs)ms")
                .font(AppFonts.inspectorBody)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            Text(record.timestamp, style: .time)
                .font(AppFonts.inspectorBody)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct EvaluationDispositionBadge: View {
    let record: EvaluationRecord

    var body: some View {
        Text(record.dispositionLabel)
            .font(AppFonts.microMonoBadge)
            .fontWeight(.bold)
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(record.dispositionColor.opacity(0.8))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

private struct EvaluationRecordExpandedDetail: View {
    let record: EvaluationRecord
    let detail: EvaluationRecordDetail

    var body: some View {
        switch detail {
        case .compact:
            EvaluationRecordCompactDetail(record: record)
        case .full:
            EvaluationRecordFullDetail(record: record)
        }
    }
}

private struct EvaluationRecordCompactDetail: View {
    let record: EvaluationRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !record.toolParams.isEmpty {
                Text(record.toolParams)
                    .font(AppFonts.smallMonoCode)
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
            }
            // The scoping response is the full allow/block JSON — show all of it; a verdict's
            // response is its reason, of which the sidebar shows the start.
            Text(record.isToolScoping ? record.response : "Response: \(record.response)")
                .font(record.isToolScoping ? AppFonts.smallMonoCode : AppFonts.inspectorBody.italic())
                .foregroundStyle(.secondary)
                .lineLimit(record.isToolScoping ? nil : 3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Everything the evaluation stored, exactly and in full.
private struct EvaluationRecordFullDetail: View {
    let record: EvaluationRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let taskTitle = record.taskTitle {
                Text("Task: \(taskTitle)")
                    .font(AppFonts.inspectorBody)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if !record.toolParams.isEmpty {
                TranscriptTextBox(title: "Tool parameters", text: record.toolParams, maxHeight: 160)
            }
            TranscriptTextBox(title: "Evaluation prompt (as stored)", text: record.prompt, maxHeight: 320)
            TranscriptTextBox(title: "Response", text: record.response, maxHeight: 220)
        }
        .padding(.top, 2)
    }
}
