import SwiftUI

/// A short inline refusal or validation problem, shown beside the control it concerns rather than in
/// an alert. Draws nothing when `message` is nil.
struct InlineProblemText: View {
    let message: String?

    var body: some View {
        if let message {
            Text(message)
                .font(.caption)
                .foregroundStyle(AppColors.verdictError)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}
