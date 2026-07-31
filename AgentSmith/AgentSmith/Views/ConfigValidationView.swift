import SwiftUI
import SwiftLLMKit
import AgentSmithKit

/// Startup gate that validates all agent configurations before allowing the system to start.
struct ConfigValidationView: View {
    let viewModel: AppViewModel
    let onStart: () -> Void
    let onDismiss: () -> Void

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "gear.badge.checkmark")
                .font(AppFonts.welcomeIcon)
                .foregroundStyle(.secondary)

            Text("Configuration Check")
                .font(.title2.bold())

            Text("Verify each agent has a valid model configuration before starting.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 8) {
                agentRow(role: .smith, label: "Agent Smith (Orchestrator)", color: AppColors.smithAgent)
                agentRow(role: .brown, label: "Agent Brown (Executor)", color: AppColors.brownAgent)
                agentRow(role: .securityAgent, label: "Security Agent (Safety Monitor)", color: AppColors.securityAgent)
                agentRow(role: .summarizer, label: "Task Summarizer", color: .secondary)
            }

            HStack(spacing: 12) {
                Button("Open Settings") {
                    onDismiss()
                    openSettings()
                }
                Button("Start") { onStart() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!viewModel.allAgentConfigsValid)
            }
            .padding(.top, 8)
        }
        .padding(24)
        // Sized ~40% wider and ~50% taller than the old content-hugging sheet (was ~480×490):
        // multi-line validation errors ("Max output tokens (500000) exceeds model limit…") need
        // the room, and the old minWidth-only frame clipped them.
        .frame(minWidth: 670, minHeight: 730)
    }

    private func agentRow(role: AgentRole, label: String, color: Color) -> some View {
        let assignment = viewModel.agentAssignments[role]
        let provider = assignment.flatMap { a in viewModel.shared.llmKit.providers.first { $0.id == a.providerID } }
        let hasModel = (assignment?.modelID.isEmpty == false)

        return GroupBox {
            HStack {
                Label(label, systemImage: "person.circle")
                    .foregroundStyle(color)
                    .font(.headline)

                Spacer()

                if let assignment, hasModel {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(provider.map { "\(assignment.modelID)  ·  \($0.name)" } ?? assignment.modelID)
                            .font(.subheadline)
                        if provider != nil {
                            Label("Valid", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            Label("Provider not configured", systemImage: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                } else {
                    Label("No model assigned", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(4)
        }
    }
}
