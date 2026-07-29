import Testing
import Foundation
@testable import AgentSmithKit

/// Covers `PathLinkifier`, the helper that wraps URLs, emails, and on-disk file paths with
/// markdown link syntax for `AttributedString(markdown:)`. Filesystem-touching tests build
/// their fixtures under `FileManager.default.temporaryDirectory` so they're hermetic.
@Suite("PathLinkifier")
struct PathLinkifierTests {

    /// Creates an empty file at a unique path under a fresh temp directory and returns
    /// the file's URL. The directory and file are removed when `cleanup` is called.
    private func makeTempFile(named name: String = "file.md") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-smith-linkifier-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(name)
        try Data().write(to: file)
        return file
    }

    private func cleanup(_ file: URL) {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    // MARK: - standaloneLink(for:)

    @Test("absolute path that exists on disk produces a file:// link")
    func standaloneAbsolutePathExists() throws {
        let file = try makeTempFile()
        defer { cleanup(file) }
        let urlString = URL(fileURLWithPath: file.path).absoluteString
        #expect(PathLinkifier.standaloneLink(for: file.path) == "[\(file.path)](\(urlString))")
    }

    @Test("absolute path is wrapped even when it does not exist (existence is checked on click)")
    func standaloneAbsolutePathMissing() {
        let bogus = "/tmp/agent-smith-this-path-does-not-exist-\(UUID().uuidString)/x.md"
        let urlString = URL(fileURLWithPath: bogus).absoluteString
        #expect(PathLinkifier.standaloneLink(for: bogus) == "[\(bogus)](\(urlString))")
    }

    @Test("https URL is wrapped in a markdown link")
    func standaloneHttpsURL() {
        #expect(PathLinkifier.standaloneLink(for: "https://example.com")
                == "[https://example.com](https://example.com)")
        #expect(PathLinkifier.standaloneLink(for: "https://example.com/path?q=1")
                == "[https://example.com/path?q=1](https://example.com/path?q=1)")
    }

    @Test("mailto URL is wrapped as-is")
    func standaloneMailtoURL() {
        #expect(PathLinkifier.standaloneLink(for: "mailto:foo@bar.com")
                == "[mailto:foo@bar.com](mailto:foo@bar.com)")
    }

    @Test("file URL is wrapped as-is")
    func standaloneFileURL() {
        #expect(PathLinkifier.standaloneLink(for: "file:///tmp/example.txt")
                == "[file:///tmp/example.txt](file:///tmp/example.txt)")
    }

    @Test("plain email is wrapped with mailto: target")
    func standalonePlainEmail() {
        #expect(PathLinkifier.standaloneLink(for: "foo@bar.com")
                == "[foo@bar.com](mailto:foo@bar.com)")
    }

    @Test("target is the parsed URL's absoluteString — normalized, not the input verbatim")
    func standaloneLinkNormalizesTarget() {
        // Non-ASCII in a URL path is percent-encoded in the target; the link text is not.
        #expect(PathLinkifier.standaloneLink(for: "https://example.com/é")
                == "[https://example.com/é](https://example.com/%C3%A9)")
        // A bare `%` in an email's local part becomes `%25` in the mailto target.
        #expect(PathLinkifier.standaloneLink(for: "foo%zz@bar.com")
                == "[foo%zz@bar.com](mailto:foo%25zz@bar.com)")
    }

    @Test("markdown output and standaloneLinkTarget resolve to the same .link after parsing")
    func standaloneLinkResolvesToSameURLAsTarget() throws {
        // The invariant that makes target normalization safe: whatever bytes the markdown
        // carries, the `.link` the parser resolves must equal `standaloneLinkTarget(for:)`,
        // because InlineMarkdownStyler sets that URL directly on runs it styles itself.
        for input in ["https://example.com/é", "foo%zz@bar.com", "https://example.com/path?q=1"] {
            let markdown = try #require(PathLinkifier.standaloneLink(for: input))
            let target = try #require(PathLinkifier.standaloneLinkTarget(for: input))
            let parsed = try AttributedString(
                markdown: markdown,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace
                )
            )
            #expect(parsed.runs.compactMap(\.link) == [target])
        }
    }

    @Test("content with internal whitespace is rejected")
    func standaloneRejectsInternalWhitespace() {
        #expect(PathLinkifier.standaloneLink(for: "path: /tmp/foo") == nil)
        #expect(PathLinkifier.standaloneLink(for: "see /tmp/foo") == nil)
    }

    @Test("empty / whitespace-only input is rejected")
    func standaloneRejectsEmpty() {
        #expect(PathLinkifier.standaloneLink(for: "") == nil)
        #expect(PathLinkifier.standaloneLink(for: "   ") == nil)
    }

    @Test("leading/trailing whitespace is trimmed before evaluation")
    func standaloneTrimsOuterWhitespace() throws {
        let file = try makeTempFile()
        defer { cleanup(file) }
        let urlString = URL(fileURLWithPath: file.path).absoluteString
        #expect(PathLinkifier.standaloneLink(for: "  \(file.path)  ")
                == "[\(file.path)](\(urlString))")
    }

    @Test("relative path (no leading slash) returns nil")
    func standaloneRejectsRelativePath() {
        #expect(PathLinkifier.standaloneLink(for: "foo/bar.md") == nil)
    }

    // MARK: - linkifyPaths

    @Test("existing absolute path is wrapped in markdown link")
    func linkifyPathsWrapsExisting() throws {
        let file = try makeTempFile()
        defer { cleanup(file) }
        let input = "see \(file.path) for details"
        let output = PathLinkifier.linkifyPaths(input)
        let urlString = URL(fileURLWithPath: file.path).absoluteString
        #expect(output == "see [\(file.path)](\(urlString)) for details")
    }

    @Test("trailing sentence punctuation stays outside the link")
    func linkifyPathsPreservesTrailingPunctuation() throws {
        let file = try makeTempFile()
        defer { cleanup(file) }
        let input = "see \(file.path)."
        let output = PathLinkifier.linkifyPaths(input)
        let urlString = URL(fileURLWithPath: file.path).absoluteString
        #expect(output == "see [\(file.path)](\(urlString)).")
    }

    @Test("combining mark after a stripped trailing dot does not corrupt the rewrite")
    func linkifyPathsHandlesCombiningMarkAfterStrippedDot() throws {
        // The regex match ends after the dot, mid-grapheme when a combining mark
        // (U+0301) follows — shrinking the range through the character view
        // rounded down first and duplicated the path's final character.
        let file = try makeTempFile()
        defer { cleanup(file) }
        let input = "see \(file.path).\u{0301} end"
        let urlString = URL(fileURLWithPath: file.path).absoluteString
        #expect(PathLinkifier.linkifyPaths(input)
                == "see [\(file.path)](\(urlString)).\u{0301} end")
    }

    @Test("non-existent path is left untouched")
    func linkifyPathsLeavesMissingPathAlone() {
        let bogus = "/tmp/agent-smith-this-path-does-not-exist-\(UUID().uuidString)/x.md"
        let input = "see \(bogus) for details"
        let output = PathLinkifier.linkifyPaths(input)
        #expect(output == input)
    }

    @Test("path already inside markdown link syntax is not double-wrapped")
    func linkifyPathsDoesNotDoubleWrap() throws {
        let file = try makeTempFile()
        defer { cleanup(file) }
        let urlString = URL(fileURLWithPath: file.path).absoluteString
        let alreadyLinked = "see [\(file.path)](\(urlString)) for details"
        let output = PathLinkifier.linkifyPaths(alreadyLinked)
        #expect(output == alreadyLinked)
    }

    // MARK: - linkifyBareURLs

    @Test("bare https URL is wrapped as markdown link")
    func linkifyBareURLsWrapsHttps() {
        let input = "see https://example.com for details"
        let output = PathLinkifier.linkifyBareURLs(input)
        #expect(output == "see [https://example.com](https://example.com) for details")
    }

    @Test("URL already inside markdown link syntax is not double-wrapped")
    func linkifyBareURLsDoesNotDoubleWrap() {
        let input = "see [example](https://example.com) for details"
        let output = PathLinkifier.linkifyBareURLs(input)
        #expect(output == input)
    }

    @Test("URL match stops at a backtick so injected link syntax cannot pair with it")
    func linkifyBareURLsStopsAtBacktick() {
        // A backtick is never a legal raw URI character (RFC 3986). Swallowing one
        // hands the whole-line markdown parse a backtick inside the injected
        // [url](url) syntax, where it pairs with a later backtick into a bogus
        // code span that destroys the link.
        let input = "see https://x.com/abc` more text"
        let output = PathLinkifier.linkifyBareURLs(input)
        #expect(output == "see [https://x.com/abc](https://x.com/abc)` more text")
    }

    // MARK: - linkifyEmails

    @Test("bare email is wrapped as mailto link")
    func linkifyEmailsWrapsBareEmail() {
        let input = "contact foo@bar.com for help"
        let output = PathLinkifier.linkifyEmails(input)
        #expect(output == "contact [foo@bar.com](mailto:foo@bar.com) for help")
    }

    // MARK: - linkify (composed pipeline)

    @Test("composed linkify wraps path, URL, and email together")
    func linkifyComposesAllPasses() throws {
        let file = try makeTempFile()
        defer { cleanup(file) }
        let input = "path \(file.path) url https://example.com email foo@bar.com"
        let output = PathLinkifier.linkify(input)
        let urlString = URL(fileURLWithPath: file.path).absoluteString
        #expect(output.contains("[\(file.path)](\(urlString))"))
        #expect(output.contains("[https://example.com](https://example.com)"))
        #expect(output.contains("[foo@bar.com](mailto:foo@bar.com)"))
    }

    // MARK: - Single-pass engine (injection protection)

    @Test("URL containing an email is wrapped once — no mailto link nested inside")
    func linkifyURLContainingEmailWrapsOnce() {
        // The old sequential passes rescanned their own output, so the email pass
        // nested a mailto link inside the URL link's text AND destination.
        #expect(PathLinkifier.linkify("visit https://x.com/?email=a@b.com now")
                == "visit [https://x.com/?email=a@b.com](https://x.com/?email=a@b.com) now")
    }

    @Test("no candidate is injected inside an authored markdown link")
    func linkifyProtectsAuthoredLinks() {
        // CommonMark links don't nest: injecting inside either half voids the
        // author's link and renders every bracket literally.
        #expect(PathLinkifier.linkify("[see /usr/bin](https://x.com)")
                == "[see /usr/bin](https://x.com)")
        #expect(PathLinkifier.linkify("[mail a@b.com](https://x.com)")
                == "[mail a@b.com](https://x.com)")
    }

    @Test("protection is span-scoped: text outside an authored link still linkifies")
    func linkifyOutsideAuthoredLinkStillWorks() {
        #expect(PathLinkifier.linkify("[mail a@b.com](https://x.com) or foo@bar.com")
                == "[mail a@b.com](https://x.com) or [foo@bar.com](mailto:foo@bar.com)")
    }

    @Test("a candidate dropped for overlapping an authored link claims its span")
    func linkifyDroppedCandidateDoesNotResurrectContainedTokens() {
        // The URL match extends into the authored link, so it is dropped — and the
        // email inside the URL text must stay dead rather than wrap mid-token.
        let input = "https://x.com/a@b.com[plain](x) end"
        #expect(PathLinkifier.linkify(input) == input)
    }

    // MARK: - markdownLinkSpans

    @Test("authored link spans are found; escaped and unclosed shapes are not")
    func markdownLinkSpanDetection() {
        let text = "a [x](y) b"
        let spans = PathLinkifier.markdownLinkSpans(in: text)
        #expect(spans.map { String(text[$0]) } == ["[x](y)"])

        #expect(PathLinkifier.markdownLinkSpans(in: #"\[x](y)"#).isEmpty)
        #expect(PathLinkifier.markdownLinkSpans(in: "[x](y").isEmpty)
        #expect(PathLinkifier.markdownLinkSpans(in: "[x] (y)").isEmpty)

        let nested = "[a [b] c](https://x.com/a(b)c) end"
        let nestedSpans = PathLinkifier.markdownLinkSpans(in: nested)
        #expect(nestedSpans.map { String(nested[$0]) } == ["[a [b] c](https://x.com/a(b)c)"])
    }
}
