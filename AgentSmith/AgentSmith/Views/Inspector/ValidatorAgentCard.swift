import SwiftUI
import SwiftLLMKit
import AgentSmithKit

/// Inspector card for the acceptance-validator model slot, matching the other agent cards'
/// visual grammar (activity dot, role-colored name, status, model-info line, session cost, and
/// a gear that opens the model picker).
///
/// A validator is not a resident agent — it exists for the duration of one criterion's
/// evaluation — so it has no system prompt, poll interval, tool budget, speech, or inspector
/// window. What it does have is a model assignment, and that assignment has no fallback: leave
/// it empty and submitted tasks park unvalidated. This card is where that model is chosen
/// outside first-run onboarding.
struct ValidatorAgentCard: View {
    @Bindable var viewModel: AppViewModel

    @State private var showingConfig = false

    private static let roleColor = AppColors.validatorAgent

    private var assignedConfig: ModelConfiguration? {
        guard let id = viewModel.agentAssignments[.validator] else { return nil }
        return viewModel.shared.llmKit.configurations.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header()

            if let config = assignedConfig {
                AgentCardModelInfoLine(modelConfig: config, llmTurns: [], role: .validator, shared: viewModel.shared)
                    .padding(.leading, 28)
                    .padding(.trailing, 12)
                    .padding(.bottom, 6)
            } else {
                Label("No model assigned — submitted tasks park unvalidated until one is set.", systemImage: "exclamationmark.triangle.fill")
                    .font(AppFonts.inspectorLabel)
                    .foregroundStyle(.orange)
                    .padding(.leading, 28)
                    .padding(.trailing, 12)
                    .padding(.bottom, 6)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                Text("Session")
                Spacer()
                Text(String(format: "$%.2f", viewModel.sessionCost(for: .validator)))
                    .monospacedDigit()
            }
            .font(AppFonts.inspectorLabel)
            .foregroundStyle(.tertiary)
            .padding(.leading, 28)
            .padding(.trailing, 12)
            .padding(.bottom, 10)

            Divider()
        }
        .sheet(isPresented: $showingConfig) {
            ValidatorConfigSheet(viewModel: viewModel, roleColor: Self.roleColor)
        }
    }

    private func header() -> some View {
        let hasModel = assignedConfig != nil
        return HStack(spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(hasModel ? Self.roleColor : AppColors.inactiveDot)
                    .frame(width: 8, height: 8)

                Text(AgentRole.validator.displayName)
                    .font(.headline)
                    .foregroundStyle(hasModel ? Self.roleColor : .secondary)

                Spacer()

                Text(hasModel ? "Per-criterion" : "No model")
                    .font(AppFonts.inspectorLabel)
                    .foregroundStyle(.tertiary)
            }

            Button(action: { showingConfig = true }, label: {
                Image(systemName: "gearshape")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            })
            .buttonStyle(.plain)
            .padding(.leading, 4)
            .help("Configure the validator model")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// Model picker for the acceptance validator. Deliberately narrower than `AgentConfigSheet`:
/// the validator has no system prompt, poll interval, or tool budget to configure — only a model.
private struct ValidatorConfigSheet: View {
    @Bindable var viewModel: AppViewModel
    let roleColor: Color
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(AgentRole.validator.displayName) Configuration")
                    .font(.title3.bold())
                    .foregroundStyle(roleColor)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("The acceptance validator judges completed work against each task's criteria. It runs per-criterion and has no conversation, tools, or speech of its own — only a model. With none assigned, submitted tasks park unvalidated until you pick one.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    AgentModelSettingsSection(viewModel: viewModel, role: .validator)
                }
                .padding(20)
            }
        }
        .frame(minWidth: 540, minHeight: 420)
    }
}
