import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Text input area for `UserInputView`. Wraps a `TextEditor` with a placeholder overlay
/// and the keyboard-handling behaviour (Enter sends, Shift/Opt+Enter inserts newline,
/// arrows navigate history, ⌘V intercepts non-text clipboards).
struct UserInputTextField: View {
    @Binding var text: String
    let isRunning: Bool
    let pendingAttachmentCount: Int
    let onSend: () -> Void
    let onHistoryUp: () -> Bool
    let onHistoryDown: () -> Bool
    let onPaste: () -> Bool

    /// Approximate line height for the input font, used to size the TextEditor.
    private let lineHeight: CGFloat = 18
    /// Vertical padding inside the TextEditor (top + bottom).
    private let verticalPadding: CGFloat = 12
    private var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pendingAttachmentCount > 0
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(isRunning ? "Message Agent Smith..." : "Press Start to begin messaging...")
                    .font(AppFonts.inputField)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $text)
                .font(AppFonts.inputField)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(height: lineHeight * 5 + verticalPadding)
        }
        .background(AppColors.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onKeyPress(.return, phases: .down) { keyPress in
            // Shift+Enter or Option+Enter: insert newline (let through)
            if keyPress.modifiers.contains(.shift) || keyPress.modifiers.contains(.option) {
                return .ignored
            }
            // Plain Enter: send message
            if isRunning && hasContent {
                onSend()
            }
            return .handled
        }
        .onKeyPress(.upArrow) {
            // Only use history navigation when text is empty or single-line
            guard text.isEmpty || !text.contains("\n") else { return .ignored }
            return onHistoryUp() ? .handled : .ignored
        }
        .onKeyPress(.downArrow) {
            guard text.isEmpty || !text.contains("\n") else { return .ignored }
            return onHistoryDown() ? .handled : .ignored
        }
        .onKeyPress(characters: .init(charactersIn: "v"), phases: .down, action: { keyPress in
            guard keyPress.modifiers == .command else { return .ignored }
            // Only intercept if the clipboard has non-text content (images/files).
            // Let normal text paste through to the TextEditor.
            let pasteboard = NSPasteboard.general
            let hasFiles = pasteboard.canReadObject(forClasses: [NSURL.self], options: [
                .urlReadingFileURLsOnly: true
            ])
            let hasImage = pasteboard.data(forType: .tiff) != nil
            guard hasFiles || hasImage else { return .ignored }
            return onPaste() ? .handled : .ignored
        })
    }
}
