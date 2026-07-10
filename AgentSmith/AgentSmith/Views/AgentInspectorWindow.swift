import SwiftUI
import AgentSmithKit

/// Standalone window showing full agent inspector detail for Smith or Brown.
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
        }
    }

    private var isProcessing: Bool { viewModel.processingRoles.contains(role) }
    private var executingTools: [String] {
        guard let counts = viewModel.toolExecutingByRole[role] else { return [] }
        var out: [String] = []
        for name in counts.keys.sorted() {
            for _ in 0..<(counts[name] ?? 0) { out.append(name) }
        }
        return out
    }
    private var availableTools: [String] { viewModel.agentToolNames[role] ?? [] }
    private var contextMessages: [LLMMessage] { viewModel.inspectorStore.contextMessages(for: role) }
    private var llmTurns: [LLMTurnRecord] { viewModel.inspectorStore.turnsByRole[role] ?? [] }

    /// True when the agent has activity history but no live tools — i.e. terminated.
    private var isTerminated: Bool {
        availableTools.isEmpty && !contextMessages.isEmpty
    }

    var body: some View {
        // Single-pass message bucketing per body, sharing InspectorView's rules
        // (role-attributed system diagnostics included, agent_online chrome excluded)
        // so the standalone window and the sidebar card never disagree.
        let roleMessages = InspectorView.bucketMessagesByRole(viewModel.messages)[role] ?? []
        let hasActivity = !roleMessages.isEmpty || viewModel.hasAgentActivity(role)
        let recentMessages = Array(roleMessages.suffix(10).reversed())
        let recentToolUses = Array(roleMessages.filter { $0.metadata?["tool"] != nil }.suffix(5).reversed())

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

            Divider()

            AgentInspectorWindowSections(
                role: role,
                availableTools: availableTools,
                recentToolUses: recentToolUses,
                recentMessages: recentMessages,
                contextMessages: contextMessages,
                llmTurns: llmTurns,
                expandedTurnIDs: $expandedTurnIDs,
                onSendDirectMessage: { [viewModel] text in
                    Task { await viewModel.sendDirectMessage(to: role, text: text) }
                }
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
