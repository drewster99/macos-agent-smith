import SwiftUI

/// Left-hand sidebar of `MainView` — auto-run toggles and the scrolling task list.
struct MainViewSidebar: View {
    @Bindable var viewModel: AppViewModel
    let onCreateTask: () -> Void
    /// Opens THIS session's orchestration overrides (plain gear click).
    let onOpenSessionOrchestration: () -> Void
    /// Opens the app-wide orchestration Settings tab (⌘-click on the gear).
    let onOpenGlobalOrchestration: () -> Void

    /// Whether ⌘ is currently held, so the gear's action AND its tooltip switch between the
    /// per-session sheet and the global settings tab.
    @State private var orchestrationGearCommandHeld = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button {
                    if orchestrationGearCommandHeld { onOpenGlobalOrchestration() }
                    else { onOpenSessionOrchestration() }
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .onModifierKeysChanged(mask: .command) { _, newKeys in
                    orchestrationGearCommandHeld = newKeys.contains(.command)
                }
                .help(orchestrationGearCommandHeld
                    ? "Global orchestration settings"
                    : "Session orchestration settings  (⌘-click for global)")

                Text("Tasks")
                    .font(AppFonts.sectionHeader)
                Spacer()
                Button(action: onCreateTask, label: {
                    Label("Create Task", systemImage: "plus.circle")
                })
                .controlSize(.small)
            }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

            ScrollView {
                TaskListView(viewModel: viewModel)
            }
        }
        .navigationSplitViewColumnWidth(min: 250, ideal: 300)
    }
}
