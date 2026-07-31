import AppKit
import SwiftUI

/// A native macOS search field (`NSSearchField`) bridged to SwiftUI. Gives the magnifying-glass
/// affordance and the built-in clear (✕) button that a plain SwiftUI `TextField` lacks, and reports
/// every keystroke (and the clear button) through the binding for realtime filtering.
struct MacSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = "Search"
    /// Tooltip shown on hover — a good place for detailed search-syntax help.
    var help: String?

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.toolTip = help
        field.delegate = context.coordinator
        // The delegate covers realtime typing; the target/action also catches the clear (✕) button
        // and Return, which don't always post a text-did-change notification.
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchFieldChanged(_:))
        // Let the field stretch to fill the row rather than sit at its intrinsic width.
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
        field.placeholderString = placeholder
        field.toolTip = help
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        // Fires on every keystroke for realtime filtering.
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }

        // Fires on the clear (✕) button and Return — belt-and-suspenders for events the text-change
        // notification may skip.
        @objc func searchFieldChanged(_ sender: NSSearchField) {
            text.wrappedValue = sender.stringValue
        }
    }
}
