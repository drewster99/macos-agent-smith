import SwiftUI
import SwiftLLMKit

// MARK: - Query parsing

/// One parsed filter term.
///
/// - `bare`: a whitespace-delimited word. Matched case-INsensitively against the row's concatenated
///   search string (all four display lines glued, whitespace removed, lowercased).
/// - `quoted`: text that appeared inside double quotes (or after an unclosed quote, to end of line).
///   Matched case-SENSITIVELY against the row's four display-line strings, each independently.
nonisolated enum ModelSearchTerm: Equatable, Sendable {
    case bare(String)
    case quoted(String)
}

/// Splits filter text into terms. Whitespace separates bare terms; a double quote starts a quoted
/// term that runs to the next double quote or the end of the line. Empty quoted terms (`""`, or a
/// lone trailing `"`) are dropped so they can't act as a match-everything no-op downstream.
nonisolated func parseModelSearchQuery(_ text: String) -> [ModelSearchTerm] {
    var terms: [ModelSearchTerm] = []
    var current = ""
    func flushBare() {
        if !current.isEmpty {
            terms.append(.bare(current))
            current = ""
        }
    }
    var index = text.startIndex
    while index < text.endIndex {
        let ch = text[index]
        if ch == "\"" {
            flushBare()
            let quoteStart = text.index(after: index)
            if let close = text[quoteStart...].firstIndex(of: "\"") {
                let quoted = String(text[quoteStart..<close])
                if !quoted.isEmpty { terms.append(.quoted(quoted)) }
                index = text.index(after: close)
            } else {
                let quoted = String(text[quoteStart...])
                if !quoted.isEmpty { terms.append(.quoted(quoted)) }
                index = text.endIndex
            }
        } else if ch.isWhitespace {
            flushBare()
            index = text.index(after: index)
        } else {
            current.append(ch)
            index = text.index(after: index)
        }
    }
    flushBare()
    return terms
}

/// A query prepared once per keystroke: bare terms pre-lowercased (so the per-row match loop doesn't
/// re-lowercase them 1,675 times), quoted terms kept verbatim (case-sensitive).
nonisolated struct PreparedModelSearch: Equatable, Sendable {
    let bare: [String]
    let quoted: [String]

    var isEmpty: Bool { bare.isEmpty && quoted.isEmpty }

    init(_ terms: [ModelSearchTerm]) {
        var bare: [String] = []
        var quoted: [String] = []
        for term in terms {
            switch term {
            case .bare(let s): bare.append(s.lowercased())
            case .quoted(let s): quoted.append(s)
            }
        }
        self.bare = bare
        self.quoted = quoted
    }
}

// MARK: - Row content (display segments + searchable strings)

/// A single styled run of text in a model row. The row is rendered from these segments (matching the
/// existing HStack layout), and the row's searchable strings are derived from the SAME segments — so
/// what is searched can never drift from what is shown.
nonisolated struct ModelRowSegment: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case title
        case newBadge
        case providerChip
        case modelID
        case maxTokens
        case ctxTokens
        case pricing
        case capabilities
        case flagChip
    }
    let text: String
    let kind: Kind
}

/// Identifies one segment within a row: line index (0 = title … 3 = flag chips) + segment index.
nonisolated struct ModelRowSegmentKey: Hashable, Sendable {
    let line: Int
    let segment: Int
}

/// A character's origin: which line, which segment, and the character offset within that segment's
/// ORIGINAL (display) text — so a match found in a derived string maps back to display positions.
private struct RowCharOrigin: Sendable {
    let line: Int
    let segment: Int
    let offset: Int
}

