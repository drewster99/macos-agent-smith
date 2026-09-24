import SwiftUI
import SwiftLLMKit
import AgentSmithKit

/// The inspector window's body, routed by role. Every role shares the window shell
/// (`AgentInspectorWindow`: header, model/cost line, Done) and the shared section components;
/// only the sections themselves differ, because what each role's truth IS differs:
///
/// - Smith / Brown: a resident conversation — tools, messages, context, turns, direct message.
/// - Security Agent: evaluations plus the exact provider calls behind them; no direct message
///   (its message filter drops private messages).
struct AgentInspectorWindowContent: View {
    let viewModel: AppViewModel
    let role: AgentRole
    let roleMessages: [ChannelMessage]
    @Binding var expandedCallIDs: Set<UUID>

    var body: some View {
        switch role {
        case .smith, .brown:
            ResidentAgentInspectorContent(viewModel: viewModel, role: role, roleMessages: roleMessages,
                                          expandedCallIDs: $expandedCallIDs)
        case .securityAgent:
            SecurityAgentInspectorSections(
                evaluationRecords: viewModel.inspectorStore.evaluationRecords,
                evaluationLifetimeCount: viewModel.inspectorStore.evaluationLifetimeCount,
                recentMessages: Array(roleMessages.suffix(10).reversed()),
                callLog: viewModel.inspectorStore.callLogsByRole[.securityAgent],
                expandedCallIDs: $expandedCallIDs
            )
        case .validator, .summarizer:
            UnavailableInspectorContent(role: role)
        }
    }
}

/// Smith / Brown: the resident-agent sections.
private struct ResidentAgentInspectorContent: View {
    let viewModel: AppViewModel
    let role: AgentRole
    let roleMessages: [ChannelMessage]
    @Binding var expandedCallIDs: Set<UUID>

    var body: some View {
        AgentInspectorWindowSections(
            role: role,
            availableTools: viewModel.agentToolNames[role] ?? [],
            recentToolUses: Array(roleMessages.filter { $0.toolName != nil }.suffix(5).reversed()),
            recentMessages: Array(roleMessages.suffix(10).reversed()),
            contextMessages: viewModel.inspectorStore.contextMessages(for: role),
            callLog: viewModel.inspectorStore.callLogsByRole[role],
            expandedTurnIDs: $expandedCallIDs,
            onSendDirectMessage: { [viewModel] text in
                Task { await viewModel.sendDirectMessage(to: role, text: text) }
            }
        )
    }
}

/// Shown for a role whose inspector content has not been built. No card opens a window on such
/// a role; this exists so the switch is exhaustive without inventing content.
private struct UnavailableInspectorContent: View {
    let role: AgentRole

    var body: some View {
        Text("No inspector detail is available for \(role.displayName).")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Security Agent: its evaluations, its recent messages/errors, and the exact provider calls.
struct SecurityAgentInspectorSections: View {
    let evaluationRecords: [EvaluationRecord]
    let evaluationLifetimeCount: Int
    let recentMessages: [ChannelMessage]
    let callLog: InspectorCallLog?
    @Binding var expandedCallIDs: Set<UUID>

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if evaluationLifetimeCount > 0 {
                    SecurityEvaluationsSection(records: evaluationRecords, lifetimeCount: evaluationLifetimeCount,
                                               limit: nil, detail: .full)
                }
                if !recentMessages.isEmpty {
                    InspectorSection(title: "Recent Messages") {
                        ForEach(recentMessages) { message in
                            InspectorMessageRow(message: message)
                        }
                    }
                }
                if let callLog, callLog.lifetimeCount > 0 {
                    // Reviews arrive at tool-call frequency; auto-expanding each would churn.
                    LLMCallLogSection(log: callLog, expandedCallIDs: $expandedCallIDs, expandsNewestCall: false)
                }
            }
            .padding(16)
        }
    }
}

/// The window's model/configuration summary and session cost, beneath the header.
struct InspectorModelCostLine: View {
    let viewModel: AppViewModel
    let role: AgentRole

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let config = viewModel.resolvedAgentConfigs[role] {
                AgentCardModelInfoLine(
                    modelConfig: config,
                    llmTurns: viewModel.inspectorStore.retainedTurns(for: role),
                    role: role,
                    shared: viewModel.shared
                )
            }
            HStack(spacing: 6) {
                Text("Session cost")
                Spacer()
                Text(String(format: "$%.2f", viewModel.sessionCost(for: role)))
                    .monospacedDigit()
            }
            .foregroundStyle(.secondary)
        }
        .font(AppFonts.inspectorLabel)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}
