import Foundation

/// Wraps plain text with markdown link syntax (`[text](url)`) for URLs, emails, and
/// absolute file paths. Designed to feed `AttributedString(markdown:)` so the resulting
/// `Text` carries a real `.link` attribute (clickable, right-clickable, surviving
/// `.textSelection(.enabled)`).
///
/// `standaloneLink(for:)` is pure / side-effect-free. `linkifyPaths(_:)` (the free-text
/// scanner) does a `FileManager.fileExists` check per candidate so that rhetorical path
/// mentions in prose aren't turned into links.
public enum PathLinkifier {

    /// Compiled once and reused across all calls.
    /// `try?` — pattern is a compile-time literal; init only fails for malformed
    /// patterns, which would be caught at first run during development.
    /// Backtick is excluded because it is never a legal raw URI character (RFC 3986),
    /// and a swallowed backtick pairs with the injected `[url](url)` syntax at the
    /// whole-line markdown parse, destroying the link.
    private static let bareURLRegex = try? NSRegularExpression(
        pattern: #"(?<![(\[])https?://[^\s)\]*`]+"#
    )

    /// Matches plain email addresses not already inside markdown link syntax. Conservative:
    /// requires standard local@domain.tld shape with at least one TLD-like suffix. Negative
    /// lookbehind on `[`, `(`, `:` skips emails already wrapped as a markdown link or used
    /// as a `mailto:` URL component.
    /// `try?` — same rationale as `bareURLRegex`: literal pattern, compile-time correct.
    private static let emailRegex = try? NSRegularExpression(
        pattern: #"(?<![\[(:])[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#
    )

    /// Matches absolute POSIX paths starting with `/` or `~/`.
    /// Negative lookbehind excludes: existing markdown link syntax (`[` / `(`),
    /// URL scheme tails (`:` / `/`), and word-adjacent slashes like `a/b` which
    /// aren't filesystem paths.
    /// `try?` — same rationale as `bareURLRegex`: literal pattern, compile-time correct.
    private static let pathRegex = try? NSRegularExpression(
        pattern: #"(?<![\w/:\[(])(?:~/|/)[A-Za-z0-9._/~\-]+"#
    )

    /// Returns the markdown-link-wrapped form of `text` if (after trimming) the entire
    /// content is a single linkable token: an absolute path, an http(s)/file/mailto URL,
    /// or a bare email. Returns nil otherwise. Path existence is **not** checked here —
    /// a whole-token, whitespace-free path is almost always meant as a path, and the
    /// click handler validates existence lazily when the link is actually opened.
    public static func standaloneLink(for text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = standaloneLinkTarget(for: trimmed) else { return nil }
        // The link **text** keeps the original trimmed form (e.g. `~/...`) so users
        // see what they typed. The link **target** is the parsed URL's `absoluteString`,
        // so it is normalized (non-ASCII → percent-encoding, a bare `%` → `%25`) rather
        // than the input verbatim. Deliberate: `AttributedString(markdown:)` normalizes
        // destinations identically, so the resolved `.link` is unchanged, and the
        // markdown path agrees byte-for-byte with direct `standaloneLinkTarget` consumers.
        return "[\(trimmed)](\(target.absoluteString))"
    }