/// Everything the Models list needs for one (provider, model): the display segments, and the derived
/// strings searched against. Built off the main actor (`init` is `nonisolated`); the display-string
/// formatting (`formatTokenCount`, `PricingFormatter.summary`) is pure and nonisolated too.
nonisolated struct ModelRowContent: Identifiable, Sendable {
    let provider: ModelProvider
    let model: ModelInfo

    /// Display segments, one array per line: [0] title line, [1] meta line, [2] capabilities line,
    /// [3] flag-chips line. Empty lines (no capabilities / all-default flags) are empty arrays.
    let lines: [[ModelRowSegment]]

    /// Lines 0-3 reconstructed as plain strings (segments joined by single spaces) — the
    /// case-sensitive quoted-term match targets.
    let lineStrings: [String]

    /// All segment text, whitespace removed and lowercased, concatenated across every line — the
    /// case-insensitive bare-term match target.
    let concatenated: String

    var id: String { "\(provider.id)/\(model.modelID)" }

    init(provider: ModelProvider, model: ModelInfo) {
        self.provider = provider
        self.model = model

        var line0: [ModelRowSegment] = [ModelRowSegment(text: model.displayName, kind: .title)]
        if model.isNew {
            line0.append(ModelRowSegment(text: "New", kind: .newBadge))
        }

        var line1: [ModelRowSegment] = [
            ModelRowSegment(text: provider.name, kind: .providerChip),
            ModelRowSegment(text: model.modelID, kind: .modelID),
        ]
        if let maxOut = model.maxOutputTokens {
            line1.append(ModelRowSegment(text: "max \(formatTokenCount(maxOut))", kind: .maxTokens))
        }
        if let maxIn = model.maxInputTokens {
            line1.append(ModelRowSegment(text: "ctx \(formatTokenCount(maxIn))", kind: .ctxTokens))
        }
        if let pricing = model.pricing, pricing.base.hasAnyRate {
            line1.append(ModelRowSegment(text: PricingFormatter.summary(pricing), kind: .pricing))
        }

        var line2: [ModelRowSegment] = []
        let capabilityLabels = model.capabilities.enabledLabels
        if !capabilityLabels.isEmpty {
            line2.append(ModelRowSegment(text: capabilityLabels.joined(separator: ", "), kind: .capabilities))
        }

        var line3: [ModelRowSegment] = []
        if !model.behaviorFlags.isAllDefault {
            for label in model.behaviorFlags.displayLabels {
                line3.append(ModelRowSegment(text: label, kind: .flagChip))
            }
        }

        let lines = [line0, line1, line2, line3]
        self.lines = lines
        self.lineStrings = lines.enumerated().map { String(Self.lineCharacters(segments: $0.element, line: $0.offset).chars) }
        self.concatenated = String(Self.concatenatedCharacters(lines: lines).chars)
    }

    // MARK: Matching

    /// Whether this row satisfies every term (AND). Fast: substring tests over the precomputed
    /// strings, no allocation. Bare terms hit the lowercased concatenation; quoted terms hit any one
    /// of the four line strings, case-sensitively.
    func matches(_ search: PreparedModelSearch) -> Bool {
        for term in search.bare where concatenated.range(of: term, options: .literal) == nil {
            return false
        }
        for term in search.quoted where !lineStrings.contains(where: { $0.range(of: term, options: .literal) != nil }) {
            return false
        }
        return true
    }

    // MARK: Highlighting

    /// Per-segment character offsets to highlight for the given query. Bare-term matches on the
    /// concatenation map back through the whitespace-removal (so a match spanning removed spaces
    /// highlights each side but not the gap); quoted-term matches map within each line, skipping the
    /// synthetic separator spaces between segments. Computed only for on-screen rows.
    func highlightRanges(_ search: PreparedModelSearch) -> [ModelRowSegmentKey: IndexSet] {
        if search.isEmpty { return [:] }
        var result: [ModelRowSegmentKey: IndexSet] = [:]

        if !search.bare.isEmpty {
            let concat = Self.concatenatedCharacters(lines: lines)
            for term in search.bare {
                let needle = Array(term)
                var from = 0
                while let start = Self.firstIndex(of: needle, in: concat.chars, from: from) {
                    for offset in start..<(start + needle.count) {
                        let origin = concat.origins[offset]
                        let key = ModelRowSegmentKey(line: origin.line, segment: origin.segment)
                        result[key, default: IndexSet()].insert(origin.offset)
                    }
                    from = start + 1
                }
            }
        }

        if !search.quoted.isEmpty {
            for (lineIndex, segments) in lines.enumerated() {
                let line = Self.lineCharacters(segments: segments, line: lineIndex)
                for term in search.quoted {
                    let needle = Array(term)
                    var from = 0
                    while let start = Self.firstIndex(of: needle, in: line.chars, from: from) {
                        for offset in start..<(start + needle.count) {
                            if let origin = line.origins[offset] {
                                let key = ModelRowSegmentKey(line: origin.line, segment: origin.segment)
                                result[key, default: IndexSet()].insert(origin.offset)
                            }
                        }
                        from = start + 1
                    }
                }
            }
        }
        return result
    }

    // MARK: Derived-string construction (single source for both build-time strings and highlighting)

    /// One line's characters (segments joined by a single space) with per-character origins;
    /// separator spaces map to `nil` (they belong to no segment).
    private static func lineCharacters(segments: [ModelRowSegment], line: Int) -> (chars: [Character], origins: [RowCharOrigin?]) {
        var chars: [Character] = []
        var origins: [RowCharOrigin?] = []
        for (segmentIndex, segment) in segments.enumerated() {
            if segmentIndex > 0 {
                chars.append(" ")
                origins.append(nil)
            }
            for (offset, character) in segment.text.enumerated() {
                chars.append(character)
                origins.append(RowCharOrigin(line: line, segment: segmentIndex, offset: offset))
            }
        }
        return (chars, origins)
    }

    /// Every segment's text across all lines, whitespace removed and lowercased, with per-character
    /// origins pointing back to the original (display-case) character offset.
    private static func concatenatedCharacters(lines: [[ModelRowSegment]]) -> (chars: [Character], origins: [RowCharOrigin]) {
        var chars: [Character] = []
        var origins: [RowCharOrigin] = []
        for (lineIndex, segments) in lines.enumerated() {
            for (segmentIndex, segment) in segments.enumerated() {
                for (offset, character) in segment.text.enumerated() where !character.isWhitespace {
                    for lowered in character.lowercased() {
                        chars.append(lowered)
                        origins.append(RowCharOrigin(line: lineIndex, segment: segmentIndex, offset: offset))
                    }
                }
            }
        }
        return (chars, origins)
    }

    /// First index at/after `from` where `needle` occurs contiguously in `haystack`, else nil.
    private static func firstIndex(of needle: [Character], in haystack: [Character], from: Int) -> Int? {
        if needle.isEmpty || haystack.count < needle.count { return nil }
        var i = max(from, 0)
        let lastStart = haystack.count - needle.count
        while i <= lastStart {
            var matched = true
            for j in 0..<needle.count where haystack[i + j] != needle[j] {
                matched = false
                break
            }
            if matched { return i }
            i += 1
        }
        return nil
    }
}

/// Builds an `AttributedString` from `text`, applying `background` behind the character offsets in
/// `highlightedOffsets`. The offsets are Character offsets (as produced by `highlightRanges`), which
/// line up with `AttributedString.CharacterView` for ASCII model strings.
nonisolated func attributedHighlighting(_ text: String, highlightedOffsets: IndexSet?, background: Color) -> AttributedString {
    var attributed = AttributedString(text)
    guard let offsets = highlightedOffsets, !offsets.isEmpty else { return attributed }
    let characterCount = attributed.characters.count
    for range in offsets.rangeView {
        let lower = min(range.lowerBound, characterCount)
        let upper = min(range.upperBound, characterCount)
        guard lower < upper else { continue }
        let start = attributed.characters.index(attributed.startIndex, offsetBy: lower)
        let end = attributed.characters.index(attributed.startIndex, offsetBy: upper)
        attributed[start..<end].backgroundColor = background
    }
    return attributed
}
