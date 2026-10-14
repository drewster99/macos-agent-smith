import SwiftUI
import SwiftLLMKit

/// A list of LLM context messages — an agent's live context, a call's outgoing messages, a turn's
/// full snapshot — in a `HostedRowsTable`. These run to hundreds of messages; as SwiftUI stacks
/// they laid out every one on every turn, which is what made the inspector sluggish.
struct ContextMessagesTable: View {
    let messages: [LLMMessage]
    /// Show "#n" before each row.
    var numbered = false
    /// Rows start expanded. A change rebuilds every row in the new state.
    var expandedByDefault = false
    /// Keep the newest message in view as the list grows (a live context).
    var followsTail = false
    /// An extra message after the list, under a caption — a turn's response below its context.
    var trailing: (caption: String, message: LLMMessage)?
    /// The rows' total height, as it changes — for sizing a short list to its content.
    var onContentHeightChange: ((CGFloat) -> Void)?

    var body: some View {
        HostedRowsTable(
            rows: rows,
            followsTail: followsTail,
            identityRevision: expandedByDefault,
            rowInsets: EdgeInsets(top: 1, leading: 0, bottom: 2, trailing: 0),
            onContentHeightChange: onContentHeightChange,
            rowContent: { row in ContextMessageListRowView(row: row) }
        )
    }

    private var rows: [ContextMessageListRow] {
        var rows = messages.enumerated().map { index, message in
            ContextMessageListRow(position: index, message: message, number: numbered ? index + 1 : nil,
                                  caption: nil, expandedByDefault: expandedByDefault)
        }
        if let trailing {
            rows.append(ContextMessageListRow(position: messages.count, message: trailing.message,
                                              number: numbered ? messages.count + 1 : nil,
                                              caption: trailing.caption, expandedByDefault: expandedByDefault))
        }
        return rows
    }
}

/// One message in a `ContextMessagesTable`. Identity is the position: contexts grow at the end, and
/// a compaction that rewrites the front simply redraws (the render key, the message, changes).
nonisolated struct ContextMessageListRow: HostedTableRow, Sendable {
    let position: Int
    let message: LLMMessage
    let number: Int?
    let caption: String?
    let expandedByDefault: Bool

    var id: Int { position }

    var renderKey: RenderKey {
        RenderKey(message: message, number: number, caption: caption, expandedByDefault: expandedByDefault)
    }

    struct RenderKey: Equatable, Sendable {
        let message: LLMMessage
        let number: Int?
        let caption: String?
        let expandedByDefault: Bool
    }

    /// Collapsed rows are one line; an expanded one is its text's line count, bounded.
    var estimatedHeight: CGFloat {
        let captionHeight: CGFloat = caption == nil ? 0 : 28
        guard expandedByDefault, case .text(let text) = message.content else { return 18 + captionHeight }
        var lines = 1
        for byte in text.utf8 where byte == UInt8(ascii: "\n") {
            lines += 1
            if lines >= 60 { break }
        }
        return 6 + 14 * CGFloat(lines) + captionHeight
    }
}

private struct ContextMessageListRowView: View {
    let row: ContextMessageListRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let caption = row.caption {
                Divider()
                Text(caption)
                    .font(.caption.bold())
                    .foregroundStyle(AppColors.inspectorResponse)
            }
            ContextMessageRow(message: row.message, index: row.number, initiallyExpanded: row.expandedByDefault)
        }
    }
}
