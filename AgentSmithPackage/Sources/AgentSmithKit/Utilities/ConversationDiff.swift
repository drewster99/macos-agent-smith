import Foundation
import SwiftLLMKit

/// Builds a message-aware, view-ready diff between two conversation histories (e.g. a
/// compaction's before/after). Three levels of granularity, so every change is visible:
///
/// 1. **Message level** — LCS over rendered message text aligns the two histories; a message
///    is `.equal`, `.removed`, `.added`, or (a related removed/added pair) `.changed`.
/// 2. **Line level** — inside a `.changed` message, an LCS over lines classifies each line.
/// 3. **Word level** — a changed line pair is highlighted IN PLACE via `InlineDiff`, so an edit
///    reads as one line with the changed words marked, never a whole line deleted and re-added.
public enum ConversationDiff {

    /// One rendered message: role label plus full, unfiltered body text (may be multi-line).
    public struct MessageRef: Identifiable, Sendable, Equatable {
        public let id: Int
        public let roleLabel: String
        public let text: String
    }

    /// A line within a `.changed` message's body, aligned across old/new.
    public struct LineRow: Identifiable, Sendable {
        public enum Kind: Sendable { case equal, removed, added, changed }
        public let id: Int
        public let kind: Kind
        /// Spans for the LEFT (old) rendering — `.equal` + `.removed`. Nil when there is no old line.
        public let oldSpans: [InlineDiff.Span]?
        /// Spans for the RIGHT (new) rendering — `.equal` + `.added`. Nil when there is no new line.
        public let newSpans: [InlineDiff.Span]?
    }

    /// One aligned top-level unit of the two histories.
    public struct Row: Identifiable, Sendable {
        public enum Kind: Sendable { case equal, removed, added, changed }
        public let id: Int
        public let kind: Kind
        /// Present for `.equal`, `.removed`, `.changed`.
        public let left: MessageRef?
        /// Present for `.equal`, `.added`, `.changed`.
        public let right: MessageRef?
        /// Intra-message line diff for `.changed` rows; nil otherwise.
        public let lineRows: [LineRow]?

        /// True for any row that carries a difference — drives ↑/↓ change navigation.
        public var isChange: Bool { kind != .equal }
    }

    // MARK: - Build

    public static func build(before: [LLMMessage], after: [LLMMessage]) -> [Row] {
        let oldRendered = before.map(render)
        let newRendered = after.map(render)
        let ops = messageLCS(oldTexts: oldRendered.map(\.text), newTexts: newRendered.map(\.text))

        var rows: [Row] = []
        var oldIndex = 0
        var newIndex = 0
        var rowID = 0
        var i = 0
        while i < ops.count {
            switch ops[i] {
            case .equal:
                rows.append(Row(id: rowID, kind: .equal,
                                left: MessageRef(id: oldIndex, roleLabel: oldRendered[oldIndex].role, text: oldRendered[oldIndex].text),
                                right: MessageRef(id: newIndex, roleLabel: newRendered[newIndex].role, text: newRendered[newIndex].text),
                                lineRows: nil))
                rowID += 1; oldIndex += 1; newIndex += 1; i += 1

            case .removed:
                // Pair a related removed→added run into `.changed` rows (in-place edit); otherwise
                // emit a clean `.removed`.
                if i + 1 < ops.count, ops[i + 1] == .added,
                   InlineDiff.areRelated(old: oldRendered[oldIndex].text, new: newRendered[newIndex].text) {
                    let left = MessageRef(id: oldIndex, roleLabel: oldRendered[oldIndex].role, text: oldRendered[oldIndex].text)
                    let right = MessageRef(id: newIndex, roleLabel: newRendered[newIndex].role, text: newRendered[newIndex].text)
                    rows.append(Row(id: rowID, kind: .changed, left: left, right: right,
                                    lineRows: lineDiff(old: left.text, new: right.text)))
                    rowID += 1; oldIndex += 1; newIndex += 1; i += 2
                } else {
                    rows.append(Row(id: rowID, kind: .removed,
                                    left: MessageRef(id: oldIndex, roleLabel: oldRendered[oldIndex].role, text: oldRendered[oldIndex].text),
                                    right: nil, lineRows: nil))
                    rowID += 1; oldIndex += 1; i += 1
                }

            case .added:
                rows.append(Row(id: rowID, kind: .added, left: nil,
                                right: MessageRef(id: newIndex, roleLabel: newRendered[newIndex].role, text: newRendered[newIndex].text),
                                lineRows: nil))
                rowID += 1; newIndex += 1; i += 1
            }
        }
        return rows
    }

    // MARK: - Line diff (level 2 + 3)

