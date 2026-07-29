import Testing
import Foundation
import SwiftUI
@testable import AgentSmithKit

/// Covers `InlineMarkdownStyler`, the whole-line inline markdown pipeline behind
/// `MarkdownText`. The load-bearing properties:
///
/// 1. Emphasis and links form **across** inline code spans (the predecessor split at
///    backticks first, so `**bold `code` bold**` rendered its asterisks literally).
/// 2. The code-span mask agrees with `AttributedString(markdown:)` about where code
///    spans are, so `PathLinkifier` never rewrites text inside backticks.
/// 3. The parser's `.code` intent is stripped after styling, so inline code keeps the
///    base font (SwiftUI would otherwise render it monospaced) — color only.
@Suite("InlineMarkdownStyler")
struct InlineMarkdownStylerTests {

    private let codeColor = Color.cyan

    /// One styled run, decoded into the properties the tests assert on. `isCode`
    /// is detected via the injected color because the `.code` intent is deliberately
    /// stripped from the output.
    private struct StyledRun: Equatable {
        let text: String
        let isBold: Bool
        let isItalic: Bool
        let isStruck: Bool
        let isCode: Bool
        let link: URL?
    }

    private func styledRuns(of line: String) -> [StyledRun] {
        let attributed = InlineMarkdownStyler.styledLine(line, inlineCodeColor: codeColor)
        return attributed.runs.map { run in
            let intent = run.inlinePresentationIntent
            return StyledRun(
                text: String(attributed[run.range].characters),
                isBold: intent?.contains(.stronglyEmphasized) == true,
                isItalic: intent?.contains(.emphasized) == true,
                isStruck: intent?.contains(.strikethrough) == true,
                isCode: run.foregroundColor == codeColor,
                link: run.link
            )
        }
    }

    private func plainText(of line: String) -> String {
        String(InlineMarkdownStyler.styledLine(line, inlineCodeColor: codeColor).characters)
    }

