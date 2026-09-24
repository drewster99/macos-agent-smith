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
/// - Validator: the task verdict ledgers — it has no resident conversation.
/// - Summarizer: its operations and the exact provider calls behind them.
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
            SecurityAgentInspectorContent(viewModel: viewModel, roleMessages: roleMessages,
                                          expandedCallIDs: $expandedCallIDs)
        case .validator:
            ValidatorInspectorSections(viewModel: viewModel)
        case .summarizer:
            SummarizerInspectorSections(
                callLog: viewModel.inspectorStore.callLogsByRole[.summarizer],
                recentMessages: Array(roleMessages.reversed()), expandedCallIDs: $expandedCallIDs)
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

/// Reads the Security Agent's slice of the inspector store for its sections.
private struct SecurityAgentInspectorContent: View {
    let viewModel: AppViewModel
    let roleMessages: [ChannelMessage]
    @Binding var expandedCallIDs: Set<UUID>

    var body: some View {
        SecurityAgentInspectorSections(
            evaluationRecords: viewModel.inspectorStore.evaluationRecords,
            evaluationLifetimeCount: viewModel.inspectorStore.evaluationLifetimeCount,
            recentMessages: Array(roleMessages.suffix(10).reversed()),
            callLog: viewModel.inspectorStore.callLogsByRole[.securityAgent],
            expandedCallIDs: $expandedCallIDs
        )
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
            if let config = viewModel.inspectorResolvedAgentConfigs[role] {
                AgentCardModelInfoLine(
                    modelConfig: config,
                    llmTurns: viewModel.inspectorStore.retainedTurns(for: role),
                    role: role,
                    shared: viewModel.shared,
                    evictedCallCount: viewModel.inspectorStore.callLogsByRole[role]?.evictedCount ?? 0,
                    recordsPerCallStats: role != .validator
                )
            }
            InspectorSessionCostRow(cost: viewModel.sessionCost(for: role))
        }
        .font(AppFonts.inspectorLabel)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

private struct InspectorSessionCostRow: View {
    let cost: Double

    var body: some View {
        HStack(spacing: 6) {
            Text("Session cost")
            Spacer()
            Text(String(format: "$%.2f", cost))
                .monospacedDigit()
        }
        .foregroundStyle(.secondary)
    }
}
