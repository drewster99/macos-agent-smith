import Testing
import Foundation
@testable import AgentSmithKit

/// Facts about the machine the suite's traits read. Outside the suite: a suite's trait can't
/// refer to the suite's own members.
private enum GitIgnoreTestEnvironment {
    static let gitIsInstalled: Bool = {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        probe.arguments = ["-p"]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        do { try probe.run() } catch { return false }
        probe.waitUntilExit()
        return probe.terminationStatus == 0
    }()

    static let tempVolumeIsCaseInsensitive: Bool = {
        let dir = TempDir()
        defer { dir.cleanup() }
        do {
            return try dir.url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames == false
        } catch {
            return false
        }
    }()
}

/// `glob`'s `respect_gitignore` (#29): what git ignores is left out, tracked files never are, and a
/// root git can't speak for says so instead of silently returning everything. Walk path only
/// (`useSpotlight: false`) — Spotlight doesn't index the temp directory.
///
/// Skipped where git isn't installed: running `/usr/bin/git` without the Command Line Tools opens
/// an install dialog rather than failing.
@Suite("GlobTool respect_gitignore", .enabled(if: GitIgnoreTestEnvironment.gitIsInstalled))
struct GlobToolGitIgnoreTests {

    /// Keeps the machine's git setup out of every git this suite runs — its own and the tool's,
    /// which inherit this process's environment: no global or system config (a developer's global
    /// excludes file would change what is ignored) and no `GIT_*` overrides (a `GIT_DIR` set by a
    /// hook would point git at another repository). Process-wide, set once.
    private static let isolatedGit: Void = {
        for name in ProcessInfo.processInfo.environment.keys where name.hasPrefix("GIT_") {
            unsetenv(name)
        }
        setenv("GIT_CONFIG_GLOBAL", "/dev/null", 1)
        setenv("GIT_CONFIG_NOSYSTEM", "1", 1)
    }()

    struct GitCommandFailed: Error, CustomStringConvertible {
        let arguments: [String]
        let status: Int32
        var description: String { "git \(arguments.joined(separator: " ")) exited \(status)" }
    }

    private static func decode(_ result: ToolExecutionResult) -> [String: Any]? {
        guard let data = result.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    /// Runs git in `directory`, throwing on a non-zero exit so a broken fixture fails where it broke.
    private static func git(_ arguments: [String], in directory: String) throws {
        Self.isolatedGit
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw GitCommandFailed(arguments: arguments, status: process.terminationStatus) }
    }

    /// A repository with an ignored generated directory, an ignored log, and a force-tracked ignored log.
    private static func makeRepository() throws -> TempDir {
        let dir = TempDir()
        try git(["init", "-q"], in: dir.path)
        try dir.write("generated/\n*.log\n", to: ".gitignore")
        try dir.write("a", to: "src/App.swift")
        try dir.write("b", to: "src/debug.log")
        try dir.write("c", to: "src/kept.log")
        try dir.write("d", to: "generated/gen/Generated.swift")
        try dir.write("e", to: "generated/out.log")
        try git(["add", "-f", "src/kept.log"], in: dir.path)
        return dir
    }

    private static func run(_ arguments: [String: AnyCodable]) async throws -> [String: Any] {
        Self.isolatedGit
        let result = try await GlobTool(useSpotlight: false).execute(arguments: arguments, context: TestToolContext.make())
        #expect(result.succeeded)
        return try #require(decode(result))
    }

    // MARK: - Snapshot parsing

    private static func parse(_ output: String, prefix: String = "", caseInsensitive: Bool = false) -> GitIgnoreSnapshot {
        GitIgnoreSnapshot.parse(lsFilesOutput: output, rootPrefix: prefix, caseInsensitive: caseInsensitive)
    }

    @Test("parse splits files and directories at the top level")
    func parseShapes() {
        let snapshot = Self.parse("build/\0src/c.log\0")
        #expect(snapshot.ignoredDirectories == ["build"])
        #expect(snapshot.ignoredFiles == ["src/c.log"])
        #expect(!snapshot.rootIgnored)
        #expect(Self.parse("") == GitIgnoreSnapshot(ignoredFiles: [], ignoredDirectories: [], rootIgnored: false, caseInsensitive: false))
    }

    @Test("parse below the top level: entries become root-relative, an enclosing ignored directory ignores the root")
    func parseWithPrefix() {
        let below = Self.parse("src/c.log\0src/gen/\0", prefix: "src/")
        #expect(below.ignoredFiles == ["c.log"])
        #expect(below.ignoredDirectories == ["gen"])
        #expect(!below.rootIgnored)
        #expect(Self.parse("generated/\0", prefix: "generated/sub/").rootIgnored)
        #expect(Self.parse("generated/\0", prefix: "generated/").rootIgnored)
        // A sibling whose name merely starts the same is not an ancestor.
        #expect(!Self.parse("gen/\0", prefix: "generated/").rootIgnored)
        #expect(!Self.parse("generated\0", prefix: "generated/sub/").rootIgnored)
    }