    /// Creates an empty file at a unique path under a fresh temp directory so
    /// `linkifyPaths` (which checks existence) has something real to wrap.
    private func makeTempFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-smith-styler-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("file.md")
        try Data().write(to: file)
        return file
    }

    private func cleanup(_ file: URL) {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    // MARK: - Mask ↔ parser agreement

    /// Lines chosen to exercise every pairing rule: run-length matching, unmatched
    /// openers, escaped backticks, escapes being literal inside spans, the
    /// one-space trim, and cmark's backtick-string cache (failed-scan poisoning,
    /// successful-scan rewind, the MAXBACKTICKS cap). No linkifiable content —
    /// this isolates the scanner.
    private static let pairingCorpus: [String] = [
        "a `b` c",
        "a ``b`` c",
        "a ``b ` c`` d",
        "a `b `` c",
        "a `b` c ` d",
        #"a \` b `code` d"#,
        #"a \`` b"#,
        #"\`x`"#,
        #"\\`x`"#,
        #"`a\`"#,
        "a ` b ` c",
        "a ` ` c",
        "a ```b``` c",
        "a `` c",
        "`a``b`",
        "`",
        "``",
        "```",
        "`x`",
        "no backticks at all",
        "",
        // cmark's backtick-string cache (Apple ships it; spec CommonMark has no
        // such thing): a closer scan that hits end of input poisons later
        // same-length openers unless the cache proves a run of that length lies
        // ahead, and a successful scan can rewind a length's cache entry. These
        // pin the live parser's off-spec pairing so OS drift fails here.
        "`` `a` `b`",
        "`` `a` `b` `c`",
        "``` `x` `a``b`c``d",
        "``` `x` `a``b` c ``d``",
        "```` x `` y `a``b` z ``w``",
        #"`` \``a` `b`"#,
        "``` ``a`` ``b``",
        "` ``a`` ``b``",
        // cmark's MAXBACKTICKS (80): an 81-tick opener fails without even
        // scanning; an 80-tick opener still pairs.
        String(repeating: "`", count: 81) + "x" + String(repeating: "`", count: 81),
        String(repeating: "`", count: 80) + "x" + String(repeating: "`", count: 80),
    ]

    /// The mask must find exactly the code spans the real parser finds, in order.
    /// Disagreement is the failure mode that lets `PathLinkifier` inject link syntax
    /// into a code span (rendered as literal brackets).
    @Test("code-span mask agrees with AttributedString(markdown:)", arguments: pairingCorpus)
    func maskAgreesWithParser(line: String) throws {
        let maskSpans = InlineMarkdownStyler.stretches(in: line)
            .filter(\.isCodeSpan)
            .map { stretch -> String in
                let withoutOpener = stretch.text.drop(while: { $0 == "`" })
                let delimiterLength = stretch.text.count - withoutOpener.count
                var content = String(withoutOpener.dropLast(delimiterLength))
                // CommonMark strips one leading and one trailing space when both are
                // present and the content isn't all spaces.
                if content.count >= 2, content.hasPrefix(" "), content.hasSuffix(" "),
                   !content.allSatisfy({ $0 == " " }) {
                    content = String(content.dropFirst().dropLast())
                }
                return content
            }

        let parsed = try AttributedString(
            markdown: line,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )
        let parserSpans = parsed.runs.compactMap { run -> String? in
            guard run.inlinePresentationIntent?.contains(.code) == true else { return nil }
            return String(parsed[run.range].characters)
        }

        #expect(maskSpans == parserSpans)
    }

    @Test("stretch concatenation reproduces the input byte-for-byte", arguments: pairingCorpus)
    func stretchesRoundTrip(line: String) {
        let joined = InlineMarkdownStyler.stretches(in: line).map(\.text).joined()
        #expect(joined == line)
    }

    // MARK: - Emphasis across code spans (the bug this replaced)

    @Test("bold spanning an inline code span renders bold on all three parts")
    func boldAcrossCodeSpan() {
        let runs = styledRuns(of: "**JSON files via a `PersistenceManager` actor.** The rest.")
        #expect(runs == [
            StyledRun(text: "JSON files via a ", isBold: true, isItalic: false, isStruck: false, isCode: false, link: nil),
            StyledRun(text: "PersistenceManager", isBold: true, isItalic: false, isStruck: false, isCode: true, link: nil),
            StyledRun(text: " actor.", isBold: true, isItalic: false, isStruck: false, isCode: false, link: nil),
            StyledRun(text: " The rest.", isBold: false, isItalic: false, isStruck: false, isCode: false, link: nil),
        ])
    }

    @Test("italic spanning an inline code span renders italic on all three parts")
    func italicAcrossCodeSpan() {
        let runs = styledRuns(of: "*use `grep` here*")
        #expect(runs == [
            StyledRun(text: "use ", isBold: false, isItalic: true, isStruck: false, isCode: false, link: nil),
            StyledRun(text: "grep", isBold: false, isItalic: true, isStruck: false, isCode: true, link: nil),
            StyledRun(text: " here", isBold: false, isItalic: true, isStruck: false, isCode: false, link: nil),
        ])
    }

    @Test("no run in styled output carries the .code presentation intent")
    func codeIntentIsStripped() {
        let attributed = InlineMarkdownStyler.styledLine(
            "**a `b` c** and `d` and ``e``", inlineCodeColor: codeColor
        )
        for run in attributed.runs {
            #expect(run.inlinePresentationIntent?.contains(.code) != true)
        }
    }

    // MARK: - Code span styling

    @Test("multi-token code span gets the inline code color and keeps its text")
    func plainCodeSpanGetsColor() {
        let runs = styledRuns(of: "run `swift test now` please")
        #expect(runs == [
            StyledRun(text: "run ", isBold: false, isItalic: false, isStruck: false, isCode: false, link: nil),
            StyledRun(text: "swift test now", isBold: false, isItalic: false, isStruck: false, isCode: true, link: nil),
            StyledRun(text: " please", isBold: false, isItalic: false, isStruck: false, isCode: false, link: nil),
        ])
    }

    @Test("double-backtick span keeps its inner backtick as content")
    func doubleBacktickSpanKeepsInnerBacktick() {
        let runs = styledRuns(of: "a ``b ` c`` d")
        #expect(runs.contains(StyledRun(text: "b ` c", isBold: false, isItalic: false, isStruck: false, isCode: true, link: nil)))
    }

    @Test("unmatched backtick stays literal while the matched pair still styles")
    func unmatchedBacktickStaysLiteral() {
        let runs = styledRuns(of: "a `b` c ` d")
        #expect(runs.contains(StyledRun(text: "b", isBold: false, isItalic: false, isStruck: false, isCode: true, link: nil)))
        #expect(plainText(of: "a `b` c ` d") == "a b c ` d")
    }

    // MARK: - Standalone linkable code spans

    @Test("code span holding a single absolute path becomes a file link, not colored code")
    func standalonePathCodeSpanBecomesLink() {
        let path = "/tmp/agent-smith-nonexistent/report.md"
        let runs = styledRuns(of: "see `\(path)` for details")
        let linkRun = runs.first(where: { $0.link != nil })
        #expect(linkRun?.text == path)
        #expect(linkRun?.link == URL(fileURLWithPath: path))
        #expect(linkRun?.isCode == false)
    }

    @Test("code span holding a single URL or email becomes a link")
    func standaloneURLAndEmailCodeSpansBecomeLinks() {
        let urlRuns = styledRuns(of: "docs: `https://example.com/guide`")
        let urlRun = urlRuns.first(where: { $0.link != nil })
        #expect(urlRun?.link == URL(string: "https://example.com/guide"))
        #expect(urlRun?.text == "https://example.com/guide")
        #expect(urlRun?.isCode == false)

        let emailRuns = styledRuns(of: "contact `foo@bar.com` today")
        let emailRun = emailRuns.first(where: { $0.link != nil })
        #expect(emailRun?.link == URL(string: "mailto:foo@bar.com"))
        #expect(emailRun?.text == "foo@bar.com")
        #expect(emailRun?.isCode == false)
    }

    @Test("standalone path code span inside bold keeps the bold and gains the link")
    func standalonePathCodeSpanInsideBoldKeepsBoldAndLinks() {
        let path = "/tmp/agent-smith-nonexistent/x"
        let runs = styledRuns(of: "**check `\(path)` now**")
        #expect(runs == [
            StyledRun(text: "check ", isBold: true, isItalic: false, isStruck: false, isCode: false, link: nil),
            StyledRun(text: path, isBold: true, isItalic: false, isStruck: false, isCode: false, link: URL(fileURLWithPath: path)),
            StyledRun(text: " now", isBold: true, isItalic: false, isStruck: false, isCode: false, link: nil),
        ])
    }

    // MARK: - Linkification stays outside code spans

    @Test("existing path inside a multi-token code span is not linkified")
    func linkifyDoesNotReachInsideCodeSpans() {
        // /usr/bin exists, so a leak of linkifyPaths into the span would wrap it
        // and the injected brackets would render literally inside the code span.
        let line = "check `ls /usr/bin now` output"
        let runs = styledRuns(of: line)
        #expect(runs.allSatisfy { $0.link == nil })
        #expect(plainText(of: line) == "check ls /usr/bin now output")
    }

    @Test("existing path outside a code span is linkified in the same line")
    func pathOutsideCodeSpanIsLinkified() throws {
        let file = try makeTempFile()
        defer { cleanup(file) }
        let runs = styledRuns(of: "see \(file.path) and run `make` after")
        #expect(runs.contains(where: { $0.link == URL(fileURLWithPath: file.path) }))
        #expect(runs.contains(StyledRun(text: "make", isBold: false, isItalic: false, isStruck: false, isCode: true, link: nil)))
    }

    @Test("bare URL and email outside code spans become links")
    func bareURLAndEmailAreLinkified() {
        let runs = styledRuns(of: "visit https://example.com or mail foo@bar.com")
        #expect(runs.contains(where: { $0.link == URL(string: "https://example.com") }))
        #expect(runs.contains(where: { $0.link == URL(string: "mailto:foo@bar.com") }))
    }

    @Test("bare URL abutting an unpaired backtick links cleanly, backtick stays literal")
    func bareURLAbuttingUnpairedBacktickStaysClean() {
        // The unpaired backtick is plain-stretch content (the mask cuts only at
        // paired spans), so the URL regex must stop before it — a swallowed
        // backtick pairs with the injected [url](url) syntax at parse time,
        // destroying the link and coloring the leftovers as code.
        let line = "see https://x.com/abc` more text"
        let runs = styledRuns(of: line)
        #expect(runs.contains(where: { $0.link == URL(string: "https://x.com/abc") }))
        #expect(runs.allSatisfy { !$0.isCode })
        #expect(plainText(of: line) == "see https://x.com/abc` more text")
    }

    @Test("authored link containing a real path renders as the authored link")
    func authoredLinkContainingPathRendersIntact() {
        // The old sequential linkifier injected a file link inside the authored
        // link's text, voiding the author's link and rendering brackets literally.
        let runs = styledRuns(of: "[see /usr/bin](https://x.com) after")
        #expect(runs == [
            StyledRun(text: "see /usr/bin", isBold: false, isItalic: false, isStruck: false, isCode: false, link: URL(string: "https://x.com")),
            StyledRun(text: " after", isBold: false, isItalic: false, isStruck: false, isCode: false, link: nil),
        ])
    }

    @Test("URL containing an email renders as one link with the full URL")
    func urlContainingEmailRendersAsSingleLink() {
        let line = "visit https://x.com/?email=a@b.com now"
        let runs = styledRuns(of: line)
        #expect(runs == [
            StyledRun(text: "visit ", isBold: false, isItalic: false, isStruck: false, isCode: false, link: nil),
            StyledRun(text: "https://x.com/?email=a@b.com", isBold: false, isItalic: false, isStruck: false, isCode: false, link: URL(string: "https://x.com/?email=a@b.com")),
            StyledRun(text: " now", isBold: false, isItalic: false, isStruck: false, isCode: false, link: nil),
        ])
        #expect(plainText(of: line) == line)
    }

    @Test("markdown link syntax spanning a code span collapses to one plain link run")
    func markdownLinkAcrossCodeSpan() {
        // The parser drops the .code intent inside link syntax and merges the text.
        // Pinned exactly so a future parser that starts emitting .code inside links
        // (which would route the run through the code-coloring branch) fails loudly.
        let runs = styledRuns(of: "[see `code` here](https://example.com)")
        #expect(runs == [
            StyledRun(text: "see code here", isBold: false, isItalic: false, isStruck: false, isCode: false, link: URL(string: "https://example.com")),
        ])
    }

    // MARK: - Tilde handling

    @Test("two home-relative paths in one line do not strike through the text between")
    func pathTildesDoNotStrikeThrough() {
        let line = "check ~/cursor/a and ~/cursor/b done"
        let runs = styledRuns(of: line)
        #expect(runs.allSatisfy { !$0.isStruck })
        #expect(plainText(of: line) == line)
    }

    @Test("deliberate ~~strikethrough~~ still strikes")
    func deliberateStrikethroughPreserved() {
        let runs = styledRuns(of: "~~gone~~ kept")
        #expect(runs.contains(StyledRun(text: "gone", isBold: false, isItalic: false, isStruck: true, isCode: false, link: nil)))
    }

    @Test("strikethrough whose delimiter abuts a slash still strikes")
    func strikethroughDelimiterAbuttingSlashPreserved() {
        // The second tilde of a `~~` delimiter next to a slash must not be
        // escaped as a `~/` path start — that broke the whole strikethrough.
        let openingRuns = styledRuns(of: "~~/gone~~ kept")
        #expect(openingRuns.contains(StyledRun(text: "/gone", isBold: false, isItalic: false, isStruck: true, isCode: false, link: nil)))

        let closingRuns = styledRuns(of: "~~old~~/new stays")
        #expect(closingRuns.contains(StyledRun(text: "old", isBold: false, isItalic: false, isStruck: true, isCode: false, link: nil)))
        #expect(plainText(of: "~~old~~/new stays") == "old/new stays")
    }

    @Test("home-relative path inside a multi-token code span stays literal")
    func tildePathInsideCodeSpanStaysLiteral() {
        let runs = styledRuns(of: "run `ls ~/cursor stuff` after")
        #expect(runs.contains(StyledRun(text: "ls ~/cursor stuff", isBold: false, isItalic: false, isStruck: false, isCode: true, link: nil)))
    }

    // MARK: - Non-regressions

    @Test("space-surrounded asterisks are not emphasis")
    func multiplicationAsterisksStayLiteral() {
        let line = "5 * 3 = 15 and `x` and 2 * 4"
        let runs = styledRuns(of: line)
        #expect(runs.allSatisfy { !$0.isBold && !$0.isItalic })
        #expect(plainText(of: line) == "5 * 3 = 15 and x and 2 * 4")
    }

    @Test("degenerate inputs don't crash and keep their text", arguments: ["", "`", "``", "```", "   ", "\\"])
    func degenerateInputs(line: String) {
        _ = styledRuns(of: line)
        #expect(plainText(of: line) == line)
    }

    // MARK: - standaloneLinkTarget (PathLinkifier companion)

    @Test("standaloneLinkTarget matches standaloneLink's classification")
    func standaloneLinkTargetMatchesMarkdownVariant() {
        #expect(PathLinkifier.standaloneLinkTarget(for: "/tmp/x.md") == URL(fileURLWithPath: "/tmp/x.md"))
        #expect(PathLinkifier.standaloneLinkTarget(for: "https://example.com") == URL(string: "https://example.com"))
        #expect(PathLinkifier.standaloneLinkTarget(for: "foo@bar.com") == URL(string: "mailto:foo@bar.com"))
        #expect(PathLinkifier.standaloneLinkTarget(for: "see /tmp/x.md") == nil)
        #expect(PathLinkifier.standaloneLinkTarget(for: "") == nil)
        #expect(PathLinkifier.standaloneLinkTarget(for: "foo/bar.md") == nil)
    }
}
