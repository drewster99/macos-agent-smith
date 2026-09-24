import SwiftUI
import AgentSmithKit

/// Scrolling content for a resident agent's (Smith / Brown) inspector window: tools, recent
/// calls/messages, context, LLM turns, and direct-message input.
struct AgentInspectorWindowSections: View {
    let role: AgentRole
    let availableTools: [String]
    let recentToolUses: [ChannelMessage]
    let recentMessages: [ChannelMessage]
    let contextMessages: [LLMMessage]
    let callLog: InspectorCallLog?
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

                if let callLog, callLog.lifetimeCount > 0 {
                    LLMCallLogSection(log: callLog, expandedCallIDs: $expandedTurnIDs, expandsNewestCall: true)
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
