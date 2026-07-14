import Testing
import Foundation
@testable import AgentSmithKit

/// Broad roots are ALLOWED. glob is Spotlight-first (`mdfind`), which makes a home-directory or
/// even machine-wide scope cheap, and both backends are independently bounded (the Spotlight
/// result ceiling, and the walk's entry cap + timeout + resume token). So a broad `path` must NOT
/// be refused as `too_broad` — the query does the narrowing. These tests force the walk fallback
/// (`useSpotlight: false`) with a tiny scan cap so they return immediately with `scan_limit`
/// rather than crawling, and assert the refusal is gone.
@Suite("GlobTool broad roots are allowed and bounded")
struct GlobToolBroadRootTests {

    private static func stopReason(_ r: ToolExecutionResult) -> String? {
        guard let data = r.output.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return j["stop_reason"] as? String
    }

    @Test("system roots are NOT refused as too_broad",
          arguments: ["/", "/System", "/usr", "/bin", "/sbin", "/private", "/dev", "/Library", "/Volumes", "/Users", "/opt"])
    func systemRootsAllowed(path: String) async throws {
        let r = try await GlobTool(useSpotlight: false, maxEntriesScanned: 5).execute(
            arguments: ["pattern": .string("**/never_matches_anything_xyzzy.zzz"), "path": .string(path)],
            context: TestToolContext.make()
        )
        #expect(Self.stopReason(r) != "too_broad")
    }

    @Test("bare $HOME is NOT refused — the index makes a home-wide scope cheap")
    func homeAllowed() async throws {
        let r = try await GlobTool(useSpotlight: false, maxEntriesScanned: 5).execute(
            arguments: ["pattern": .string("**/never_matches_anything_xyzzy.zzz"), "path": .string(NSHomeDirectory())],
            context: TestToolContext.make()
        )
        #expect(Self.stopReason(r) != "too_broad")
    }

    @Test("`~` (tilde alone) is NOT refused")
    func tildeAloneAllowed() async throws {
        let r = try await GlobTool(useSpotlight: false, maxEntriesScanned: 5).execute(
            arguments: ["pattern": .string("**/never_matches_anything_xyzzy.zzz"), "path": .string("~")],
            context: TestToolContext.make()
        )
        #expect(Self.stopReason(r) != "too_broad")
    }

    @Test("a normal project subdir works")
    func normalProjectDirAllowed() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        _ = try dir.write("a", to: "src/App.swift")

        let r = try await GlobTool(useSpotlight: false).execute(
            arguments: ["pattern": .string("**/*.swift"), "path": .string(dir.path)],
            context: TestToolContext.make()
        )
        #expect(r.succeeded)
        #expect(Self.stopReason(r) == "complete")
    }
}
