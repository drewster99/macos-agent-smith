import SwiftUI
import AgentSmithKit

/// All sections that appear under an `AgentCard` when it is expanded inline (Security Agent, the
/// only role that doesn't open in a separate window). Drives `Available Tools`, security
/// `Evaluations` (Security Agent only), `Recent Tool Calls`, `Recent Messages`, `Context`, the
/// `LLM Turns` disclosure list, and the per-agent `Direct Message` input.
struct AgentCardExpandedSections: View {
    let role: AgentRole
    let availableTools: [String]
    let evaluationRecords: [EvaluationRecord]
    let recentToolUses: [ChannelMessage]
    let recentMessages: [ChannelMessage]
    let contextMessages: [LLMMessage]
    let llmTurns: [LLMTurnRecord]
    @Binding var expandedTurnIDs: Set<UUID>
    let onSendDirectMessage: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !availableTools.isEmpty {
                InspectorSection(title: "Available Tools") {
                    AvailableToolsGrid(toolNames: availableTools)
                }
            }

            // Security Agent: evaluations are the primary work product, surface above tool calls.
            if role == .securityAgent && !evaluationRecords.isEmpty {
                InspectorSection(title: "Security Evaluations (\(evaluationRecords.count))") {
                    ForEach(Array(evaluationRecords.suffix(10).reversed())) { record in
                        EvaluationRecordRow(record: record)
                    }
                }
            }

            if !recentToolUses.isEmpty {
                InspectorSection(title: "Recent Tool Calls") {
                    ForEach(recentToolUses) { msg in
                        InspectorToolRow(message: msg)
                    }
                }
            }

            if !recentMessages.isEmpty {
                InspectorSection(title: "Recent Messages") {
                    ForEach(recentMessages) { msg in
                        InspectorMessageRow(message: msg)
                    }
                }
            }

            if !contextMessages.isEmpty {
                InspectorSection(title: "Context (\(contextMessages.count) entries)") {
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(contextMessages.indices, id: \.self) { i in
                                ContextMessageRow(message: contextMessages[i])
                            }
                        }
                    }
                    .frame(maxHeight: 300)
                }
            }

            if !llmTurns.isEmpty {
                InspectorSection(title: "LLM Turns (\(llmTurns.count))") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(llmTurns.enumerated()), id: \.element.id) { i, turn in
                            LLMTurnDisclosureRow(
                                turn: turn,
                                turnNumber: i + 1,
                                isExpanded: expandedTurnIDs.contains(turn.id),
                                onExpandedChange: { expand in
                                    if expand { expandedTurnIDs.insert(turn.id) }
                                    else { expandedTurnIDs.remove(turn.id) }
                                }
                            )
                            .equatable()
                        }
                    }
                }
                // Turns are added collapsed; the user expands the ones they want to read. (We
                // used to auto-expand the latest turn on every new turn, which made a streaming
                // Security Agent's turn list churn open messily.)
            }

            // Direct message input — hidden for Security Agent since its filter drops private messages.
            if role != .securityAgent {
                InspectorSection(title: "Direct Message") {
                    DirectMessageInputRow(
                        placeholder: "Message \(role.displayName) privately…",
                        onSend: onSendDirectMessage
                    )
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }
}
