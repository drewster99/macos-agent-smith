import SwiftUI
import AppKit
import AgentSmithKit

/// Renders a task's structured result deliverables (`ResultItem`s) as a stack of cards: each with
/// its routing tags, inline text (markdown), and attachment references. Each attachment whose file
/// is reachable on disk is a clickable link that opens it in its default app; unreachable ones fall
/// back to a plain secondary label.
struct DeliverablesView: View {
    let items: [ResultItem]
    /// Resolves an attachment to its on-disk URL so a reachable file can be opened. Defaults to
    /// unresolved (every row renders as a plain label) for previews and callers without a session.
    var urlResolver: (Attachment) -> URL? = { _ in nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                deliverableCard(item)
            }
        }
    }

    private func deliverableCard(_ item: ResultItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !item.refs.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(Array(item.refs.enumerated()), id: \.offset) { _, ref in
                        Text(ref)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(AppColors.deliverableTagBackground))
                            .foregroundStyle(AppColors.deliverableTagForeground)
                    }
                }
            }
            content(for: item.content)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppColors.deliverableCardBackground))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(AppColors.deliverableCardBorder, lineWidth: 0.5))
    }

    @ViewBuilder
    private func content(for content: ResultItem.Content) -> some View {
        switch content {
        case .text(let text):
            MarkdownText(content: text, baseFont: .body)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .attachment(let attachment):
            attachmentLabel(attachment)
        case .attachmentGroup(let attachments, let description):
            if let description, !description.isEmpty {
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(attachments) { attachment in
                    attachmentLabel(attachment)
                }
            }
        case .unknown(let kind, _):
            Text("[unsupported result item: \(kind)]")
                .font(.callout)
                .italic()
                .foregroundStyle(.secondary)
        }
    }

    /// A single attachment reference line — icon reflects the file kind. When the file is
    /// reachable on disk the row becomes a link that opens it in its default app; otherwise it
    /// degrades to a plain secondary label (no dead click target).
    @ViewBuilder
    private func attachmentLabel(_ attachment: Attachment) -> some View {
        let icon = attachment.isImage ? "photo" : (attachment.isPDF ? "doc.richtext" : "paperclip")
        if let url = urlResolver(attachment), FileManager.default.fileExists(atPath: url.path) {
            Button(action: { NSWorkspace.shared.open(url) }, label: {
                Label(attachment.filename, systemImage: icon)
                    .font(.callout)
            })
            .buttonStyle(.plain)
            .foregroundStyle(AppColors.disclosureToggle)
            .help("Open \(attachment.filename)")
            .pointerStyle(.link)
        } else {
            Label(attachment.filename, systemImage: icon)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// Plain-text rendering for a section copy button — the single source of truth for how a
    /// deliverable reads as text.
    static func plainText(_ items: [ResultItem]) -> String {
        items.map { item in
            let tag = item.refs.isEmpty ? "" : "[for: \(item.refs.joined(separator: ", "))] "
            switch item.content {
            case .text(let text):
                return "\(tag)\(text)"
            case .attachment(let attachment):
                return "\(tag)\(attachment.filename)"
            case .attachmentGroup(let attachments, let description):
                let head = description.map { "\($0): " } ?? ""
                return "\(tag)\(head)\(attachments.map(\.filename).joined(separator: ", "))"
            case .unknown(let kind, _):
                return "\(tag)[unsupported result item: \(kind)]"
            }
        }.joined(separator: "\n")
    }
}

/// Minimal wrapping row layout so tag chips flow onto multiple lines instead of overflowing a
/// fixed-width column when a deliverable carries several tags.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var maxRowWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + spacing + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                maxRowWidth = max(maxRowWidth, x)
                x = 0
                rowHeight = 0
            }
            x += (x > 0 ? spacing : 0) + size.width
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        maxRowWidth = max(maxRowWidth, x)
        return CGSize(width: maxWidth.isFinite ? maxWidth : maxRowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

#Preview("Deliverables") {
    let pdf = Attachment(filename: "runtime-report.pdf", mimeType: "application/pdf", byteCount: 12_345)
    let de = Attachment(filename: "de-paywall-01.png", mimeType: "image/png", byteCount: 90_210)
    let ar = Attachment(filename: "ar-paywall-01.png", mimeType: "image/png", byteCount: 88_120)
    return ScrollView {
        DeliverablesView(items: [
            ResultItem(content: .text("Jeff's email address is **jeff@example.com** (from a 2002 message)."), refs: ["email-found"]),
            ResultItem(content: .attachment(pdf), refs: ["report"]),
            ResultItem(
                content: .attachmentGroup(attachments: [de, ar], description: "Per-locale paywall screenshots (pseudolocalized)"),
                refs: ["screenshots", "coverage"]
            ),
            ResultItem(content: .text("No routing tag on this one — still shown as a deliverable."))
        ])
        .padding()
    }
    .frame(width: 460, height: 460)
}
