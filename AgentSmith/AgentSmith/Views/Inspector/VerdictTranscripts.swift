import SwiftUI
import AgentSmithKit

/// Exactly what a validator was sent and what it said back, read from one
/// `CriterionVerdictRecord` — the assessment-debugging surface shared by Task Detail and the
/// Validator inspector.
///
/// The stored fields are capped by the coordinator, which marks any cut in the text itself, so the
/// titles say "as stored" and name the cap rather than promising the complete original.
struct VerdictTranscripts<CopyControl: View>: View {
    let record: CriterionVerdictRecord
    /// Trailing control for each box, given that box's text (Task Detail's copy button).
    let copyControl: (String) -> CopyControl

    private static var inputCap: String {
        OrchestrationRuntime.maxPersistedInputChars.formatted()
    }
    private static var logCap: String {
        OrchestrationRuntime.maxPersistedLogChars.formatted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let systemPrompt = record.renderedSystemPrompt, !systemPrompt.isEmpty {
                TranscriptTextBox(
                    title: "System prompt as sent — includes the criterion & response format (stored up to \(Self.inputCap) characters; any cut is marked)",
                    text: systemPrompt, accessory: copyControl(systemPrompt))
            } else {
                VerdictTranscriptAbsence(text: "No system prompt was stored for this verdict.")
            }
            if let input = record.renderedInput, !input.isEmpty {
                TranscriptTextBox(
                    title: "User message — the results/evidence the validator judged (stored up to \(Self.inputCap) characters; any cut is marked)",
                    text: input, accessory: copyControl(input))
            }
            if let log = record.responseLog, !log.isEmpty {
                TranscriptTextBox(
                    title: "Validator output, turn by turn (stored up to \(Self.logCap) characters; any cut is marked)",
                    text: log, accessory: copyControl(log))
            }
        }
    }
}

extension VerdictTranscripts where CopyControl == EmptyView {
    init(record: CriterionVerdictRecord) {
        self.init(record: record, copyControl: { _ in EmptyView() })
    }
}

/// States that a transcript field is absent rather than silently omitting its box.
private struct VerdictTranscriptAbsence: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "doc.badge.ellipsis")
            .font(.caption)
            .foregroundStyle(AppColors.inspectorRetentionNotice)
    }
}
