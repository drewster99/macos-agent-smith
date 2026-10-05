import SwiftUI
import AgentSmithKit

/// Standalone inspector window — the one shell every role's inspector opens in. Role-specific
/// sections come from `AgentInspectorWindowContent`.
struct AgentInspectorWindow: View {
    let viewModel: AppViewModel
    let role: AgentRole
    @Environment(\.dismiss) private var dismiss

    @State private var expandedTurnIDs: Set<UUID> = []

    private var roleColor: Color { AppColors.color(for: .agent(role)) }

    private var inspectorDisplayName: String {
        switch role {
        case .smith: return "Agent Smith"
        case .brown: return "Agent Brown"
        case .securityAgent: return "Security Agent"
        case .summarizer: return "Summarizer"
        case .validator: return role.displayName
        }
    }

    private var isProcessing: Bool {
        role == .securityAgent ? viewModel.isSecurityAgentBusy : viewModel.processingRoles.contains(role)
    }
    private var executingTools: [String] {
        guard let counts = viewModel.toolExecutingByRole[role] else { return [] }
        var out: [String] = []
        for name in counts.keys.sorted() {
            for _ in 0..<(counts[name] ?? 0) { out.append(name) }
        }
        return out
    }
    private var availableTools: [String] { viewModel.agentToolNames[role] ?? [] }

    /// True when a resident agent (Smith / Brown) has activity history but no live tools — i.e.
    /// terminated. The other roles never hold tools, so the test would misread them as terminated.
    private var isTerminated: Bool {
        guard role == .smith || role == .brown else { return false }
        return availableTools.isEmpty && !viewModel.inspectorStore.contextMessages(for: role).isEmpty
    }

    var body: some View {
        // Single-pass message bucketing per body, sharing InspectorView's rules
        // (role-attributed system diagnostics included) so the standalone window
        // and the sidebar card never disagree.
        let roleMessages = InspectorLiveState.bucketMessagesByRole(viewModel.messages)[role] ?? []
        // The Validator has no messages or call log of its own; like its card, its dot says whether
        // a model is assigned to judge with.
        let hasActivity = role == .validator
            ? viewModel.resolvedAgentConfigs[.validator] != nil
            : !roleMessages.isEmpty || viewModel.hasAgentActivity(role)

        return VStack(spacing: 0) {
            AgentInspectorWindowHeader(
                role: role,
                displayName: inspectorDisplayName,
                roleColor: roleColor,
                hasActivity: hasActivity,
                isProcessing: isProcessing,
                isTerminated: isTerminated,
                executingTools: executingTools,
                processingStartDate: viewModel.inspectorLive.processingSince[role],
                toolExecutingStartDate: viewModel.inspectorLive.toolsRunningSince[role],
                providerWaits: viewModel.inspectorLive.providerWaitsByRole[role] ?? [],
                onDone: { dismiss() }
            )
            InspectorModelCostLine(viewModel: viewModel, role: role)

            Divider()

            AgentInspectorWindowContent(
                viewModel: viewModel,
                role: role,
                roleMessages: roleMessages,
                expandedCallIDs: $expandedTurnIDs
            )
        }
        .frame(minWidth: 600, idealWidth: 800, minHeight: 500, idealHeight: 700)
        .onAppear {
            // This window can open before the sidebar inspector ever has (e.g. from
            // `SummarizerCard`/`ValidatorAgentCard`'s own pop-out button), so it must activate the
            // shared derived state itself. Idempotent — a no-op if the sidebar already did.
            viewModel.inspectorLive.activate()
        }
    }

}
