import Foundation
import SwiftUI

/// Styles one line of inline markdown into an `AttributedString`, giving inline
/// `` `code` `` spans a distinct color while letting emphasis and links form
/// **across** them.
///
/// The line is parsed **whole** by `AttributedString(markdown:)`. The previous
/// implementation split the line at backticks first and markdown-parsed each
/// non-code piece independently, which broke any `**bold**`, `*italic*`, or
/// `[link](…)` that contained a code span: each half saw an unmatched delimiter
/// and rendered it literally (`**JSON files via a `PersistenceManager` actor.**`
/// shipped with its asterisks visible).
///
/// A whole-line parse needs the code spans masked during preprocessing, because
/// `PathLinkifier` must never rewrite text inside backticks — injected
/// `[text](url)` syntax inside a code span renders as literal brackets. The mask
/// (`stretches(in:)`) therefore replicates the CommonMark pairing rules the
/// parser itself uses, so the two always agree about where code spans are; a
/// test cross-checks the mask against the parser over a corpus of tricky lines.
public enum InlineMarkdownStyler {

    /// A maximal piece of a line that is either one whole code span (backtick
    /// delimiters included, passed through the preprocessors verbatim) or the
    /// plain text between code spans (fair game for linkification/escaping).
    struct LineStretch: Equatable {
        let text: String
        let isCodeSpan: Bool
    }

    /// Renders `line` (inline markdown, no block structure) into a styled
    /// `AttributedString`.
    ///
    /// - Code spans that are a single linkable token (absolute path, URL, email)
    ///   become clickable links, matching `PathLinkifier.standaloneLink`.
    /// - All other code spans get `inlineCodeColor`.
    /// - The parser's `.code` presentation intent is removed after styling:
    ///   SwiftUI renders that intent in a monospaced font, which would change the
    ///   look of every call site whose base font is proportional. Color-only is
    ///   the pre-existing rendering; keep it.
    /// - If markdown parsing fails, the raw line is returned unstyled rather than
    ///   dropping the text.
    public static func styledLine(_ line: String, inlineCodeColor: Color) -> AttributedString {
        guard let parsed = try? AttributedString(
            markdown: preprocessedLine(line),
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) else {
            return AttributedString(line)
        }

        // Rebuild by concatenation instead of mutating `parsed` in place:
        // mutating an AttributedString invalidates the run ranges being iterated.
        var output = AttributedString()
        for run in parsed.runs {
            var piece = AttributedString(parsed[run.range])
            if var intent = run.inlinePresentationIntent, intent.contains(.code) {
                intent.remove(.code)
                piece.inlinePresentationIntent = intent.isEmpty ? nil : intent
                let runText = String(parsed[run.range].characters)
                // `run.link == nil` is defensive: the parser collapses code spans
                // inside link syntax today, but a future parser that kept both
                // must not have its link overwritten.
                if run.link == nil, let target = PathLinkifier.standaloneLinkTarget(for: runText) {
                    piece.link = target
                } else {
                    piece.foregroundColor = inlineCodeColor
                }
            }
            output += piece
        }
        return output
    }

    /// Applies the string-level preprocessors (path/URL/email linkification,
    /// `~/` escaping) to the plain stretches of `line` while passing code spans
    /// through byte-for-byte, then reassembles the line for the whole-line parse.
    static func preprocessedLine(_ line: String) -> String {
        stretches(in: line)
            .map { stretch in
                stretch.isCodeSpan
                    ? stretch.text
                    : escapePathTildes(in: PathLinkifier.linkify(stretch.text))
            }
            .joined()
    }

    /// Splits `line` into code-span and plain stretches using CommonMark's
    /// pairing rules, which is what `AttributedString(markdown:)` implements:
    ///
    /// - A run of N backticks opens a span closed only by the next run of
    ///   exactly N backticks; runs of other lengths in between are content.
    /// - An opener with no closer is literal text, and scanning resumes after
    ///   the whole opener run.
    /// - Outside code spans a backslash escapes a following backtick (or
    ///   backslash), so that backtick cannot open a span. Inside a span
    ///   backslashes are literal, so they cannot hide a closer.
    ///
    /// Concatenating the stretch texts always reproduces `line` exactly.
    static func stretches(in line: String) -> [LineStretch] {
        guard line.contains("`") else {
            return line.isEmpty ? [] : [LineStretch(text: line, isCodeSpan: false)]
        }

        var result: [LineStretch] = []
        var plainStart = line.startIndex
        var i = line.startIndex

        func flushPlain(upTo end: String.Index) {
            if plainStart < end {
                result.append(LineStretch(text: String(line[plainStart..<end]), isCodeSpan: false))
            }
        }

        while i < line.endIndex {
            let character = line[i]
            if character == "\\" {
                let next = line.index(after: i)
                if next < line.endIndex, line[next] == "`" || line[next] == "\\" {
                    i = line.index(after: next)
                } else {
                    i = next
                }
                continue
            }
            guard character == "`" else {
                i = line.index(after: i)
                continue
            }

            var openerEnd = i
            while openerEnd < line.endIndex, line[openerEnd] == "`" {
                openerEnd = line.index(after: openerEnd)
            }
            let openerLength = line.distance(from: i, to: openerEnd)

            var closerEnd: String.Index?
            var searchStart = openerEnd
            while searchStart < line.endIndex {
                guard let tickStart = line[searchStart...].firstIndex(of: "`") else { break }
                var tickEnd = tickStart
                while tickEnd < line.endIndex, line[tickEnd] == "`" {
                    tickEnd = line.index(after: tickEnd)
                }
                if line.distance(from: tickStart, to: tickEnd) == openerLength {
                    closerEnd = tickEnd
                    break
                }
                searchStart = tickEnd
            }

            if let closerEnd {
                flushPlain(upTo: i)
                result.append(LineStretch(text: String(line[i..<closerEnd]), isCodeSpan: true))
                plainStart = closerEnd
                i = closerEnd
            } else {
                i = openerEnd
            }
        }
        flushPlain(upTo: line.endIndex)
        return result
    }

    /// GFM has treated even single tildes as strikethrough delimiters, so two
    /// home-relative paths in one line ("check ~/cursor/a and ~/cursor/b")
    /// struck through everything between them (observed on user-typed text
    /// 2026-07-09; current OS builds no longer reproduce it, but the escape is
    /// kept so rendering doesn't depend on the OS parser's version). Escapes `~`
    /// only when it starts a `~/` path — deliberate `~~strikethrough~~` has no
    /// slash and is untouched. Runs only on plain stretches; code spans protect
    /// their tildes at parse time.
    static func escapePathTildes(in text: String) -> String {
        guard text.contains("~/") else { return text }
        var result = ""
        result.reserveCapacity(text.count + 4)
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character == "~", next < text.endIndex, text[next] == "/" {
                result.append("\\~")
            } else {
                result.append(character)
            }
            index = next
        }
        return result
    }
}
