import SwiftUI
import AgentSmithKit

/// Scrolling content body for `AgentInspectorWindow`: tools, recent calls/messages,
/// context, LLM turns, and direct-message input. Mirrors AgentCardExpandedSections but
/// laid out at the larger window scale.
struct AgentInspectorWindowSections: View {
    let role: AgentRole
    let availableTools: [String]
    let recentToolUses: [ChannelMessage]
    let recentMessages: [ChannelMessage]
    let contextMessages: [LLMMessage]
    let llmTurns: [LLMTurnRecord]
    @Binding var expandedTurnIDs: Set<UUID>
    let onSendDirectMessage: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !availableTools.isEmpty {
                    InspectorSection(title: "Available Tools") {
                        AvailableToolsGrid(toolNames: availableTools)
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
                        .frame(maxHeight: 400)
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
                    .onAppear {
                        // Project rule: defer @State / @Binding mutations out of SwiftUI
                        // lifecycle closures so they can't race the active render pass.
                        if let last = llmTurns.last {
                            DispatchQueue.main.async { expandedTurnIDs.insert(last.id) }
                        }
                    }
                    .onChange(of: llmTurns.count) {
                        if let last = llmTurns.last {
                            DispatchQueue.main.async { expandedTurnIDs.insert(last.id) }
                        }
                    }
                }

                InspectorSection(title: "Direct Message") {
                    DirectMessageInputRow(
                        placeholder: "Message \(role.displayName) privately…",
                        onSend: onSendDirectMessage
                    )
                }
            }
            .padding(16)
        }
    }
}
