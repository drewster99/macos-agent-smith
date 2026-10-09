import SwiftUI
import AgentSmithKit

/// Single-view per ForEach iteration in the scheduled-runs popover — bundles the wake
/// row with its trailing divider so the ForEach yields one view per wake.
struct ScheduledRunsPopoverItem: View {
    let wake: ScheduledWake
    /// False for a wake another session's scheduler owns: only that session can cancel it.
    let isCancellable: Bool
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScheduledRunsPopoverRow(wake: wake, isCancellable: isCancellable, onCancel: onCancel)
            Divider()
        }
    }
}
