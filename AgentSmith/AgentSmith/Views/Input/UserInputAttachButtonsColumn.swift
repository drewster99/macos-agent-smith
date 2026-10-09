import SwiftUI

/// Vertical stack of attach (paperclip) and expanded-editor (pencil) buttons that sits to
/// the left of the message text editor.
struct UserInputAttachButtonsColumn: View {
    let isEnabled: Bool
    let onAttach: () -> Void
    let onExpand: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Button(action: onAttach, label: {
                Image(systemName: "paperclip")
                    .imageScale(.large)
            })
            .accessibilityLabel("Attach file")
            .buttonStyle(.borderless)
            .disabled(!isEnabled)

            Button(action: onExpand, label: {
                Image(systemName: "square.and.pencil")
                    .imageScale(.large)
            })
            .accessibilityLabel("Open expanded editor")
            .buttonStyle(.borderless)
            .disabled(!isEnabled)
            .help("Open expanded editor")
        }
    }
}
