import SwiftUI

/// Left-hand sidebar of `MainView` — auto-run toggles and the scrolling task list.
struct MainViewSidebar: View {
    @Bindable var viewModel: AppViewModel
    let onCreateTask: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
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

            Toggle("Auto-run next task", isOn: $viewModel.autoRunNextTask)
                .font(.caption)
                .padding(.horizontal, 12)

            Toggle("Auto-run interrupted tasks", isOn: $viewModel.autoRunInterruptedTasks)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)

            ScrollView {
                TaskListView(viewModel: viewModel)
            }
        }
        .navigationSplitViewColumnWidth(min: 250, ideal: 300)
    }
}
