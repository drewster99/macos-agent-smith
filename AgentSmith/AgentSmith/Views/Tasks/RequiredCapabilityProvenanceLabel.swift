import SwiftUI
import AgentSmithKit

/// Marks a required capability that was added after the task was written: who added it, when, and
/// why. Shared by Task Detail and the task editor so a later addition reads the same everywhere.
struct RequiredCapabilityProvenanceLabel: View {
    let addedBy: TaskAuthorship
    let addedAt: Date
    let reason: String?

    var body: some View {
        Text(caption)
            .font(.caption)
            .foregroundStyle(AppColors.capabilityAddedLater)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var caption: String {
        let added = "Added later by \(addedBy.displayName), \(addedAt.formatted(date: .abbreviated, time: .shortened))"
        guard let reason else { return added }
        return "\(added) — \(reason)"
    }
}
