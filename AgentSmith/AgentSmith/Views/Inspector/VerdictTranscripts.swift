import SwiftUI
import AgentSmithKit

/// Exactly what a validator was sent and what it said back, read from one
/// `CriterionVerdictRecord` — the assessment-debugging surface shared by Task Detail and the
/// Validator inspector.
///
/// The stored fields are capped by the coordinator, which marks any cut in the text itself, so the
/// titles say "as stored" and name the cap rather than promising the complete original.
/// What a verdict record's stored "user message" holds.
enum VerdictInputKind {
    /// The results/evidence the validator judged.
    case judgedEvidence
    /// An enumerated criterion's record stores the ENUMERATOR's input (the prompt that listed the
    /// items to judge), not per-item evidence.
    case enumeratorInput
    /// The criterion is no longer on the task, so which one it is can't be told.
    case unknown

    init(usesInputEnumerator: Bool?) {
        switch usesInputEnumerator {
        case true?: self = .enumeratorInput
        case false?: self = .judgedEvidence
        case nil: self = .unknown
        }
    }

    var title: String {
        switch self {
        case .judgedEvidence: return "User message — the results/evidence the validator judged"
        case .enumeratorInput: return "Enumerator input — the prompt that listed the items to judge"
        case .unknown: return "User message"
        }
    }
}

struct VerdictTranscripts<CopyControl: View>: View {
    let record: CriterionVerdictRecord
    let inputKind: VerdictInputKind
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
            VerdictTranscriptField(
                title: "System prompt as sent — includes the criterion & response format (stored up to \(Self.inputCap) characters; any cut is marked)",
                text: record.renderedSystemPrompt, absence: "No system prompt was stored for this verdict.",
                copyControl: copyControl)
            VerdictTranscriptField(
                title: "\(inputKind.title) (stored up to \(Self.inputCap) characters; any cut is marked)",
                text: record.renderedInput, absence: "No input was stored for this verdict.",
                copyControl: copyControl)
            VerdictTranscriptField(
                title: "Validator output, turn by turn (stored up to \(Self.logCap) characters; any cut is marked)",
                text: record.responseLog, absence: "No validator output was stored for this verdict.",
                copyControl: copyControl)
        }
    }
}

/// One stored transcript field, or a statement that it is absent — never silently omitted.
private struct VerdictTranscriptField<CopyControl: View>: View {
    let title: String
    let text: String?
    let absence: String
    let copyControl: (String) -> CopyControl

    var body: some View {
        if let text, !text.isEmpty {
            TranscriptTextBox(title: title, text: text, accessory: copyControl(text))
        } else {
            VerdictTranscriptAbsence(text: absence)
        }
    }
}

extension VerdictTranscripts where CopyControl == EmptyView {
    init(record: CriterionVerdictRecord, inputKind: VerdictInputKind) {
        self.init(record: record, inputKind: inputKind, copyControl: { _ in EmptyView() })
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
