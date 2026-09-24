import SwiftUI
import AgentSmithKit

/// Standalone inspector window — the one shell every role's inspector opens in. Role-specific
/// sections come from `AgentInspectorWindowContent`.
struct AgentInspectorWindow: View {
    let viewModel: AppViewModel
    let role: AgentRole
    @Environment(\.dismiss) private var dismiss

    @State private var expandedTurnIDs: Set<UUID> = []
    @State private var processingStartDate: Date?
    @State private var toolExecutingStartDate: Date?

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

    /// True when the agent has activity history but no live tools — i.e. terminated.
    private var isTerminated: Bool {
        availableTools.isEmpty && !viewModel.inspectorStore.contextMessages(for: role).isEmpty
    }

    var body: some View {
        // Single-pass message bucketing per body, sharing InspectorView's rules
        // (role-attributed system diagnostics included) so the standalone window
        // and the sidebar card never disagree.
        let roleMessages = InspectorView.bucketMessagesByRole(viewModel.messages)[role] ?? []
        let hasActivity = !roleMessages.isEmpty || viewModel.hasAgentActivity(role)

        return VStack(spacing: 0) {
            AgentInspectorWindowHeader(
                role: role,
                displayName: inspectorDisplayName,
                roleColor: roleColor,
                hasActivity: hasActivity,
                isProcessing: isProcessing,
                isTerminated: role != .securityAgent && isTerminated,
                executingTools: executingTools,
                processingStartDate: processingStartDate,
                toolExecutingStartDate: toolExecutingStartDate,
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
            // Project rule: defer @State mutations out of lifecycle closures.
            if isProcessing {
                DispatchQueue.main.async { processingStartDate = Date() }
            }
            if !executingTools.isEmpty {
                DispatchQueue.main.async { toolExecutingStartDate = Date() }
            }
        }
        .onChange(of: isProcessing) { _, newValue in
            DispatchQueue.main.async {
                processingStartDate = newValue ? Date() : nil
            }
        }
        .onChange(of: executingTools.isEmpty) { _, isEmpty in
            DispatchQueue.main.async {
                toolExecutingStartDate = isEmpty ? nil : Date()
            }
        }
    }

}