    @Test("a case-insensitive snapshot matches any spelling; a case-sensitive one only the exact one")
    func caseSensitivity() {
        let folded = Self.parse("Generated/\0src/Debug.log\0", caseInsensitive: true)
        #expect(folded.isIgnored("generated/x.swift"))
        #expect(folded.isIgnored("GENERATED/x.swift"))
        #expect(folded.isIgnored("SRC/DEBUG.LOG"))
        let exact = Self.parse("Generated/\0src/Debug.log\0", caseInsensitive: false)
        #expect(exact.isIgnored("Generated/x.swift"))
        #expect(!exact.isIgnored("generated/x.swift"))
        #expect(!exact.isIgnored("src/debug.log"))
    }

    @Test("the Spotlight prefilter drops ignored paths under the root and leaves other spellings for validation")
    func spotlightPrefilter() {
        let snapshot = Self.parse("generated/\0")
        #expect(GlobTool.isGitIgnoredSpotlightPath("/r/generated/a.js", resolvedBase: "/r", snapshot: snapshot))
        #expect(!GlobTool.isGitIgnoredSpotlightPath("/r/src/a.js", resolvedBase: "/r", snapshot: snapshot))
        #expect(!GlobTool.isGitIgnoredSpotlightPath("/elsewhere/generated/a.js", resolvedBase: "/r", snapshot: snapshot))
        #expect(!GlobTool.isGitIgnoredSpotlightPath("/rx/generated/a.js", resolvedBase: "/r", snapshot: snapshot))
        #expect(GlobTool.isGitIgnoredSpotlightPath("/private/var/r/generated/a.js", resolvedBase: "/var/r", snapshot: snapshot))
        #expect(!GlobTool.isGitIgnoredSpotlightPath("/private/var/r/src/a.js", resolvedBase: "/var/r", snapshot: snapshot))
    }

    @Test("isIgnored covers the entry itself and everything under an ignored directory, nothing else")
    func isIgnoredAncestry() {
        let snapshot = Self.parse("build/\0a/b/\0src/c.log\0")
        #expect(snapshot.isIgnored("build"))
        #expect(snapshot.isIgnored("build/x/y.swift"))
        #expect(snapshot.isIgnored("a/b/c"))
        #expect(snapshot.isIgnored("src/c.log"))
        #expect(!snapshot.isIgnored("a"))
        #expect(!snapshot.isIgnored("buildings/x.swift"))
        #expect(!snapshot.isIgnored("src/c.log.bak"))
        #expect(!snapshot.isIgnored("src"))
        let ignoredRoot = Self.parse("generated/\0", prefix: "generated/sub/")
        #expect(ignoredRoot.isIgnored("anything/at/all"))
        #expect(ignoredRoot.isIgnored(""))
        #expect(!snapshot.isIgnored(""))
    }

    // MARK: - execute()

    @Test("respect_gitignore leaves out ignored files and directories but keeps tracked ones")
    func filtersIgnored() async throws {
        let dir = try Self.makeRepository()
        defer { dir.cleanup() }
        let json = try await Self.run([
            "pattern": .string("**/*"), "path": .string(dir.path), "respect_gitignore": .bool(true)
        ])
        let matches = Set(json["matches"] as? [String] ?? [])
        #expect(matches == ["src/App.swift", "src/kept.log"])
        #expect(json["total_matched"] as? Int == 2)
        #expect(json["message"] == nil || json["message"] is NSNull)
    }

    @Test("without respect_gitignore (or false) nothing is left out")
    func defaultUnfiltered() async throws {
        let dir = try Self.makeRepository()
        defer { dir.cleanup() }
        let expected: Set<String> = ["src/App.swift", "src/debug.log", "src/kept.log", "generated/gen/Generated.swift", "generated/out.log"]
        let absent = try await Self.run(["pattern": .string("**/*"), "path": .string(dir.path)])
        #expect(Set(absent["matches"] as? [String] ?? []) == expected)
        let off = try await Self.run(["pattern": .string("**/*"), "path": .string(dir.path), "respect_gitignore": .bool(false)])
        #expect(Set(off["matches"] as? [String] ?? []) == expected)
    }

    @Test("literal and wildcard segment patterns are filtered too")
    func filtersEverySegmentShape() async throws {
        let dir = try Self.makeRepository()
        defer { dir.cleanup() }
        let literal = try await Self.run([
            "pattern": .string("src/debug.log"), "path": .string(dir.path), "respect_gitignore": .bool(true)
        ])
        #expect((literal["matches"] as? [String])?.isEmpty == true)
        let wildcard = try await Self.run([
            "pattern": .string("src/*.log"), "path": .string(dir.path), "respect_gitignore": .bool(true)
        ])
        #expect(wildcard["matches"] as? [String] == ["src/kept.log"])
        let deep = try await Self.run([
            "pattern": .string("**/*.swift"), "path": .string(dir.path), "respect_gitignore": .bool(true)
        ])
        #expect(deep["matches"] as? [String] == ["src/App.swift"])
    }

