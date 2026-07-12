import SwiftUI

/// Pill button that grows the channel log's rendered window backwards, revealing older
/// messages that are already in memory but withheld from the view tree.
///
/// The channel log only ever materializes a bounded tail of `messages` (see
/// `ChannelLogView`), so an arbitrarily long transcript can't flood CoreAnimation with
/// tens of thousands of layers. This button lets the user page further back on demand,
/// one bounded chunk at a time, keeping the app responsive between clicks.
struct ChannelLogLoadEarlierButton: View {
    let hiddenEarlierCount: Int
    let onLoadEarlier: () -> Void

    var body: some View {
        Button(action: onLoadEarlier, label: {
            Text("Load earlier messages (\(hiddenEarlierCount) more)")
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.quaternary)
                .clipShape(Capsule())
        })
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.bottom, 4)
    }
}
