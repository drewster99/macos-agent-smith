import SwiftUI
import AppKit
import AgentSmithKit

/// Renders the list of attachments associated with a task field (description, an update,
/// or the result). Each row shows the filename, MIME / size, and a Reveal-in-Finder
/// button so the user can pop the file open in its native app. The list is compact-mode
/// when nested inside an update row so multiple updates' attachments don't dominate the
/// detail window.
///
/// `urlResolver` returns the on-disk URL for an attachment — the calling view (which has
/// the session's `AppViewModel` in scope) provides this so the row can build a Reveal-in-
/// Finder action without needing the viewModel itself.
struct TaskAttachmentList: View {
    let attachments: [Attachment]
    var compact: Bool = false
    let urlResolver: (Attachment) -> URL?

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 4) {
            ForEach(attachments) { attachment in
                TaskAttachmentRow(attachment: attachment, compact: compact, url: urlResolver(attachment))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Single row in `TaskAttachmentList`. Shows file metadata + a button to Reveal in Finder
/// when the URL is reachable.
struct TaskAttachmentRow: View {
    let attachment: Attachment
    let compact: Bool
    let url: URL?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .imageScale(compact ? .small : .medium)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.filename)
                    .font(compact ? .caption : .callout)
                    .lineLimit(1)
                Text("\(attachment.mimeType) · \(attachment.formattedSize)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            if let url, FileManager.default.fileExists(atPath: url.path) {
                Button(action: { NSWorkspace.shared.activateFileViewerSelecting([url]) }) {
                    Image(systemName: "magnifyingglass")
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")
            } else {
                Image(systemName: "exclamationmark.circle")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
                    .help("File missing on disk")
            }
        }
        .padding(.vertical, compact ? 1 : 2)
    }

    private var iconName: String {
        if attachment.isImage { return "photo" }
        if attachment.isPDF { return "doc.richtext" }
        if attachment.mimeType.hasPrefix("video/") { return "video" }
        if attachment.mimeType.hasPrefix("audio/") { return "waveform" }
        if attachment.mimeType.hasPrefix("text/") { return "doc.text" }
        return "doc"
    }
}
