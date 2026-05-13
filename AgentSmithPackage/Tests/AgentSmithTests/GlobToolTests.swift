import Testing
import Foundation
@testable import AgentSmithKit

/// Functional tests for `GlobTool`. The pure regex-translation logic is exercised directly via
/// `GlobTool.globToRegex`; the `execute(...)` paths run against a per-test temp directory with
/// `useSpotlight: false` so the Spotlight branch (which doesn't cover `/tmp`) is deterministically
/// skipped and the structural walk is what's under test.
@Suite("GlobTool")
struct GlobToolTests {

    // MARK: - JSON parsing helper

    /// Decodes the tool's JSON-as-string output. Returns `nil` if the output isn't JSON, so the
    /// caller can fail the test loudly rather than silently passing on a string-match coincidence.
    private static func decode(_ result: ToolExecutionResult) -> [String: Any]? {
        guard let data = result.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    private static func matches(_ result: ToolExecutionResult) -> [String]? {
        Self.decode(result)?["matches"] as? [String]
    }

    private static func stopReason(_ result: ToolExecutionResult) -> String? {
        Self.decode(result)?["stop_reason"] as? String
    }

    private static func message(_ result: ToolExecutionResult) -> String? {
        Self.decode(result)?["message"] as? String
    }

    // MARK: - globToRegex (pure)

    @Test("`**` followed by `/` becomes optional path-prefix")
    func doubleStarSlashTranslatesToOptionalPrefix() {
        #expect(GlobTool.globToRegex("**/Foo.swift") == "(.*/)?Foo\\.swift")
    }

    @Test("single `*` matches within a path segment")
    func singleStarTranslatesToNonSlashRun() {
        #expect(GlobTool.globToRegex("*.swift") == "[^/]*\\.swift")
    }

    @Test("`?` matches a single non-slash character")
    func questionMarkTranslatesToNonSlashSingle() {
        #expect(GlobTool.globToRegex("file?.swift") == "file[^/]\\.swift")
    }

    @Test("brace alternation expands to a regex group")
    func braceExpansion() {
        #expect(GlobTool.globToRegex("*.{ts,tsx}") == "[^/]*\\.(ts|tsx)")
    }

    @Test("regex-special characters are escaped")
    func specialCharsEscaped() {
        #expect(GlobTool.globToRegex("a.b+c") == "a\\.b\\+c")
        #expect(GlobTool.globToRegex("[x]") == "\\[x\\]")
    }

    // MARK: - execute()

    @Test("matches files at any depth")
    func matchesAtAnyDepth() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        _ = try dir.write("a", to: "InspectorView.swift")
        _ = try dir.write("b", to: "sub/InspectorView.swift")
        _ = try dir.write("c", to: "deep/sub/InspectorView.swift")
        _ = try dir.write("noise", to: "deep/Other.swift")

        let result = try await GlobTool(useSpotlight: false).execute(
            arguments: [
                "pattern": .string("**/InspectorView.swift"),
                "path": .string(dir.path)
            ],
            context: TestToolContext.make()
        )

        #expect(result.succeeded)
        let matches = Self.matches(result)
        #expect(matches?.count == 3)
        #expect(matches?.allSatisfy { $0.hasSuffix("InspectorView.swift") } == true)
        #expect(matches?.contains(where: { $0.contains("Other.swift") }) == false)
    }

    @Test("no matches is a successful empty result with stop_reason complete")
    func noMatchesReturnsSuccess() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        _ = try dir.write("x", to: "a.txt")

        let result = try await GlobTool(useSpotlight: false).execute(
            arguments: [
                "pattern": .string("**/*.swift"),
                "path": .string(dir.path)
            ],
            context: TestToolContext.make()
        )

        #expect(result.succeeded)
        #expect(Self.matches(result)?.isEmpty == true)
        #expect(Self.stopReason(result) == "complete")
    }

    @Test("hidden directories are skipped")
    func hiddenDirsSkipped() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        _ = try dir.write("visible", to: "Foo.swift")
        _ = try dir.write("hidden", to: ".cache/Foo.swift")

        let result = try await GlobTool(useSpotlight: false).execute(
            arguments: [
                "pattern": .string("**/Foo.swift"),
                "path": .string(dir.path)
            ],
            context: TestToolContext.make()
        )

        #expect(result.succeeded)
        let matches = Self.matches(result) ?? []
        #expect(matches.count == 1)
        #expect(matches.first?.contains(".cache") == false)
    }

    @Test("relative path is rejected")
    func relativePathRejected() async throws {
        let result = try await GlobTool(useSpotlight: false).execute(
            arguments: [
                "pattern": .string("*.swift"),
                "path": .string("relative/dir")
            ],
            context: TestToolContext.make()
        )
        #expect(!result.succeeded)
        #expect(Self.stopReason(result) == "bad_request")
        #expect(Self.message(result)?.contains("absolute") == true)
    }

    @Test("`..` in pattern is rejected as path traversal")
    func dotDotInPatternRejected() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }

        let result = try await GlobTool(useSpotlight: false).execute(
            arguments: [
                "pattern": .string("../**/*.swift"),
                "path": .string(dir.path)
            ],
            context: TestToolContext.make()
        )
        #expect(!result.succeeded)
        #expect(Self.stopReason(result) == "bad_request")
        #expect(Self.message(result)?.contains("path traversal") == true)
    }

    @Test("missing directory returns failure")
    func missingDirectoryFails() async throws {
        let result = try await GlobTool(useSpotlight: false).execute(
            arguments: [
                "pattern": .string("**/*.swift"),
                "path": .string("/tmp/does-not-exist-\(UUID().uuidString)")
            ],
            context: TestToolContext.make()
        )
        #expect(!result.succeeded)
        #expect(Self.stopReason(result) == "bad_request")
        #expect(Self.message(result)?.contains("does not exist") == true)
    }

    @Test("brace alternation matches multiple extensions")
    func braceAlternationMatchesMultiExtensions() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        _ = try dir.write("a", to: "a.ts")
        _ = try dir.write("b", to: "b.tsx")
        _ = try dir.write("c", to: "c.js")

        let result = try await GlobTool(useSpotlight: false).execute(
            arguments: [
                "pattern": .string("**/*.{ts,tsx}"),
                "path": .string(dir.path)
            ],
            context: TestToolContext.make()
        )

        #expect(result.succeeded)
        let matches = Self.matches(result) ?? []
        #expect(matches.count == 2)
        #expect(matches.contains(where: { $0.contains("c.js") }) == false)
    }

    @Test("matches are relative paths, not absolute")
    func matchesAreRelative() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        _ = try dir.write("a", to: "src/App.swift")

        let result = try await GlobTool(useSpotlight: false).execute(
            arguments: [
                "pattern": .string("**/*.swift"),
                "path": .string(dir.path)
            ],
            context: TestToolContext.make()
        )

        #expect(result.succeeded)
        let matches = Self.matches(result) ?? []
        #expect(matches == ["src/App.swift"])
        #expect(Self.decode(result)?["search_root"] as? String != nil)
    }

    @Test("source is filesystem_walk when Spotlight is disabled")
    func sourceIsFilesystemWalk() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        _ = try dir.write("x", to: "Foo.swift")

        let result = try await GlobTool(useSpotlight: false).execute(
            arguments: [
                "pattern": .string("**/Foo.swift"),
                "path": .string(dir.path)
            ],
            context: TestToolContext.make()
        )

        #expect(result.succeeded)
        #expect(Self.decode(result)?["source"] as? String == "filesystem_walk")
    }
}
