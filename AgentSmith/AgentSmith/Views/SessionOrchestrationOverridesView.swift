import SwiftUI
import AgentSmithKit

/// The per-session orchestration overrides sheet, opened from Session ▸ Orchestration Overrides.
/// Same form as the app-wide Settings tab, but bound to THIS session's override and resolved against
/// the app-wide effective default — so the "Resolved" value on each row is exactly what this
/// session's agents will use. `nil`/empty override means the session inherits the app-wide settings.
struct SessionOrchestrationOverridesView: View {
    @Bindable var viewModel: AppViewModel
    let onDone: () -> Void

    var body: some View {
        let target = OrchestrationOverrideTarget.session(viewModel)
        return VStack(alignment: .leading, spacing: 0) {
            SessionOverridesTitleBar(sessionName: viewModel.session.name, onDone: onDone)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SessionOverridesExplanationRow(target: target)
                    OrchestrationOverrideForm(target: target)
                }
                .padding()
            }
        }
        .frame(minWidth: 580, minHeight: 640)
    }
}

struct SessionOverridesTitleBar: View {
    let sessionName: String
    let onDone: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Orchestration Overrides").font(.title3.bold())
                Text(sessionName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Done", action: onDone).keyboardShortcut(.defaultAction)
        }
        .padding()
    }
}

struct SessionOverridesExplanationRow: View {
    let target: OrchestrationOverrideTarget

    var body: some View {
        HStack(alignment: .top) {
            Text("Overrides for this session only. Each row inherits the app-wide default unless you force it on or off; the resolved value each agent will use is shown on the right.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Reset to defaults") { target.reset() }
                .disabled(target.isEmpty)
        }
    }
}
