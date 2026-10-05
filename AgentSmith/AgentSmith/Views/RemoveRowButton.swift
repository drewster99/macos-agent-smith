import SwiftUI

/// Icon-only "remove this row" button for editor lists. `title` is both the accessibility label and
/// the tooltip, so VoiceOver reads "Remove step" rather than "minus circle".
struct RemoveRowButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action, label: {
            Label(title, systemImage: "minus.circle")
                .labelStyle(.iconOnly)
        })
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(title)
    }
}
