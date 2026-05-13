import SwiftUI
import AgentSmithKit

/// Single timestamped update entry in the Task Detail window's "Updates" list. One view
/// per ForEach iteration — keeps the loop body free of nested layout primitives.
struct TaskUpdateRow: View {
    let update: AgentTask.TaskUpdate
    let attachmentURLResolver: (Attachment) -> URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(update.date.formatted(date: .omitted, time: .standard))
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                MarkdownText(content: update.message, baseFont: .callout)
            }
            if !update.attachments.isEmpty {
                TaskAttachmentList(
                    attachments: update.attachments,
                    compact: true,
                    urlResolver: attachmentURLResolver
                )
                .padding(.leading, 70)
            }
        }
    }
}