    @Test("a root below the repository root reports paths relative to itself, filtered")
    func subdirectoryRoot() async throws {
        let dir = try Self.makeRepository()
        defer { dir.cleanup() }
        let json = try await Self.run([
            "pattern": .string("*"), "path": .string(dir.path + "/src"), "respect_gitignore": .bool(true)
        ])
        #expect(Set(json["matches"] as? [String] ?? []) == ["App.swift", "kept.log"])
    }

    @Test("a root inside an ignored directory matches nothing, and says why")
    func ignoredRoot() async throws {
        let dir = try Self.makeRepository()
        defer { dir.cleanup() }
        let json = try await Self.run([
            "pattern": .string("**/*"), "path": .string(dir.path + "/generated"), "respect_gitignore": .bool(true)
        ])
        #expect((json["matches"] as? [String])?.isEmpty == true)
        #expect((json["message"] as? String)?.contains("ignored by git") == true)
    }

    @Test("a root two levels inside an ignored directory matches nothing (git can't list from there)")
    func deeplyIgnoredRoot() async throws {
        let dir = try Self.makeRepository()
        defer { dir.cleanup() }
        let json = try await Self.run([
            "pattern": .string("**/*"), "path": .string(dir.path + "/generated/gen"), "respect_gitignore": .bool(true)
        ])
        #expect((json["matches"] as? [String])?.isEmpty == true)
        #expect((json["message"] as? String)?.contains("ignored by git") == true)
    }

    @Test("a tracked file inside an ignored directory is still found, from any root")
    func trackedInsideIgnored() async throws {
        let dir = try Self.makeRepository()
        defer { dir.cleanup() }
        try dir.write("t", to: "generated/sub/Tracked.swift")
        try dir.write("u", to: "generated/sub/deep/Untracked.swift")
        try Self.git(["add", "-f", "generated/sub/Tracked.swift"], in: dir.path)
        for root in [dir.path, dir.path + "/generated", dir.path + "/generated/sub"] {
            let json = try await Self.run([
                "pattern": .string("**/*.swift"), "path": .string(root), "respect_gitignore": .bool(true)
            ])
            let matches = json["matches"] as? [String] ?? []
            #expect(matches.contains { $0.hasSuffix("/Tracked.swift") || $0 == "Tracked.swift" }, "root \(root): \(matches)")
            #expect(!matches.contains { $0.hasSuffix("Untracked.swift") }, "root \(root): \(matches)")
            #expect(!matches.contains { $0.hasSuffix("Generated.swift") }, "root \(root): \(matches)")
        }
    }


    @Test("a literal segment spelled in another case is still filtered on a case-insensitive volume",
          .enabled(if: GitIgnoreTestEnvironment.tempVolumeIsCaseInsensitive))
    func literalSegmentCase() async throws {
        let dir = try Self.makeRepository()
        defer { dir.cleanup() }
        let json = try await Self.run([
            "pattern": .string("GENERATED/**/*.swift"), "path": .string(dir.path), "respect_gitignore": .bool(true)
        ])
        #expect((json["matches"] as? [String])?.isEmpty == true)
    }

    @Test("outside a git work tree the search is unfiltered and says why")
    func notARepository() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        try dir.write("x", to: "generated/a.swift")
        let json = try await Self.run([
            "pattern": .string("**/*.swift"), "path": .string(dir.path), "respect_gitignore": .bool(true)
        ])
        #expect(json["matches"] as? [String] == ["generated/a.swift"])
        let message = try #require(json["message"] as? String)
        #expect(message.hasPrefix("respect_gitignore was not applied:"))
        #expect(message.contains("isn't inside a git work tree"))
    }

    @Test("a malformed respect_gitignore is refused, not guessed")
    func malformedRefused() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let result = try await GlobTool(useSpotlight: false).execute(
            arguments: ["pattern": .string("*"), "path": .string(dir.path), "respect_gitignore": .string("maybe")],
            context: TestToolContext.make()
        )
        #expect(!result.succeeded)
        #expect(result.output.contains("respect_gitignore"))
    }

    @Test("a resumed walk keeps filtering")
    func resumeKeepsFiltering() async throws {
        let dir = try Self.makeRepository()
        defer { dir.cleanup() }
        for index in 0..<12 {
            try dir.write("\(index)", to: "src/more/file_\(index).swift")
            try dir.write("\(index)", to: "generated/more/file_\(index).swift")
        }
        let tool = GlobTool(useSpotlight: false)
        var seen: [String] = []
        var arguments: [String: AnyCodable] = [
            "pattern": .string("**/*.swift"), "path": .string(dir.path), "respect_gitignore": .bool(true), "limit": .int(5)
        ]
        for _ in 0..<10 {
            let result = try await tool.execute(arguments: arguments, context: TestToolContext.make())
            let json = try #require(Self.decode(result))
            seen += json["matches"] as? [String] ?? []
            guard let token = json["resume_token"] as? String else { break }
            arguments = ["resume": .string(token), "limit": .int(5)]
        }
        #expect(seen.count == 13)
        #expect(Set(seen).count == 13)
        #expect(!seen.contains { $0.hasPrefix("generated/") })
    }
}
