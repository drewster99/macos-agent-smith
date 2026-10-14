import Foundation

/// One line of markdown prose, classified once. Both renderers — the selectable AppKit text view
/// and the static per-line SwiftUI `Text` — draw from this, so they cannot disagree about what a
/// line is.
///
/// Classification order is the original renderer's precedence: headings, blank, list, indented,
/// plain. The three heading prefixes are mutually exclusive — the character after the hashes
/// disambiguates — so their order is not load-bearing; longest-first is for the reader.
enum MarkdownLine: Equatable {
    case heading(level: Int, text: String)
    case blank
    /// `marker` is "•" for bullets or the number prefix ("1.", "2)") as written.
    case listItem(marker: String, text: String, indent: CGFloat)
    /// Text with leading whitespace that isn't a list item — the indent is kept.
    case indented(text: String, indent: CGFloat)
    case plain(String)

    init(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("### ") {
            self = .heading(level: 3, text: String(trimmed.dropFirst(4)))
            return
        }
        if trimmed.hasPrefix("## ") {
            self = .heading(level: 2, text: String(trimmed.dropFirst(3)))
            return
        }
        if trimmed.hasPrefix("# ") {
            self = .heading(level: 1, text: String(trimmed.dropFirst(2)))
            return
        }
        if trimmed.isEmpty {
            self = .blank
            return
        }

        let stripped = line.drop(while: { $0 == " " || $0 == "\t" })
        let leadingWhitespace = line.count - stripped.count
        // 12pt per 2-space level.
        let indent = CGFloat(max(0, leadingWhitespace / 2)) * 12

        // Bullet markers: "* ", "- "
        if stripped.hasPrefix("* ") || stripped.hasPrefix("- ") {
            self = .listItem(marker: "•", text: String(stripped.dropFirst(2)), indent: indent)
            return
        }
        // Unicode bullet, with or without a following space (some models omit it).
        if stripped.hasPrefix("•") {
            let afterBullet = stripped.dropFirst(1).drop(while: { $0 == " " })
            self = .listItem(marker: "•", text: String(afterBullet), indent: indent)
            return
        }
        // Numbered list: "1. ", "2) " — the prefix is kept for display.
        if let match = stripped.prefixMatch(of: /\d+[.)]\s+/) {
            let marker = String(stripped[match.range]).trimmingCharacters(in: .whitespaces)
            self = .listItem(marker: marker, text: String(stripped[match.range.upperBound...]), indent: indent)
            return
        }
        if leadingWhitespace > 0 {
            self = .indented(text: String(stripped), indent: indent)
            return
        }
        self = .plain(line)
    }

    /// The face a heading of `level` is set in.
    static func headingFont(level: Int) -> MarkdownFont {
        switch level {
        case 1: return .heading1
        case 2: return .heading2
        default: return .heading3
        }
    }

    /// Height of a blank line, in points — a paragraph break, not a full empty line.
    static let blankLineHeight: CGFloat = 6
    /// Space between a list marker and its text.
    static let listMarkerSpacing: CGFloat = 4
    /// Space between consecutive lines.
    static let lineSpacing: CGFloat = 1
}
