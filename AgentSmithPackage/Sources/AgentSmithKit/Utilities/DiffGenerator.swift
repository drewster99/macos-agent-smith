import Foundation

/// A single line in a rendered diff. `Codable` so diffs can be precomputed at
/// tool-request post time (in `AgentActor.postToolRequestToChannel`) and stored
/// in channel metadata, instead of stashing the full pre- and post-edit file
/// contents (which were bloating `channel_log.json` unboundedly).
public struct DiffLine: Identifiable, Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case context
        case removed
        case added
        /// Separator between non-contiguous hunks (e.g. "⋯").
        case separator
        /// Sentinel: the diff was too large to compute. `text` holds a summary.
        case tooLarge
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

/// Line-based diff generator using longest-common-subsequence.
public enum DiffGenerator {
    /// Hard cap on input size to prevent O(m*n) memory/CPU blowup on large files.
    /// 1000 lines per side → ~8 MB DP table, worst case. If either side exceeds
    /// this, we return a simplified all-removed/all-added diff instead of LCS.
    public static let maxLineCount = 1000

    /// Produces a diff between `old` and `new`, showing up to `contextLines` of
    /// unchanged lines around each change hunk. Non-contiguous hunks are joined
    /// with a `.separator` line.
    public static func generate(old: String, new: String, contextLines: Int = 2) -> [DiffLine] {
        let oldLines = splitLines(old)
        let newLines = splitLines(new)

        // Fast paths.
        if oldLines.isEmpty && newLines.isEmpty { return [] }
        if oldLines.isEmpty {
            return newLines.enumerated().map { DiffLine(id: $0.offset, kind: .added, text: $0.element) }
        }
        if newLines.isEmpty {
            return oldLines.enumerated().map { DiffLine(id: $0.offset, kind: .removed, text: $0.element) }
        }

        // Size guard: above this, LCS becomes prohibitive. Return a sentinel.
        if oldLines.count > maxLineCount || newLines.count > maxLineCount {
            let summary = "diff too large (\(oldLines.count) → \(newLines.count) lines)"
            return [DiffLine(id: 0, kind: .tooLarge, text: summary)]
        }

        let ops = lcsDiff(oldLines: oldLines, newLines: newLines)
        return trimContext(ops: ops, contextLines: contextLines)
    }

    /// Splits text into lines. Preserves empty trailing lines for accurate diffs.
    private static func splitLines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        // Split on \n but preserve the difference between "a\nb" (2 lines) and
        // "a\nb\n" (2 lines, not 3) — standard unified-diff semantics.
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// Classic LCS-based diff returning the raw ordered operation list (no trimming).
    ///
    /// Memory: O(m * n) for the DP table — at the 1000-line cap that's ~8 MB. A
    /// Hirschberg-style O(min(m,n)) optimization exists but adds significant
    /// complexity for marginal gain at our capped input size. Accepted as-is; the
    /// `maxLineCount` guard in `generate()` bounds the worst case.
    private static func lcsDiff(oldLines: [String], newLines: [String]) -> [DiffLine] {
        let m = oldLines.count
        let n = newLines.count

        // Build LCS length table.
        var lcs = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0..<m {
            for j in 0..<n {
                if oldLines[i] == newLines[j] {
                    lcs[i + 1][j + 1] = lcs[i][j] + 1
                } else {
                    lcs[i + 1][j + 1] = max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }

        // Backtrack to produce an ordered list of operations.
        var reversed: [DiffLine] = []
        var i = m
        var j = n
        var id = 0
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && oldLines[i - 1] == newLines[j - 1] {
                reversed.append(DiffLine(id: id, kind: .context, text: oldLines[i - 1]))
                i -= 1
                j -= 1
            } else if j > 0 && (i == 0 || lcs[i][j - 1] >= lcs[i - 1][j]) {
                reversed.append(DiffLine(id: id, kind: .added, text: newLines[j - 1]))
                j -= 1
            } else if i > 0 {
                reversed.append(DiffLine(id: id, kind: .removed, text: oldLines[i - 1]))
                i -= 1
            }
            id += 1
        }
        return reversed.reversed().enumerated().map { DiffLine(id: $0.offset, kind: $0.element.kind, text: $0.element.text) }
    }

    /// Renders an existing `[DiffLine]` array into a unified-diff-style plain-text
    /// block — `+ ` for additions, `- ` for removals, `  ` for unchanged context
    /// lines, plus a leading summary like `+1 -0`. Used to feed Security Agent (the security
    /// evaluator) a representation of a `file_edit` call that's identical in shape
    /// to what the UI displays, so Security Agent reasons about the *actual change* rather
    /// than about the literal `new_string` parameter (which includes anchor context
    /// and is easy to misread as "two added items" when only one is being added).
    public static func renderAsText(lines: [DiffLine]) -> String {
        guard !lines.isEmpty else { return "(no changes)" }
        if lines.count == 1, lines[0].kind == .tooLarge {
            return lines[0].text
        }
        let added = lines.reduce(into: 0) { $0 += ($1.kind == .added ? 1 : 0) }
        let removed = lines.reduce(into: 0) { $0 += ($1.kind == .removed ? 1 : 0) }
        var rendered: [String] = ["+\(added) -\(removed)"]
        for line in lines {
            switch line.kind {
            case .context:   rendered.append("  " + line.text)
            case .added:     rendered.append("+ " + line.text)
            case .removed:   rendered.append("- " + line.text)
            case .separator: rendered.append(line.text)
            case .tooLarge:  rendered.append(line.text)
            }
        }
        return rendered.joined(separator: "\n")
    }

    /// Convenience: generate-and-render in one call, matching what the UI's
    /// `DiffView(oldContent:newContent:)` would display for the same inputs but
    /// as plain text.
    public static func renderAsText(old: String, new: String, contextLines: Int = 2) -> String {
        renderAsText(lines: generate(old: old, new: new, contextLines: contextLines))
    }

    /// Keeps only `contextLines` unchanged lines around each change hunk,
    /// inserting a separator between non-contiguous hunks.
    private static func trimContext(ops: [DiffLine], contextLines: Int) -> [DiffLine] {
        // Indices of lines that represent a change.
        let changeIndices = ops.enumerated().compactMap { idx, line -> Int? in
            line.kind == .context ? nil : idx
        }
        if changeIndices.isEmpty { return [] }

        // Expand each change index into a context window, then merge overlapping windows.
        var windows: [(start: Int, end: Int)] = []
        for idx in changeIndices {
            let start = max(0, idx - contextLines)
            let end = min(ops.count - 1, idx + contextLines)
            if var last = windows.last, last.end + 1 >= start {
                last.end = max(last.end, end)
                windows[windows.count - 1] = last
            } else {
                windows.append((start, end))
            }
        }

        var result: [DiffLine] = []
        var nextID = 0
        for (windowIndex, window) in windows.enumerated() {
            if windowIndex > 0 {
                result.append(DiffLine(id: nextID, kind: .separator, text: "⋯"))
                nextID += 1
            }
            for i in window.start...window.end {
                result.append(DiffLine(id: nextID, kind: ops[i].kind, text: ops[i].text))
                nextID += 1
            }
        }
        return result
    }
}
