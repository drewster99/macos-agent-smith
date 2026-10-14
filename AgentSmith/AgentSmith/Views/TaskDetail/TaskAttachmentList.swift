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

    /// Rows shown before "(more)". Audit tasks attach well over a hundred files; laying them all
    /// out made the detail window slow to open and to scroll.
    private static let previewCount = 12

    @State private var isExpanded = false
    /// Which files exist on disk — checked once per list, off the main thread. It used to be a
    /// `fileExists` call in every row's `body`: a disk read per row on every redraw of the window.
    @State private var fileStates: [Attachment.ID: AttachmentFileState] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 4) {
            ForEach(visibleAttachments) { attachment in
                TaskAttachmentRow(attachment: attachment, compact: compact,
                                  fileState: fileStates[attachment.id] ?? .checking)
            }
            if attachments.count > Self.previewCount {
                DisclosureMoreLessLink(isExpanded: isExpanded, font: .caption) { isExpanded.toggle() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: attachments.map(\.id)) {
            let located = attachments.map { (id: $0.id, url: urlResolver($0)) }
            let resolved = await AttachmentFileState.resolve(located)
            // A check for a list that has since changed must not overwrite the newer check's answer.
            guard !Task.isCancelled else { return }
            fileStates = resolved
        }
    }

    private var visibleAttachments: [Attachment] {
        isExpanded ? attachments : Array(attachments.prefix(Self.previewCount))
    }

}

/// Whether an attachment's file is on disk — looked up off the main thread, never in a `body`.
enum AttachmentFileState: Equatable, Sendable {
    /// Not looked up yet.
    case checking
    case present(URL)
    case missing

    /// One disk check per attachment, off the main thread. An attachment with no resolvable URL is
    /// missing.
    @concurrent
    static func resolve(_ located: [(id: Attachment.ID, url: URL?)]) async -> [Attachment.ID: AttachmentFileState] {
        var states: [Attachment.ID: AttachmentFileState] = [:]
        for entry in located {
            guard let url = entry.url else {
                states[entry.id] = .missing
                continue
            }
            states[entry.id] = FileManager.default.fileExists(atPath: url.path) ? .present(url) : .missing
        }
        return states
    }
}

/// Single row in `TaskAttachmentList`. Shows file metadata + a button to Reveal in Finder
/// when the file is on disk.
struct TaskAttachmentRow: View {
    let attachment: Attachment
    let compact: Bool
    let fileState: AttachmentFileState

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
            TaskAttachmentFileControl(fileState: fileState)
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

/// Reveal in Finder for a file that exists; a marker for one that doesn't; nothing while checking.
private struct TaskAttachmentFileControl: View {
    let fileState: AttachmentFileState

    var body: some View {
        switch fileState {
        case .checking:
            EmptyView()
        case .present(let url):
            Button(action: { NSWorkspace.shared.activateFileViewerSelecting([url]) }) {
                Image(systemName: "magnifyingglass")
                    .imageScale(.small)
            }
            .accessibilityLabel("Reveal in Finder")
            .buttonStyle(.plain)
            .help("Reveal in Finder")
        case .missing:
            Image(systemName: "exclamationmark.circle")
                .imageScale(.small)
                .foregroundStyle(.tertiary)
                .help("File missing on disk")
        }
    }
}
