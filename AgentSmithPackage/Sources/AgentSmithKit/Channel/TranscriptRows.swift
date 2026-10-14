import Foundation

/// One row of a transcript pane: a message that renders as something, plus the follow-ups folded
/// into it. A tool call's security verdict and output are separate messages on the channel but are
/// shown inside the call's row, so the row carries them.
public struct TranscriptRow: Identifiable, Sendable {
    public let message: ChannelMessage
    /// The verdict delivered for this row's tool call — including one the pane's settings hide,
    /// which still decides the row's status icon (`TranscriptDelivery`).
    public let securityReview: ChannelMessage?
    public let toolOutput: ChannelMessage?
    /// Whether the pane's settings show `securityReview`'s text. The icon is shown regardless.
    public let showsSecurityReviewText: Bool

    public var id: UUID { message.id }

    /// What the row is drawn from, by message id. Two rows with the same key render identically
    /// because channel messages are append-only — a message is never edited after it is posted;
    /// a follow-up is a NEW message, which changes the key of the row it folds into.
    public var renderKey: RenderKey {
        RenderKey(
            messageID: message.id,
            securityReviewID: securityReview?.id,
            toolOutputID: toolOutput?.id,
            showsSecurityReviewText: showsSecurityReviewText
        )
    }

    public struct RenderKey: Hashable, Sendable {
        public let messageID: UUID
        public let securityReviewID: UUID?
        public let toolOutputID: UUID?
        public let showsSecurityReviewText: Bool
    }
}

/// The ONE place that decides which of a pane's messages become rows, and what each row renders
/// with. Pure, so the rules are testable without a view.
public enum TranscriptRows {

    /// Pane settings that change which rows exist.
    public struct Options: Equatable, Sendable {
        /// The pane's own filter. A pane is delivered verdicts its settings hide (so a tool call
        /// keeps its status icon); this says which ones it shows.
        public var verdictFilter: TranscriptFilter
        /// Whether lifecycle chrome ("All agents stopped", …) gets rows.
        public var showsRestartChrome: Bool

        public init(verdictFilter: TranscriptFilter, showsRestartChrome: Bool) {
            self.verdictFilter = verdictFilter
            self.showsRestartChrome = showsRestartChrome
        }
    }

    /// The rows for `messages`, in order.
    public static func make(from messages: [ChannelMessage], options: Options) -> [TranscriptRow] {
        let index = GroupingIndex(messages, verdictFilter: options.verdictFilter)
        var rows: [TranscriptRow] = []
        rows.reserveCapacity(messages.count)
        for message in messages where index.isRendered(message, options: options) {
            let requestID = stringMetadata(message, "requestID")
            rows.append(TranscriptRow(
                message: message,
                securityReview: requestID.flatMap { index.securityReviewByRequestID[$0] },
                toolOutput: requestID.flatMap { index.toolOutputByRequestID[$0] },
                showsSecurityReviewText: requestID.map(index.shownVerdictRequestIDs.contains) ?? false
            ))
        }
        return rows
    }

    /// How to turn a table showing `old` rows into one showing `new` — `RowListEdit.plan`, with a
    /// row's identity being its message.
    public static func edit(from old: [TranscriptRow.RenderKey],
                            to new: [TranscriptRow.RenderKey]) -> Edit {
        RowListEdit.plan(from: old, to: new, identity: \.messageID)
    }

    public typealias Edit = RowListEdit

    // MARK: - Grouping

    /// Lookups that fold follow-ups into their parent row and de-duplicate scheduling rows.
    private struct GroupingIndex {
        var toolRequestIDs: Set<String> = []
        var securityReviewByRequestID: [String: ChannelMessage] = [:]
        var shownVerdictRequestIDs: Set<String> = []
        var toolOutputByRequestID: [String: ChannelMessage] = [:]
        var taskIDsWithSchedulingBanner: Set<String> = []
        let verdictFilter: TranscriptFilter

        init(_ messages: [ChannelMessage], verdictFilter: TranscriptFilter) {
            self.verdictFilter = verdictFilter
            for message in messages {
                let kind = message.kind
                let requestID = TranscriptRows.stringMetadata(message, "requestID")
                if kind == .toolRequest, let requestID { toolRequestIDs.insert(requestID) }
                if TranscriptRows.isSecurityReview(message), let requestID {
                    securityReviewByRequestID[requestID] = message
                    if verdictFilter.matches(message) { shownVerdictRequestIDs.insert(requestID) }
                }
                if kind == .toolOutput, let requestID { toolOutputByRequestID[requestID] = message }
                if kind == .taskCreated || kind == .taskActionScheduled,
                   let taskID = TranscriptRows.stringMetadata(message, "taskID") {
                    taskIDsWithSchedulingBanner.insert(taskID)
                }
            }
        }

        /// Whether `message` gets a row of its own.
        func isRendered(_ message: ChannelMessage, options: Options) -> Bool {
            if isFoldedIntoParent(message) { return false }
            switch message.kind {
            case .taskUpdateGuidance:
                // Internal Smith guidance — never shown.
                return false
            case .restartChrome:
                return options.showsRestartChrome
            case .timerActivity:
                // A "scheduled" timer row repeats what its task's scheduling banner already shows.
                guard TranscriptRows.stringMetadata(message, "timerEventKind") == "scheduled",
                      let timerTaskID = TranscriptRows.stringMetadata(message, "timerTaskID") else { return true }
                return !taskIDsWithSchedulingBanner.contains(timerTaskID)
            default:
                return true
            }
        }

        /// Security reviews and tool outputs render inside their parent tool call's row. A verdict
        /// the pane's settings hide was delivered only for that row's status icon, so it never
        /// gets a row of its own, parent or not.
        private func isFoldedIntoParent(_ message: ChannelMessage) -> Bool {
            guard let requestID = TranscriptRows.stringMetadata(message, "requestID") else { return false }
            let review = TranscriptRows.isSecurityReview(message)
            guard review || message.kind == .toolOutput else { return false }
            if review, !verdictFilter.matches(message) { return true }
            return toolRequestIDs.contains(requestID)
        }
    }

    private static func isSecurityReview(_ message: ChannelMessage) -> Bool {
        message.metadata?["securityDisposition"] != nil
    }

    private static func stringMetadata(_ message: ChannelMessage, _ key: String) -> String? {
        guard case .string(let value) = message.metadata?[key] else { return nil }
        return value
    }
}
