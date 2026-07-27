import Foundation

/// Word-level (intra-line) diff. Where `DiffGenerator` works at line granularity, this pairs a
/// single "old" line against a single "new" line and highlights the changed WORDS in place —
/// so a line that was edited reads as one line with the changed spans marked, not as a whole
/// line removed and a whole line added.
///
/// Tokenizes into maximal runs of whitespace and non-whitespace (word-level, whitespace
/// preserved), then LCS-aligns the token streams. Each side renders its own spans:
/// - the OLD/left line renders `.equal` + `.removed` spans,
/// - the NEW/right line renders `.equal` + `.added` spans.
public enum InlineDiff {

    public struct Span: Identifiable, Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case equal
            case removed
            case added
        }
        public let id: Int
        public let kind: Kind
        public let text: String

        public init(id: Int, kind: Kind, text: String) {
            self.id = id
            self.kind = kind
            self.text = text
        }
    }

    /// LCS-aligned word-level spans between `old` and `new`. Adjacent same-kind spans are merged
    /// so a run of changed words reads as one highlighted span rather than a flicker of tokens.
    public static func diff(old: String, new: String) -> [Span] {
        if old == new {
            return old.isEmpty ? [] : [Span(id: 0, kind: .equal, text: old)]
        }
        let oldTokens = tokenize(old)
        let newTokens = tokenize(new)
        if oldTokens.isEmpty { return coalesce(newTokens.map { ($0, Span.Kind.added) }) }
        if newTokens.isEmpty { return coalesce(oldTokens.map { ($0, Span.Kind.removed) }) }

        let m = oldTokens.count
        let n = newTokens.count
        var lcs = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0..<m {
            for j in 0..<n {
                if oldTokens[i] == newTokens[j] {
                    lcs[i + 1][j + 1] = lcs[i][j] + 1
                } else {
                    lcs[i + 1][j + 1] = max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }

        var reversed: [(String, Span.Kind)] = []
        var i = m
        var j = n
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && oldTokens[i - 1] == newTokens[j - 1] {
                reversed.append((oldTokens[i - 1], .equal))
                i -= 1; j -= 1
            } else if j > 0 && (i == 0 || lcs[i][j - 1] >= lcs[i - 1][j]) {
                reversed.append((newTokens[j - 1], .added))
                j -= 1
            } else if i > 0 {
                reversed.append((oldTokens[i - 1], .removed))
                i -= 1
            }
        }
        return coalesce(reversed.reversed())
    }

    /// True when the two lines share ANY word-level common subsequence — i.e. they read as an
    /// edit of one another rather than two unrelated lines. Used to decide whether a removed line
    /// and an added line should be paired as an in-place change (inline highlight) or shown as a
    /// clean delete + add.
    public static func areRelated(old: String, new: String) -> Bool {
        if old == new { return true }
        let oldTokens = Set(tokenize(old).filter { !$0.allSatisfy(\.isWhitespace) })
        let newTokens = tokenize(new).filter { !$0.allSatisfy(\.isWhitespace) }
        guard !oldTokens.isEmpty, !newTokens.isEmpty else { return false }
        let shared = newTokens.reduce(into: 0) { $0 += oldTokens.contains($1) ? 1 : 0 }
        // Related if at least a third of the smaller side's words are shared.
        let denom = max(1, min(oldTokens.count, newTokens.count))
        return Double(shared) / Double(denom) >= 0.34
    }

    /// Splits into maximal runs of whitespace and maximal runs of non-whitespace.
    private static func tokenize(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var tokens: [String] = []
        var current = ""
        var currentIsSpace: Bool?
        for char in text {
            let isSpace = char.isWhitespace
            if currentIsSpace == nil || currentIsSpace == isSpace {
                current.append(char)
                currentIsSpace = isSpace
            } else {
                tokens.append(current)
                current = String(char)
                currentIsSpace = isSpace
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Merges adjacent same-kind tokens into single spans and assigns stable ids.
    private static func coalesce(_ items: [(String, Span.Kind)]) -> [Span] {
        var spans: [Span] = []
        for (text, kind) in items {
            if var last = spans.last, last.kind == kind {
                last = Span(id: last.id, kind: kind, text: last.text + text)
                spans[spans.count - 1] = last
            } else {
                spans.append(Span(id: spans.count, kind: kind, text: text))
            }
        }
        return spans
    }
}