    /// Line-level LCS between two message bodies, pairing related removed/added lines into
    /// `.changed` line rows with word-level inline spans.
    static func lineDiff(old: String, new: String) -> [LineRow] {
        // Large context so nothing is trimmed — every line is shown (DiffGenerator caps a side at
        // 1000 lines, well under this, so all windows merge into one and no separators appear).
        let lineOps = DiffGenerator.generate(old: old, new: new, contextLines: 100_000)
        // A `.tooLarge` sentinel (huge bodies) collapses to a single all-changed row.
        if lineOps.count == 1, lineOps[0].kind == .tooLarge {
            return [LineRow(id: 0, kind: .changed,
                            oldSpans: [InlineDiff.Span(id: 0, kind: .removed, text: lineOps[0].text)],
                            newSpans: [InlineDiff.Span(id: 0, kind: .added, text: lineOps[0].text)])]
        }

        var rows: [LineRow] = []
        var rowID = 0
        var k = 0
        while k < lineOps.count {
            switch lineOps[k].kind {
            case .context:
                let spans = [InlineDiff.Span(id: 0, kind: .equal, text: lineOps[k].text)]
                rows.append(LineRow(id: rowID, kind: .equal, oldSpans: spans, newSpans: spans))
                rowID += 1; k += 1

            case .removed:
                // Collect the contiguous removed run and the added run that follows it, then pair
                // them index-wise into `.changed` (related) / `.removed` / `.added` line rows.
                var removed: [String] = []
                while k < lineOps.count, lineOps[k].kind == .removed { removed.append(lineOps[k].text); k += 1 }
                var added: [String] = []
                while k < lineOps.count, lineOps[k].kind == .added { added.append(lineOps[k].text); k += 1 }
                let pairCount = min(removed.count, added.count)
                for p in 0..<pairCount {
                    if InlineDiff.areRelated(old: removed[p], new: added[p]) {
                        let spans = InlineDiff.diff(old: removed[p], new: added[p])
                        rows.append(LineRow(id: rowID, kind: .changed,
                                            oldSpans: spans.filter { $0.kind != .added },
                                            newSpans: spans.filter { $0.kind != .removed }))
                    } else {
                        rows.append(LineRow(id: rowID, kind: .removed,
                                            oldSpans: [InlineDiff.Span(id: 0, kind: .removed, text: removed[p])], newSpans: nil))
                        rowID += 1
                        rows.append(LineRow(id: rowID, kind: .added, oldSpans: nil,
                                            newSpans: [InlineDiff.Span(id: 0, kind: .added, text: added[p])]))
                    }
                    rowID += 1
                }
                for r in pairCount..<removed.count {
                    rows.append(LineRow(id: rowID, kind: .removed,
                                        oldSpans: [InlineDiff.Span(id: 0, kind: .removed, text: removed[r])], newSpans: nil))
                    rowID += 1
                }
                for a in pairCount..<added.count {
                    rows.append(LineRow(id: rowID, kind: .added, oldSpans: nil,
                                        newSpans: [InlineDiff.Span(id: 0, kind: .added, text: added[a])]))
                    rowID += 1
                }

            case .added:
                rows.append(LineRow(id: rowID, kind: .added, oldSpans: nil,
                                    newSpans: [InlineDiff.Span(id: 0, kind: .added, text: lineOps[k].text)]))
                rowID += 1; k += 1

            case .separator, .tooLarge:
                k += 1
            }
        }
        return rows
    }

    // MARK: - Message-level LCS

    private enum MessageOp: Equatable { case equal, removed, added }

    private static func messageLCS(oldTexts: [String], newTexts: [String]) -> [MessageOp] {
        let m = oldTexts.count
        let n = newTexts.count
        if m == 0 { return Array(repeating: .added, count: n) }
        if n == 0 { return Array(repeating: .removed, count: m) }

        var lcs = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0..<m {
            for j in 0..<n {
                if oldTexts[i] == newTexts[j] {
                    lcs[i + 1][j + 1] = lcs[i][j] + 1
                } else {
                    lcs[i + 1][j + 1] = max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }

        var reversed: [MessageOp] = []
        var i = m
        var j = n
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && oldTexts[i - 1] == newTexts[j - 1] {
                reversed.append(.equal); i -= 1; j -= 1
            } else if j > 0 && (i == 0 || lcs[i][j - 1] >= lcs[i - 1][j]) {
                reversed.append(.added); j -= 1
            } else if i > 0 {
                reversed.append(.removed); i -= 1
            }
        }
        return reversed.reversed()
    }

    // MARK: - Rendering

    /// Renders a message to a role label plus its full, unfiltered body — every role, tool calls
    /// (name + raw arguments) and tool results included, nothing truncated.
    static func render(_ message: LLMMessage) -> (role: String, text: String) {
        (roleLabel(message.role), renderBody(message.content))
    }

    private static func roleLabel(_ role: LLMMessage.Role) -> String {
        switch role {
        case .system: return "system"
        case .user: return "user"
        case .developer: return "developer"
        case .assistant: return "assistant"
        case .tool: return "tool"
        }
    }

    private static func renderBody(_ content: LLMMessage.Content) -> String {
        switch content {
        case .text(let text):
            return text
        case .mixed(let text, let calls):
            var parts: [String] = []
            if !text.isEmpty { parts.append(text) }
            parts.append(contentsOf: calls.map(renderToolCall))
            return parts.joined(separator: "\n")
        case .toolCalls(let calls):
            return calls.map(renderToolCall).joined(separator: "\n")
        case .toolResult(_, let content):
            return content
        }
    }

    private static func renderToolCall(_ call: LLMToolCall) -> String {
        let args = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        return args.isEmpty ? "[tool_call: \(call.name)]" : "[tool_call: \(call.name) \(args)]"
    }
}
