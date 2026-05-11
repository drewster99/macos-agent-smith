import Testing
import Foundation
@testable import AgentSmithKit

/// Tests for `DirectoryTreeTool`. Plain-text output (box-drawing tree); assertions are over the
/// rendered structure + the per-leaf annotations.
@Suite("DirectoryTreeTool")
struct DirectoryTreeToolTests {

    @Test("renders box-drawing tree with `/`-suffixed dir names")
    func basicShape() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        _ = try dir.write("a", to: "Sources/App.swift")
        _ = try dir.write("b", to: "Tests/AppTests.swift")
        _ = try dir.write("c", to: "Sources/Models/User.swift")

        let r = try await DirectoryTreeTool().execute(
            arguments: ["path": .string(dir.path)],
            context: TestToolContext.make()
        )
        #expect(r.succeeded)
        let out = r.output
        // Root line, with trailing slash.
        #expect(out.contains(dir.path + "/"))
        // At least one box-drawing connector present.
        #expect(out.contains("├── ") || out.contains("└── "))
        // Subdirs surfaced.
        #expect(out.contains("Sources/"))
        #expect(out.contains("Tests/"))
        // Trailer guides toward sibling tools.
        #expect(out.contains("directory_listing"))
    }

    @Test("max_depth bounds the recursion and annotates the frontier")
    func depthLimitAnnotation() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        _ = try dir.write("a", to: "Sources/Models/Deep/Inner.swift")
        _ = try dir.write("b", to: "Sources/Models/Deep/Inner2.swift")

        let r = try await DirectoryTreeTool().execute(
            arguments: ["path": .string(dir.path), "max_depth": .int(1)],
            context: TestToolContext.make()
        )
        #expect(r.succeeded)
        // At depth 1 Sources/ is shown but its children are NOT — should carry a "raise max_depth"
        // annotation since it has subdirs.
        #expect(r.output.contains("Sources/"))
        #expect(r.output.contains("raise max_depth"))
        // Inner.swift's parent should NOT have been recursed into.
        #expect(!r.output.contains("Inner.swift"))
    }

    @Test("prune-list dirs render with `(pruned ...)` and are not descended")
    func pruneListAnnotation() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        _ = try dir.write("a", to: "Sources/App.swift")
        _ = try dir.write("noise", to: "node_modules/some-pkg/Index.js")
        _ = try dir.write("noise2", to: "node_modules/deep/Other.js")

        let r = try await DirectoryTreeTool().execute(
            arguments: ["path": .string(dir.path), "max_depth": .int(3)],
            context: TestToolContext.make()
        )
        #expect(r.succeeded)
        #expect(r.output.contains("node_modules/"))
        #expect(r.output.contains("(pruned"))
        // Pruned dir's descendants must not appear.
        #expect(!r.output.contains("some-pkg"))
    }

    @Test("system roots are rejected")
    func systemRootRejected() async throws {
        let r = try await DirectoryTreeTool().execute(
            arguments: ["path": .string("/")],
            context: TestToolContext.make()
        )
        #expect(!r.succeeded)
        #expect(r.output.contains("too broad"))
    }

    @Test("$HOME itself is rejected")
    func homeRejected() async throws {
        let r = try await DirectoryTreeTool().execute(
            arguments: ["path": .string(NSHomeDirectory())],
            context: TestToolContext.make()
        )
        #expect(!r.succeeded)
        #expect(r.output.contains("too broad"))
    }

    @Test("missing directory is a clear failure")
    func missingDirFails() async throws {
        let r = try await DirectoryTreeTool().execute(
            arguments: ["path": .string("/tmp/does-not-exist-\(UUID().uuidString)")],
            context: TestToolContext.make()
        )
        #expect(!r.succeeded)
        #expect(r.output.contains("does not exist"))
    }

    @Test("true-leaf dir is annotated with its file count")
    func trueLeafCount() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        _ = try dir.write("a", to: "Models/A.swift")
        _ = try dir.write("b", to: "Models/B.swift")
        _ = try dir.write("c", to: "Models/C.swift")

        let r = try await DirectoryTreeTool().execute(
            arguments: ["path": .string(dir.path), "max_depth": .int(3)],
            context: TestToolContext.make()
        )
        #expect(r.succeeded)
        // Models/ is a leaf (no subdirs) — should show "(3 files)".
        #expect(r.output.contains("Models/"))
        #expect(r.output.contains("(3 files)"))
    }
}
