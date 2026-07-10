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
    private var senderLabel: String {
        if case .agent(.brown) = message.sender,
           case .string(let title)? = message.metadata?["senderTaskTitle"] {
            return Self.truncatedTitle(title)
        }
        return message.sender.displayName
    }

    private var recipientLabel: String {
        if case .agent(.brown)? = message.recipient {
            if case .string(let title)? = message.metadata?["recipientTaskTitle"] {
                return Self.truncatedTitle(title)
            }
            if case .string(let title)? = message.metadata?["taskTitle"] {
                return Self.truncatedTitle(title)
            }
        }
        return message.recipient?.displayName ?? "private"
    }

    private static func truncatedTitle(_ title: String) -> String {
        title.count <= 48 ? title : String(title.prefix(48)) + "…"
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(senderLabel)
                .font(AppFonts.channelSender)
                .foregroundStyle(senderColor)

            if message.isPrivate && !hidesPrivateRecipientAnnotation {
                Image(systemName: "lock.fill")
                    .font(AppFonts.metaIcon)
                    .foregroundStyle(.secondary)
                Text("\u{2192} \(recipientLabel)")
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
