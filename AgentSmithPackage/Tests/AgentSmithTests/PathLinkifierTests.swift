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

    @Test("absolute path that does NOT exist returns nil")
    func standaloneAbsolutePathMissing() {
        let bogus = "/tmp/agent-smith-this-path-does-not-exist-\(UUID().uuidString)/x.md"
        #expect(PathLinkifier.standaloneLink(for: bogus) == nil)
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
}
