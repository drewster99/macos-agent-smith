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
        .frame(minWidth: 400)
    }

    private func agentRow(role: AgentRole, label: String, color: Color) -> some View {
        let configID = viewModel.agentAssignments[role]
        let config = configID.flatMap { id in viewModel.shared.llmKit.configurations.first { $0.id == id } }

        return GroupBox {
            HStack {
                Label(label, systemImage: "person.circle")
                    .foregroundStyle(color)
                    .font(.headline)

                Spacer()

                if let config {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(config.name)
                            .font(.subheadline)
                        if config.isValid {
                            Label("Valid", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            Label(config.validationError ?? "Invalid", systemImage: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                } else {
                    Label("No configuration assigned", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(4)
        }
    }
}
