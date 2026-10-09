import SwiftUI
import AppKit

/// Hover-revealed copy button overlaid on a `MessageRow`. Visibility is driven by the
/// parent's `isHovering` flag; opacity (rather than conditional rendering) keeps the
/// view structure stable across hover transitions.
struct MessageRowCopyOverlay: View {
    let isHovering: Bool
    let messageContent: String

    var body: some View {
        Button(action: {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(messageContent, forType: .string)
        }, label: {
            Image(systemName: "doc.on.doc")
                .font(AppFonts.metaIconSmall)
                .foregroundStyle(.secondary)
                .padding(4)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        })
        .accessibilityLabel("Copy message")
        .buttonStyle(.plain)
        .padding(4)
        .opacity(isHovering ? 1 : 0)
        .allowsHitTesting(isHovering)
        .accessibilityHidden(!isHovering)
    }
}
