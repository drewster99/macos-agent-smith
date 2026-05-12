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
    private static let bareURLRegex = try? NSRegularExpression(
        pattern: #"(?<![(\[])https?://[^\s)\]*]+"#
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
        guard !trimmed.isEmpty,
              !trimmed.contains(where: { $0.isWhitespace }) else { return nil }

        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
            || trimmed.hasPrefix("file://") || trimmed.hasPrefix("mailto:") {
            guard URL(string: trimmed) != nil else { return nil }
            return "[\(trimmed)](\(trimmed))"
        }

        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            // `URL(fileURLWithPath:)` handles percent-encoding; the link **text** keeps
            // the original `~/...` form so users see what they typed.
            let urlString = URL(fileURLWithPath: expanded).absoluteString
            return "[\(trimmed)](\(urlString))"
        }

        if let regex = emailRegex {
            let nsRange = NSRange(location: 0, length: (trimmed as NSString).length)
            if let match = regex.firstMatch(in: trimmed, range: nsRange),
               match.range == nsRange {
                return "[\(trimmed)](mailto:\(trimmed))"
            }
        }
        return nil
    }

    /// Runs all inline linkification passes in the order that avoids collisions:
    /// path wrapping first (emits `file://` markdown links), then bare URL wrapping,
    /// then email wrapping (emits `mailto:` markdown links).
    public static func linkify(_ text: String) -> String {
        linkifyEmails(linkifyBareURLs(linkifyPaths(text)))
    }

    /// Wraps absolute file paths that exist on disk with `[path](file:///...)` markdown.
    /// Non-existent paths are left untouched. Trailing sentence punctuation (`.,;:)]`) is
    /// preserved outside the link so "see /foo/bar." doesn't try to open `/foo/bar.`.
    /// `~/`-prefixed paths are expanded against the user's home directory for the existence
    /// check and the link URL, but the link **text** keeps the original `~/...` form so
    /// users see what they typed.
    static func linkifyPaths(_ text: String) -> String {
        guard let regex = pathRegex else { return text }

        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        let matches = regex.matches(in: text, range: fullRange)
        guard !matches.isEmpty else { return text }

        var result = ""
        var lastEnd = text.startIndex
        let fm = FileManager.default

        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[lastEnd..<range.lowerBound]
            lastEnd = range.upperBound

            var candidate = String(text[range])
            var trailing = ""
            while let last = candidate.last, ".,;:)]".contains(last) {
                trailing = String(last) + trailing
                candidate.removeLast()
            }

            guard !candidate.isEmpty else {
                result += String(text[range])
                continue
            }

            let expanded = (candidate as NSString).expandingTildeInPath
            guard fm.fileExists(atPath: expanded) else {
                result += String(text[range])
                continue
            }

            // `URL(fileURLWithPath:)` handles percent-encoding of spaces, unicode, etc.
            let urlString = URL(fileURLWithPath: expanded).absoluteString
            result += "[\(candidate)](\(urlString))\(trailing)"
        }
        result += text[lastEnd...]
        return result
    }

    /// Wraps bare `https?://` URLs (not already in markdown link syntax) with `[url](url)`
    /// so they parse as real markdown links via `AttributedString(markdown:)`.
    static func linkifyBareURLs(_ text: String) -> String {
        guard let regex = bareURLRegex else { return text }

        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        let matches = regex.matches(in: text, range: fullRange)

        var result = ""
        var lastEnd = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[lastEnd..<range.lowerBound]
            let url = String(text[range])
            result += "[\(url)](\(url))"
            lastEnd = range.upperBound
        }
        result += text[lastEnd...]
        return result
    }

    /// Wraps plain email addresses with `[email](mailto:email)` so they render as clickable
    /// `mailto:` links via the AttributedString markdown parser. Unlike `LocalizedStringKey`,
    /// the AttributedString markdown parser does NOT auto-detect emails — explicit wrapping
    /// is required to make them clickable.
    static func linkifyEmails(_ text: String) -> String {
        guard let regex = emailRegex else { return text }

        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        let matches = regex.matches(in: text, range: fullRange)
        guard !matches.isEmpty else { return text }

        var result = ""
        var lastEnd = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[lastEnd..<range.lowerBound]
            let email = String(text[range])
            result += "[\(email)](mailto:\(email))"
            lastEnd = range.upperBound
        }
        result += text[lastEnd...]
        return result
    }
}
