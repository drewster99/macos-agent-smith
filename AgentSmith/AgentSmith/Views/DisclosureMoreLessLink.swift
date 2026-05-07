import SwiftUI

/// `(more)` / `(less)` text link used in the lower-right of any expandable section
/// or row in the Task Detail window. The internal `Spacer` pins the link to the
/// trailing edge so callers don't need to wrap it.
struct DisclosureMoreLessLink: View {
    let isExpanded: Bool
    var font: Font = .callout
    let action: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button(action: action) {
                Text(isExpanded ? "(less)" : "(more)")
                    .font(font)
                    .foregroundStyle(AppColors.moreLessLink)
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
        }
    }
}
