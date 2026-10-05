import Foundation

/// Wraps plain text with markdown link syntax (`[text](url)`) for URLs, emails, and
/// absolute file paths. Designed to feed `AttributedString(markdown:)` so the resulting
/// `Text` carries a real `.link` attribute (clickable, right-clickable, surviving
/// `.textSelection(.enabled)`).
///
/// `standaloneLink(for:)` is side-effect-free and checks existence only for a path
/// containing spaces. `linkifyPaths(_:)` (the free-text scanner) resolves each path
/// against the filesystem, which both keeps rhetorical path mentions in prose from
/// becoming links and is the only way to know where a path with spaces ends.
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

    /// Matches where an absolute POSIX path (`/` or `~/`) can START. Where it ENDS is
    /// decided by the filesystem (`resolvedPathEnd`), not by a character class: a
    /// path may contain spaces (`~/Library/Application Support/…`), parentheses,
    /// non-ASCII — anything but `/` — so no regex can find its end in prose.
    /// Negative lookbehind excludes: existing markdown link syntax (`[` / `(`),
    /// URL scheme tails (`:` / `/`), and word-adjacent slashes like `a/b` which
    /// aren't filesystem paths. The lookahead requires a first component.
    /// `try?` — same rationale as `bareURLRegex`: literal pattern, compile-time correct.
    private static let pathStartRegex = try? NSRegularExpression(
        pattern: #"(?<![\w/:\[(])(?:~/|/)(?=[^\s/])"#
    )

    /// Characters that end a sentence, close a bracket/quote, or close markdown
    /// emphasis around a path. A run of them followed by whitespace or end of text
    /// is prose, so a path may end right before it ("see /foo/bar." does not try to
    /// open `/foo/bar.`, and `**/usr/bin**` still links `/usr/bin`).
    private static let trailingPunctuation: Set<Unicode.Scalar> = [
        ".", ",", ";", ":", "!", "?", ")", "]", "}", ">", "'", "\"", "\u{2019}", "\u{201D}",
        "*", "_", "~", "`",
    ]

    /// Returns the markdown-link-wrapped form of `text` if (after trimming) the entire
    /// content is a single linkable token: an absolute path, an http(s)/file/mailto URL,
    /// or a bare email. Returns nil otherwise. Existence of a whitespace-free path is
    /// **not** checked here — such a whole token is almost always meant as a path, and
    /// the click handler validates existence lazily when the link is actually opened.
    /// A path containing spaces must exist (see `standaloneLinkTarget`).
    public static func standaloneLink(for text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = standaloneLinkTarget(for: trimmed) else { return nil }
        // The link **text** keeps the original trimmed form (e.g. `~/...`) so users
        // see what they typed. The link **target** is the parsed URL's `absoluteString`,
        // so it is normalized (non-ASCII → percent-encoding, a bare `%` → `%25`) rather
        // than the input verbatim. Deliberate: `AttributedString(markdown:)` normalizes
        // destinations identically, so the resolved `.link` is unchanged, and the
        // markdown path agrees byte-for-byte with direct `standaloneLinkTarget` consumers.
        return "[\(escapedLinkText(trimmed))](\(target.absoluteString))"
    }

    /// The URL that `standaloneLink(for:)` would link to, for callers that set the
    /// `.link` attribute on already-parsed text instead of injecting markdown syntax.
    /// Same classification, same nil cases; the two cannot drift because the markdown
    /// variant is built from this one.
    ///
    /// A path containing spaces is linked only if it exists: unlike a whitespace-free
    /// token, it is just as likely a command line (`` `/bin/ls -la` ``) as a path,
    /// and only the filesystem can tell the two apart.
    public static func standaloneLinkTarget(for text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") {
            guard !trimmed.contains(where: \.isNewline) else { return nil }
            let expanded = (trimmed as NSString).expandingTildeInPath
            if trimmed.contains(where: { $0.isWhitespace }),
               !FileManager.default.fileExists(atPath: expanded) {
                return nil
            }
            // `URL(fileURLWithPath:)` handles percent-encoding of spaces, unicode, etc.
            return URL(fileURLWithPath: expanded)
        }

        guard !trimmed.contains(where: { $0.isWhitespace }) else { return nil }

        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
            || trimmed.hasPrefix("file://") || trimmed.hasPrefix("mailto:") {
            return URL(string: trimmed)
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
    /// paths that exist on disk become `[path](file:///...)`, including paths with
    /// spaces (see `resolvedPathEnd`). Non-existent paths are left untouched.
    /// Trailing sentence punctuation stays outside the link so "see /foo/bar."
    /// doesn't try to open `/foo/bar.`. `~/`-prefixed
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
            result += "[\(escapedLinkText(candidate.linkText))](\(candidate.target))"
            lastEnd = candidate.range.upperBound
        }
        result += text[lastEnd...]
        return result
    }

    private static func pathCandidates(in text: String) -> [LinkCandidate] {
        guard let regex = pathStartRegex else { return [] }
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        var candidates: [LinkCandidate] = []
        // Paths found earlier claim their text: a path with spaces can contain a
        // later start match ("/tmp/a /b" where "a /b" is one name) that must not
        // be resolved again as a second, overlapping path.
        var claimedUpTo = text.startIndex
        for match in regex.matches(in: text, range: fullRange) {
            guard let start = Range(match.range, in: text)?.lowerBound,
                  start >= claimedUpTo,
                  let end = resolvedPathEnd(in: text, from: start) else { continue }
            let linkText = String(text[start..<end])
            let expanded = (linkText as NSString).expandingTildeInPath
            // `URL(fileURLWithPath:)` handles percent-encoding of spaces, unicode, etc.
            candidates.append(LinkCandidate(
                range: start..<end,
                linkText: linkText,
                target: URL(fileURLWithPath: expanded).absoluteString
            ))
            claimedUpTo = end
        }
        return candidates
    }

    /// Where the existing path starting at `start` ends, or nil if no path there
    /// exists on disk in full.
    ///
    /// Resolves one component at a time against the filesystem. Inside a directory
    /// already known to exist, a component may run across single spaces up to the
    /// next `/`, so the candidate ends are every word end within it; the LONGEST
    /// that exists wins ("Application Support" over a sibling "Application").
    /// Only a directory continues the walk past its `/`.
    ///
    /// A path is linked only when it ends at a path-end boundary (see
    /// `isPathEndBoundary`; a trailing `/` after a directory is kept). Text that
    /// keeps going past what exists
    /// ("/Users/me/missing.txt") links nothing rather than a misleading fragment.
    ///
    /// Bounded by the filesystem's own limits: a component never exceeds
    /// `NAME_MAX` bytes and a path never exceeds `PATH_MAX`, so a slash in prose
    /// costs at most one existence check per word in the next 255 bytes.
    static func resolvedPathEnd(in text: String, from start: String.Index) -> String.Index? {
        let firstComponentStart: String.Index
        if text[start...].hasPrefix("~/") {
            firstComponentStart = text.index(start, offsetBy: 2)
        } else if text[start] == "/" {
            firstComponentStart = text.index(after: start)
        } else {
            return nil
        }

        let fileManager = FileManager.default
        var resolvedEnd: String.Index?
        var componentStart = firstComponentStart
        walk: while componentStart < text.endIndex {
            var componentEnds: [String.Index] = []
            var componentBytes = 0
            var i = componentStart
            scan: while true {
                let atLimit = i == text.endIndex || text[i] == "/"
                    || (text[i].isWhitespace && text[i] != " ")
                if i > componentStart, !text[text.index(before: i)].isWhitespace,
                   atLimit || isPathEndBoundary(at: i, in: text) {
                    componentEnds.append(i)
                }
                if atLimit { break scan }
                componentBytes += text[i].utf8.count
                if componentBytes > Int(NAME_MAX) { break scan }
                i = text.index(after: i)
            }

            var resolvedComponent: (end: String.Index, isDirectory: Bool)?
            for end in componentEnds.reversed() {
                let candidate = String(text[start..<end])
                guard candidate.utf8.count <= Int(PATH_MAX) else { continue }
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(
                    atPath: (candidate as NSString).expandingTildeInPath,
                    isDirectory: &isDirectory
                ) {
                    resolvedComponent = (end, isDirectory.boolValue)
                    break
                }
            }
            guard let resolvedComponent else { break walk }
            resolvedEnd = resolvedComponent.end
            guard resolvedComponent.isDirectory,
                  resolvedComponent.end < text.endIndex,
                  text[resolvedComponent.end] == "/" else { break walk }
            componentStart = text.index(after: resolvedComponent.end)
        }

        guard let resolvedEnd else { return nil }
        if isPathEndBoundary(at: resolvedEnd, in: text) { return resolvedEnd }
        // A directory written with its trailing slash ("see /tmp/foo/ for …"):
        // the walk stopped at the slash because no component followed it.
        if text[resolvedEnd] == "/" {
            let afterSlash = text.index(after: resolvedEnd)
            if isPathEndBoundary(at: afterSlash, in: text) { return afterSlash }
        }
        return nil
    }

    /// Where a path may end: a prose boundary, or a character the token-based
    /// matcher this resolver replaced already treated as ending a path — the `:` of
    /// `File.swift:42`, the `#` of `page.html#top`, `(`, `@`, non-ASCII. Keeping
    /// those means the paths that matcher linked still link; what the filesystem
    /// walk adds is paths containing spaces (and, via the longest-first search,
    /// names containing those characters).
    private static func isPathEndBoundary(at index: String.Index, in text: String) -> Bool {
        if isProseBoundary(at: index, in: text) { return true }
        // Not a prose boundary, so `index` is not `endIndex`.
        let character = text[index]
        let continuesLegacyToken = character == "/" || character == "." || character == "_"
            || character == "~" || character == "-"
            || (character.isASCII && (character.isLetter || character.isNumber))
        return !continuesLegacyToken
    }

    /// True when the text from `index` on is whitespace, end of text, or a run of
    /// `trailingPunctuation` followed by one of those. Punctuation is matched on a
    /// character's FIRST scalar so a combining mark riding on a dot (".\u{0301}")
    /// still reads as the sentence-ending dot it renders as.
    private static func isProseBoundary(at index: String.Index, in text: String) -> Bool {
        var i = index
        while i < text.endIndex,
              let scalar = text[i].unicodeScalars.first,
              trailingPunctuation.contains(scalar) {
            i = text.index(after: i)
        }
        return i == text.endIndex || text[i].isWhitespace
    }

    /// Backslash-escapes the characters that would otherwise be parsed as markdown
    /// inside link text: brackets end the link text early, backticks open code
    /// spans, `*` and `<` start emphasis and autolinks, and a backslash escapes
    /// whatever follows it. `_` is escaped only where it can delimit emphasis —
    /// CommonMark never treats an underscore between two alphanumerics as one, and
    /// those are the common case in file names. `~` is deliberately left alone;
    /// `InlineMarkdownStyler.escapePathTildes` owns it, and escaping it here too
    /// would double the backslash.
    static func escapedLinkText(_ text: String) -> String {
        let alwaysEscaped: Set<Character> = ["\\", "[", "]", "`", "*", "<", ">"]
        let characters = Array(text)
        var result = ""
        result.reserveCapacity(text.count)
        for (offset, character) in characters.enumerated() {
            if alwaysEscaped.contains(character) {
                result.append("\\")
            } else if character == "_" {
                let isIntraword = offset > 0 && offset < characters.count - 1
                    && (characters[offset - 1].isLetter || characters[offset - 1].isNumber)
                    && (characters[offset + 1].isLetter || characters[offset + 1].isNumber)
                if !isIntraword { result.append("\\") }
            }
            result.append(character)
        }
        return result
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
