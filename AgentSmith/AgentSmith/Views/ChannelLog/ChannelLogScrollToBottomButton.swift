import SwiftUI

/// Floating "jump to latest" button shown over the channel log when the user has
/// scrolled away from the bottom. Tapping triggers an animated scroll back to the
/// most recent message.
struct ChannelLogScrollToBottomButton: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap, label: {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
        })
        .accessibilityLabel("Scroll to latest message")
        .buttonStyle(.plain)
        .padding(8)
        .background(.ultraThinMaterial)
        .clipShape(Circle())
        .shadow(radius: 2)
        .padding(.bottom, 8)
        .transition(.opacity.combined(with: .scale))
    }
}
