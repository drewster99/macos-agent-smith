import Testing
import Foundation
@testable import AgentSmithKit

/// Pathological-root rejection: `path` resolving exactly to a blocklisted root must come back as
/// `stop_reason: too_broad` rather than triggering a multi-second filesystem crawl.
@Suite("GlobTool broad-root rejection")
struct GlobToolBroadRootTests {

    private static func stopReason(_ r: ToolExecutionResult) -> String? {
        guard let data = r.output.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return j["stop_reason"] as? String
    }

    @Test("system roots are rejected with stop_reason=too_broad",
          arguments: ["/", "/System", "/usr", "/bin", "/sbin", "/private", "/dev", "/Library", "/Volumes", "/Users", "/opt"])
    func systemRootsRejected(path: String) async throws {
        let r = try await GlobTool(useSpotlight: false).execute(
            arguments: ["pattern": .string("**/*.swift"), "path": .string(path)],
            context: TestToolContext.make()
        )
        #expect(!r.succeeded)
        #expect(Self.stopReason(r) == "too_broad")
    }

    @Test("bare $HOME is rejected — searching the entire home dir is too broad")
    func homeIsRejected() async throws {
        let r = try await GlobTool(useSpotlight: false).execute(
            arguments: ["pattern": .string("**/*.swift"), "path": .string(NSHomeDirectory())],
            context: TestToolContext.make()
        )
        #expect(!r.succeeded)
        #expect(Self.stopReason(r) == "too_broad")
    }

    @Test("`~` (tilde alone) is rejected — same as $HOME")
    func tildeAloneRejected() async throws {
        let r = try await GlobTool(useSpotlight: false).execute(
            arguments: ["pattern": .string("**/*.swift"), "path": .string("~")],
            context: TestToolContext.make()
        )
        #expect(!r.succeeded)
        #expect(Self.stopReason(r) == "too_broad")
    }

    @Test("a normal project subdir is NOT rejected")
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

    @Test("`~/<subpath>` expands and IS allowed (as long as the subpath exists)")
    func tildePrefixWithSubpathAllowed() async throws {
        // Pick a subdir of $HOME that almost certainly exists on a dev machine. We don't care
        // about results — just that the call isn't rejected as too_broad. Use a tiny scan cap so
        // the test doesn't burn 30s walking ~/Library before its deadline fires; any non-too_broad
        // stop reason proves the path got past root-blocking.
        let candidate = "~/Library"
        let r = try await GlobTool(useSpotlight: false, maxEntriesScanned: 5).execute(
            arguments: ["pattern": .string("**/never_matches_anything_xyzzy.zzz"), "path": .string(candidate)],
            context: TestToolContext.make()
        )
        // It might succeed (no matches), bad_request (dir missing), or hit scan_limit — but it
        // must NOT be too_broad.
        #expect(Self.stopReason(r) != "too_broad")
    }
}
