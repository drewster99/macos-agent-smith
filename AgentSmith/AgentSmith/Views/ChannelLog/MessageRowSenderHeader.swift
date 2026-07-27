import SwiftUI
import AgentSmithKit

/// Top header for a `MessageRow`: sender name, optional private-recipient annotation,
/// optional timestamp, and an optional elapsed-time chip for tool-call rows.
struct MessageRowSenderHeader: View {
    let message: ChannelMessage
    let senderColor: Color
    let recipientColor: Color
    let hidesPrivateRecipientAnnotation: Bool
    let shouldShowTimestamp: Bool
    let isToolRequest: Bool
    let displayPrefs: TimestampPreferences
    let toolCallElapsedSeconds: TimeInterval?

    /// Workers are labeled by their TASK, not the bare role name — "Brown" is ambiguous
    /// once several run concurrently. Falls back to the role name for unstamped
    /// messages (pre-feature history, task-less spawns).

    var body: some View {
        let _senderLabel: String = {
            if case .agent(.brown) = message.sender,
               case .string(let title)? = message.metadata?["senderTaskTitle"] {
                return title.count <= 48 ? title : String(title.prefix(48)) + "…"
            }
            return message.sender.displayName
        }()
        let _recipientLabel: String = {
            if case .agent(.brown)? = message.recipient {
                if case .string(let title)? = message.metadata?["recipientTaskTitle"] {
                    return title.count <= 48 ? title : String(title.prefix(48)) + "…"
                }
                if case .string(let title)? = message.metadata?["taskTitle"] {
                    return title.count <= 48 ? title : String(title.prefix(48)) + "…"
                }
            }
            return message.recipient?.displayName ?? "private"
        }()
        return HStack(spacing: 6) {
            Text(_senderLabel)
                .font(AppFonts.channelSender)
                .foregroundStyle(senderColor)

            if message.isPrivate && !hidesPrivateRecipientAnnotation {
                Image(systemName: "lock.fill")
                    .font(AppFonts.metaIcon)
                    .foregroundStyle(.secondary)
                Text("\u{2192} \(_recipientLabel)")
                    .font(AppFonts.channelTimestamp)
                    .foregroundStyle(recipientColor)
            }

            if shouldShowTimestamp {
                Text(sharedTimestampFormatter.string(from: message.timestamp))
                    .font(AppFonts.channelTimestamp)
                    .foregroundStyle(.secondary)
            }

            if isToolRequest, displayPrefs.elapsedTimeOnToolCalls,
               let elapsed = toolCallElapsedSeconds {
                Text(formatToolCallElapsed(elapsed))
                    .font(AppFonts.channelTimestamp)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
