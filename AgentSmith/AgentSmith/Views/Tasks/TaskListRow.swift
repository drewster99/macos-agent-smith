import SwiftUI
import AgentSmithKit

/// Single-view per ForEach iteration in the sidebar task list — bundles the row's
/// click button with its trailing divider so the ForEach yields one view per task.
struct TaskListRow: View {
    let task: AgentTask
    let style: TaskRowStyle
    let density: TaskRowDensity
    var disclosure: TaskRunListDisclosure?
    /// Leading inset for nested rows. Applied INSIDE the row's button so the indent strip
    /// stays part of the click and context-menu target — as outer padding it looked like the
    /// row but silently swallowed clicks landing on it.
    var indent: CGFloat = 0
    let viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TaskRowButton(
                task: task,
                style: style,
                density: density,
                disclosure: disclosure,
                indent: indent,
                viewModel: viewModel
            )
            // Compact rows appear in dense runs (a template's history). A rule between every
            // one turns the block into a ladder of lines carrying no information; the shared
            // tinted background is what groups them. Standard cards still get their divider.
            if density == .standard {
                Divider()
            }
        }
    }
}
