import Testing
import Foundation
@testable import AgentSmithKit

/// Tests of the structural (pattern-directed) walk matcher in `GlobTool`. `useSpotlight: false`
/// throughout so the walk path is what's exercised. Asserts both *correctness* (the right files
/// match for each pattern shape) and the **"smart" property**: for a pattern with a leading literal
/// like `proj/src/**/*.swift`, the walk does NOT descend irrelevant sibling subtrees.
@Suite("GlobTool walk matcher")
struct GlobToolWalkMatcherTests {

    private static func decode(_ result: ToolExecutionResult) -> [String: Any]? {
        guard let data = result.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }
    private static func matches(_ r: ToolExecutionResult) -> [String] {
        Self.decode(r)?["matches"] as? [String] ?? []
    }

    @Test("literal/literal/wildcard: src/lib/*.swift")
    func literalLiteralWildcard() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        _ = try dir.write("a", to: "src/lib/Foo.swift")
        _ = try dir.write("b", to: "src/lib/Bar.swift")
        _ = try dir.write("noise", to: "src/lib/notes.txt")
        _ = try dir.write("nope", to: "src/other/Baz.swift")

        let r = try await GlobTool(useSpotlight: false).execute(
            arguments: ["pattern": .string("src/lib/*.swift"), "path": .string(dir.path)],
            context: TestToolContext.make()
        )
        let m = Set(Self.matches(r))
        #expect(m == ["src/lib/Foo.swift", "src/lib/Bar.swift"])
    }

    @Test("**/literal/wildcard: **/src/*.swift")
    func doubleStarThenLiteralThenWildcard() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        _ = try dir.write("a", to: "src/App.swift")
        _ = try dir.write("b", to: "x/src/Lib.swift")
        _ = try dir.write("nope", to: "src/sub/Deep.swift")  // src/sub/*.swift won't match **/src/*.swift
        _ = try dir.write("nope2", to: "other/App.swift")

        let r = try await GlobTool(useSpotlight: false).execute(
            arguments: ["pattern": .string("**/src/*.swift"), "path": .string(dir.path)],
            context: TestToolContext.make()
        )
        let m = Set(Self.matches(r))
        #expect(m == ["src/App.swift", "x/src/Lib.swift"])
    }

    @Test("literal-last-segment: **/Package.swift")
    func literalLastSegment() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        _ = try dir.write("p1", to: "Package.swift")
        _ = try dir.write("p2", to: "sub/Package.swift")
        _ = try dir.write("nope", to: "sub/Package.json")
        _ = try dir.write("p3", to: "deep/very/Package.swift")

        let r = try await GlobTool(useSpotlight: false).execute(
            arguments: ["pattern": .string("**/Package.swift"), "path": .string(dir.path)],
            context: TestToolContext.make()
        )
        let m = Set(Self.matches(r))
        #expect(m == ["Package.swift", "sub/Package.swift", "deep/very/Package.swift"])
    }

    @Test("trailing `**`: src/** matches every regular file under src/")
    func trailingDoubleStar() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        _ = try dir.write("a", to: "src/App.swift")
        _ = try dir.write("b", to: "src/sub/Lib.swift")
        _ = try dir.write("c", to: "src/sub/deep/Z.txt")
        _ = try dir.write("nope", to: "other/X.txt")

        let r = try await GlobTool(useSpotlight: false).execute(
            arguments: ["pattern": .string("src/**"), "path": .string(dir.path)],
            context: TestToolContext.make()
        )
        let m = Set(Self.matches(r))
        #expect(m == ["src/App.swift", "src/sub/Lib.swift", "src/sub/deep/Z.txt"])
    }

    @Test("brace alternation in leaf: {a,b}/*.txt")
    func braceLeaf() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        _ = try dir.write("x", to: "a/one.txt")
        _ = try dir.write("y", to: "b/two.txt")
        _ = try dir.write("nope", to: "c/three.txt")

        let r = try await GlobTool(useSpotlight: false).execute(
            arguments: ["pattern": .string("{a,b}/*.txt"), "path": .string(dir.path)],
            context: TestToolContext.make()
        )
        let m = Set(Self.matches(r))
        #expect(m == ["a/one.txt", "b/two.txt"])
    }

    @Test("prune-list: node_modules is not descended")
    func pruneListSkipsNodeModules() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        _ = try dir.write("real", to: "src/App.swift")
        // Inside node_modules — should be pruned out of walks (even though it matches the pattern).
        _ = try dir.write("noise", to: "node_modules/some-pkg/Index.swift")
        _ = try dir.write("noise2", to: "node_modules/deep/Other.swift")

        let r = try await GlobTool(useSpotlight: false).execute(
            arguments: ["pattern": .string("**/*.swift"), "path": .string(dir.path)],
            context: TestToolContext.make()
        )
        let m = Self.matches(r)
        #expect(m.contains("src/App.swift"))
        #expect(m.allSatisfy { !$0.contains("node_modules") })
    }

    /// The "smart" property: a pattern with a leading literal must NOT descend irrelevant sibling
    /// subtrees. Build a tiny `proj/src/` and a *huge* sibling `proj/other/` (50 files deep), then
    /// search `proj/src/**/*.swift` — even with a tiny `maxEntriesScanned`, the walk should finish
    /// because it only touches `proj/src/`, not `proj/other/`.
    @Test("smart property: leading-literal patterns do not descend irrelevant siblings")
    func smartLiteralAvoidsIrrelevantSubtrees() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        // Tiny relevant subtree (3 .swift files).
        _ = try dir.write("a", to: "proj/src/App.swift")
        _ = try dir.write("b", to: "proj/src/lib/Util.swift")
        _ = try dir.write("c", to: "proj/src/lib/Net.swift")
        // Huge irrelevant sibling — 50 files across 10 subdirs.
        for i in 0..<50 {
            _ = try dir.write("x\(i)", to: "proj/other/sub\(i % 10)/file_\(i).txt")
        }

        // Cap entries to a small number that would NEVER cover the irrelevant subtree.
        let tool = GlobTool(useSpotlight: false, maxEntriesScanned: 30)
        let r = try await tool.execute(
            arguments: ["pattern": .string("proj/src/**/*.swift"), "path": .string(dir.path)],
            context: TestToolContext.make()
        )
        let json = Self.decode(r)
        let matches = Set(Self.matches(r))
        // Found all three .swift files...
        #expect(matches == ["proj/src/App.swift", "proj/src/lib/Util.swift", "proj/src/lib/Net.swift"])
        // ...and finished (stop_reason "complete") well within the entry cap — proves the walk
        // didn't descend `proj/other/`. (If it had, we'd hit `scan_limit` instead.)
        #expect(json?["stop_reason"] as? String == "complete")
    }
}