    /// The URL that `standaloneLink(for:)` would link to, for callers that set the
    /// `.link` attribute on already-parsed text instead of injecting markdown syntax.
    /// Same classification, same nil cases; the two cannot drift because the markdown
    /// variant is built from this one.
    public static func standaloneLinkTarget(for text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: { $0.isWhitespace }) else { return nil }

        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
            || trimmed.hasPrefix("file://") || trimmed.hasPrefix("mailto:") {
            return URL(string: trimmed)
        }

        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            // `URL(fileURLWithPath:)` handles percent-encoding of spaces, unicode, etc.
            return URL(fileURLWithPath: expanded)
        }

        if let regex = emailRegex {
            let nsRange = NSRange(location: 0, length: (trimmed as NSString).length)
            if let match = regex.firstMatch(in: trimmed, range: nsRange),
               match.range == nsRange {
                return URL(string: "mailto:\(trimmed)")
            }
        }
        return nil
    }

    /// Wraps paths, bare URLs, and emails in ONE pass over the original text.
    ///
    /// Single-pass by design: the previous implementation ran three passes in
    /// sequence, each regex-scanning the previous pass's OUTPUT, so a later pass
    /// could match inside link syntax an earlier pass had just injected
    /// ("https://x.com/?email=a@b.com" got a mailto link nested inside the URL
    /// link), and any pass could match inside an AUTHORED `[text](url)` span
    /// ("[see /usr/bin](https://x.com)"), where the injected nesting voids the
    /// outer link entirely (CommonMark links don't nest) and every bracket
    /// renders literally. Candidates are now collected against the original
    /// text, anything overlapping an authored link span is dropped, overlaps
    /// among candidates resolve earliest-start-then-longest, and the text is
    /// rewritten once — injected syntax is never rescanned.
    public static func linkify(_ text: String) -> String {
        linkified(text, including: .all)
    }

    /// Path-only linkification (see `linkify` for the shared engine): absolute
    /// paths that exist on disk become `[path](file:///...)`. Non-existent paths
    /// are left untouched. Trailing sentence punctuation (`.,;:)]`) stays outside
    /// the link so "see /foo/bar." doesn't try to open `/foo/bar.`. `~/`-prefixed
    /// paths are expanded against the user's home directory for the existence
    /// check and the link URL, but the link **text** keeps the original `~/...`
    /// form so users see what they typed.
    static func linkifyPaths(_ text: String) -> String {
        linkified(text, including: .paths)
    }

    /// URL-only linkification (see `linkify` for the shared engine): bare
    /// `https?://` URLs become `[url](url)` so they parse as real markdown links
    /// via `AttributedString(markdown:)`.
    static func linkifyBareURLs(_ text: String) -> String {
        linkified(text, including: .bareURLs)
    }

    /// Email-only linkification (see `linkify` for the shared engine): plain
    /// emails become `[email](mailto:email)`. Unlike `LocalizedStringKey`, the
    /// AttributedString markdown parser does NOT auto-detect emails — explicit
    /// wrapping is required to make them clickable.
    static func linkifyEmails(_ text: String) -> String {
        linkified(text, including: .emails)
    }

    // MARK: - Linkification engine

    /// One linkifiable token found in the original text, before overlap
    /// resolution. `range` covers exactly the characters the markdown link
    /// replaces — trailing sentence punctuation on a path is outside it, so it
    /// stays outside the link.
    private struct LinkCandidate {
        let range: Range<String.Index>
        let linkText: String
        let target: String
    }

    /// Which token kinds a linkification call considers. The per-kind entry
    /// points exist so each detector stays independently testable; production
    /// rendering uses all three.
    private struct LinkCandidateKinds: OptionSet {
        let rawValue: Int
        static let paths = LinkCandidateKinds(rawValue: 1 << 0)
        static let bareURLs = LinkCandidateKinds(rawValue: 1 << 1)
        static let emails = LinkCandidateKinds(rawValue: 1 << 2)
        static let all: LinkCandidateKinds = [.paths, .bareURLs, .emails]
    }

    private static func linkified(_ text: String, including kinds: LinkCandidateKinds) -> String {
        var candidates: [LinkCandidate] = []
        if kinds.contains(.paths) { candidates += pathCandidates(in: text) }
        if kinds.contains(.bareURLs) { candidates += bareURLCandidates(in: text) }
        if kinds.contains(.emails) { candidates += emailCandidates(in: text) }
        guard !candidates.isEmpty else { return text }

        let protectedSpans = markdownLinkSpans(in: text)
        candidates.sort { first, second in
            first.range.lowerBound != second.range.lowerBound
                ? first.range.lowerBound < second.range.lowerBound
                : first.range.upperBound > second.range.upperBound
        }

        var accepted: [LinkCandidate] = []
        var cursor = text.startIndex
        for candidate in candidates {
            // Overlap resolution runs BEFORE the protection filter, and a
            // position-winner claims its span even when protection then discards
            // it: a URL overlapping an authored link must not resurrect the email
            // nested inside it — that region is URL text whether or not it gets
            // wrapped, and wrapping a fragment of it mid-token mangles the render.
            guard candidate.range.lowerBound >= cursor else { continue }
            cursor = candidate.range.upperBound
            guard !protectedSpans.contains(where: { $0.overlaps(candidate.range) }) else { continue }
            accepted.append(candidate)
        }
        guard !accepted.isEmpty else { return text }

        var result = ""
        var lastEnd = text.startIndex
        for candidate in accepted {
            result += text[lastEnd..<candidate.range.lowerBound]
            result += "[\(candidate.linkText)](\(candidate.target))"
            lastEnd = candidate.range.upperBound
        }
        result += text[lastEnd...]
        return result
    }

    private static func pathCandidates(in text: String) -> [LinkCandidate] {
        guard let regex = pathRegex else { return [] }
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        let fileManager = FileManager.default
        return regex.matches(in: text, range: fullRange).compactMap { match in
            guard let initialRange = Range(match.range, in: text) else { return nil }
            var candidate = String(text[initialRange])
            // Trailing sentence punctuation is prose, not path: keep it outside
            // the link.
            while let last = candidate.last, ".,;:)]".contains(last) {
                candidate.removeLast()
            }
            guard !candidate.isEmpty else { return nil }
            let expanded = (candidate as NSString).expandingTildeInPath
            guard fileManager.fileExists(atPath: expanded) else { return nil }
            // The shrunken range is computed in UTF-16 units off the match range
            // (every strippable character is single-unit ASCII), NOT by walking
            // the character view backwards: the match boundary can sit
            // mid-grapheme when a combining mark follows the final stripped dot,
            // and `index(before:)` there first rounds down to the grapheme start
            // — eating one extra character, which the rewrite then duplicates.
            let strippedUnits = match.range.length - candidate.utf16.count
            guard let range = Range(
                NSRange(location: match.range.location, length: match.range.length - strippedUnits),
                in: text
            ) else { return nil }
            // `URL(fileURLWithPath:)` handles percent-encoding of spaces, unicode, etc.
            return LinkCandidate(
                range: range,
                linkText: candidate,
                target: URL(fileURLWithPath: expanded).absoluteString
            )
        }
    }

    private static func bareURLCandidates(in text: String) -> [LinkCandidate] {
        guard let regex = bareURLRegex else { return [] }
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        return regex.matches(in: text, range: fullRange).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let url = String(text[range])
            return LinkCandidate(range: range, linkText: url, target: url)
        }
    }

    private static func emailCandidates(in text: String) -> [LinkCandidate] {
        guard let regex = emailRegex else { return [] }
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        return regex.matches(in: text, range: fullRange).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let email = String(text[range])
            return LinkCandidate(range: range, linkText: email, target: "mailto:\(email)")
        }
    }

    /// Spans of authored markdown link syntax — `[text](destination)` with
    /// balanced brackets in the text and balanced parens in the destination —
    /// that linkification must never rewrite: CommonMark links don't nest, so
    /// injecting a link inside either half voids the author's link and renders
    /// every bracket literally. Conservative on purpose: over-detection (a
    /// bracket-paren shape the parser would reject as a link) just means a
    /// missed linkification. Exotic real-link forms this scanner misses — a
    /// quoted title or `<pointy>` destination hiding an unbalanced `)` — simply
    /// keep the pre-rewrite behavior instead of gaining protection.
    /// Backslash-escaped brackets don't open spans, matching the parser's
    /// escape handling.
    static func markdownLinkSpans(in text: String) -> [Range<String.Index>] {
        var spans: [Range<String.Index>] = []
        var i = text.startIndex
        while i < text.endIndex {
            let character = text[i]
            if character == "\\" {
                i = text.index(after: i)
                if i < text.endIndex { i = text.index(after: i) }
                continue
            }
            guard character == "[" else {
                i = text.index(after: i)
                continue
            }
            if let span = markdownLinkSpan(startingAt: i, in: text) {
                spans.append(span)
                i = span.upperBound
            } else {
                i = text.index(after: i)
            }
        }
        return spans
    }

    /// The full `[text](destination)` span starting at `openBracket`, or nil if
    /// the shape doesn't complete. Both loops advance past the current character
    /// FIRST so an escape at end-of-text cannot step past `endIndex`.
    private static func markdownLinkSpan(
        startingAt openBracket: String.Index,
        in text: String
    ) -> Range<String.Index>? {
        var bracketDepth = 1
        var i = text.index(after: openBracket)
        while i < text.endIndex {
            let character = text[i]
            i = text.index(after: i)
            switch character {
            case "\\":
                if i < text.endIndex { i = text.index(after: i) }
            case "[":
                bracketDepth += 1
            case "]":
                bracketDepth -= 1
                if bracketDepth == 0 {
                    guard i < text.endIndex, text[i] == "(" else { return nil }
                    var parenDepth = 1
                    var j = text.index(after: i)
                    while j < text.endIndex {
                        let destinationCharacter = text[j]
                        j = text.index(after: j)
                        switch destinationCharacter {
                        case "\\":
                            if j < text.endIndex { j = text.index(after: j) }
                        case "(":
                            parenDepth += 1
                        case ")":
                            parenDepth -= 1
                            if parenDepth == 0 { return openBracket..<j }
                        default:
                            break
                        }
                    }
                    return nil
                }
            default:
                break
            }
        }
        return nil
    }
}
