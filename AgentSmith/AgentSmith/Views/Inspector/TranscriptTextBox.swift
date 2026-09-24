import SwiftUI

/// A titled, selectable, scrollable block of exact transcript text — a prompt as sent, the
/// evidence a judge saw, a response log. The one rendering shared by Task Detail and the
/// inspector windows, so the same record never reads two different ways.
struct TranscriptTextBox<Accessory: View>: View {
    let title: String
    let text: String
    let maxHeight: CGFloat
    /// Trailing header control (e.g. a copy button); `EmptyView` for none.
    let accessory: Accessory

    init(title: String, text: String, maxHeight: CGFloat = 220, accessory: Accessory) {
        self.title = title
        self.text = text
        self.maxHeight = maxHeight
        self.accessory = accessory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                accessory
            }
            ScrollView(.vertical) {
                Text(text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(maxHeight: maxHeight)
            .background(AppColors.secondaryBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

extension TranscriptTextBox where Accessory == EmptyView {
    init(title: String, text: String, maxHeight: CGFloat = 220) {
        self.init(title: title, text: text, maxHeight: maxHeight, accessory: EmptyView())
    }
}
