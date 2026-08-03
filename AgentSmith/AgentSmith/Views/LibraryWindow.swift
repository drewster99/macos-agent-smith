import SwiftUI
import AgentSmithKit

/// A pop-out window for the global template Library — the same grouped templates as the sidebar
/// section, in a dedicated resizable window. Uses the focused session's view model for run history and
/// group operations; the Library itself is global, so every window sees the same templates live.
struct LibraryWindow: View {
    let viewModel: AppViewModel

    var body: some View {
        Group {
            if viewModel.libraryTemplates.isEmpty {
                ContentUnavailableView(
                    "No Templates",
                    systemImage: "books.vertical",
                    description: Text("Templates you create appear here, grouped and reusable.")
                )
            } else {
                ScrollView {
                    LibrarySectionView(viewModel: viewModel)
                        .padding(.bottom, 12)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 400)
        .navigationTitle("Library")
    }
}
