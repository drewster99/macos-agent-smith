import Testing
import Foundation
@testable import AgentSmithKit

/// Budget / truncation behavior for `GlobTool`'s structural walk fallback. Spotlight is disabled
/// (`useSpotlight: false`) so the walk is what's under test; `maxEntriesScanned` is set tiny so the
/// scan-cap reliably fires before the tree is exhausted.
@Suite("GlobTool budgets")
struct GlobToolBudgetTests {

    private static func decode(_ result: ToolExecutionResult) -> [String: Any]? {
        guard let data = result.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    /// Builds a temp tree wider than the supplied iteration cap so the cap fires before the tree
    /// is exhausted.
    private static func makeWideTree(fileCount: Int) -> TempDir {
        let dir = TempDir()
        for i in 0..<fileCount {
            _ = try? dir.write("\(i)", to: "sub\(i % 7)/file_\(i).bin")
        }
        return dir
    }

    @Test("scan cap stops the walk with stop_reason=scan_limit and returns a resume_token")
    func scanCapTruncates() async throws {
        let dir = Self.makeWideTree(fileCount: 50)
        defer { dir.cleanup() }

        let tool = GlobTool(useSpotlight: false, maxEntriesScanned: 5)
        let result = try await tool.execute(
            arguments: [
                "pattern": .string("**/*.bin"),
                "path": .string(dir.path)
            ],
            context: TestToolContext.make()
        )

        #expect(result.succeeded)
        let json = Self.decode(result)
        #expect(json?["stop_reason"] as? String == "scan_limit")
        // Resume token issued so the LLM can continue rather than just bailing.
        #expect(json?["more_available"] as? Bool == true)
        #expect((json?["resume_token"] as? String)?.isEmpty == false)
        // total_matched is null on early stop (we didn't finish counting).
        #expect(json?["total_matched"] is NSNull || json?["total_matched"] == nil)
    }

    @Test("result limit stops with stop_reason=result_limit and a resume_token")
    func resultLimitTruncates() async throws {
        // 600 matching files; ask for limit=10. The first queue-pop is a wildcard step that lists
        // the base dir's subdirs (sub0..sub6) — each is recursed and produces .bin matches; we
        // collect up to 10 then break.
        let dir = Self.makeWideTree(fileCount: 600)
        defer { dir.cleanup() }

        let tool = GlobTool(useSpotlight: false)
        let result = try await tool.execute(
            arguments: [
                "pattern": .string("**/*.bin"),
                "path": .string(dir.path),
                "limit": .int(10)
            ],
            context: TestToolContext.make()
        )

        #expect(result.succeeded)
        let json = Self.decode(result)
        #expect(json?["stop_reason"] as? String == "result_limit")
        let matches = json?["matches"] as? [String]
        #expect(matches?.count == 10)
        #expect(json?["more_available"] as? Bool == true)
        #expect((json?["resume_token"] as? String)?.isEmpty == false)
    }

    @Test("default budgets do not regress small searches — stop_reason complete, no token")
    func defaultBudgetsCompleteSmallSearch() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        _ = try dir.write("a", to: "Foo.swift")
        _ = try dir.write("b", to: "sub/Foo.swift")

        let result = try await GlobTool(useSpotlight: false).execute(
            arguments: [
                "pattern": .string("**/Foo.swift"),
                "path": .string(dir.path)
            ],
            context: TestToolContext.make()
        )

        #expect(result.succeeded)
        let json = Self.decode(result)
        #expect(json?["stop_reason"] as? String == "complete")
        #expect(json?["more_available"] as? Bool == false)
        #expect(json?["resume_token"] == nil || json?["resume_token"] is NSNull)
        let matches = json?["matches"] as? [String]
        #expect(matches?.count == 2)
        // total_matched is exact when the walk drains.
        #expect(json?["total_matched"] as? Int == 2)
    }
}
