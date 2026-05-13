import Testing
import Foundation
@testable import AgentSmithKit

/// Resume-token behavior for `GlobTool`'s walk fallback. `useSpotlight: false` so the walk is what
/// the test exercises; small `limit` triggers `result_limit` so a token is issued.
@Suite("GlobTool walk resume")
struct GlobToolWalkResumeTests {

    private static func decode(_ r: ToolExecutionResult) -> [String: Any]? {
        guard let data = r.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    private static func makeManyFiles(_ dir: TempDir, count: Int) throws {
        for i in 0..<count {
            _ = try dir.write("\(i)", to: "sub\(i % 5)/file_\(String(format: "%04d", i)).bin")
        }
    }

    @Test("paged walk: page 1 + resume → page 2 with no overlap; eventually `complete`, token gone")
    func resumeRoundTrip() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        try Self.makeManyFiles(dir, count: 30)

        let tool = GlobTool(useSpotlight: false)
        // Page 1: limit 10.
        let r1 = try await tool.execute(
            arguments: ["pattern": .string("**/*.bin"), "path": .string(dir.path), "limit": .int(10)],
            context: TestToolContext.make()
        )
        let j1 = Self.decode(r1)
        let page1 = j1?["matches"] as? [String] ?? []
        #expect(page1.count == 10)
        #expect(j1?["stop_reason"] as? String == "result_limit")
        #expect(j1?["more_available"] as? Bool == true)
        let token1 = (j1?["resume_token"] as? String) ?? ""
        #expect(!token1.isEmpty)

        // Page 2: resume with same token.
        let r2 = try await tool.execute(
            arguments: ["resume": .string(token1), "limit": .int(10)],
            context: TestToolContext.make()
        )
        let j2 = Self.decode(r2)
        let page2 = j2?["matches"] as? [String] ?? []
        #expect(page2.count == 10)
        // No overlap between pages.
        #expect(Set(page1).intersection(Set(page2)).isEmpty)
        #expect(j2?["more_available"] as? Bool == true)
        let token2 = (j2?["resume_token"] as? String) ?? ""
        #expect(!token2.isEmpty)

        // Page 3: drain the rest.
        let r3 = try await tool.execute(
            arguments: ["resume": .string(token2), "limit": .int(10)],
            context: TestToolContext.make()
        )
        let j3 = Self.decode(r3)
        let page3 = j3?["matches"] as? [String] ?? []
        #expect(page3.count == 10)
        #expect(Set(page1 + page2).intersection(Set(page3)).isEmpty)
        #expect(j3?["stop_reason"] as? String == "complete")
        #expect(j3?["more_available"] as? Bool == false)
        #expect(j3?["resume_token"] == nil || j3?["resume_token"] is NSNull)

        // Across all three pages we covered all 30 files.
        let all = Set(page1 + page2 + page3)
        #expect(all.count == 30)
    }

    @Test("unknown resume token returns bad_request")
    func unknownTokenIsBadRequest() async throws {
        let r = try await GlobTool(useSpotlight: false).execute(
            arguments: ["resume": .string(UUID().uuidString)],
            context: TestToolContext.make()
        )
        #expect(!r.succeeded)
        #expect(Self.decode(r)?["stop_reason"] as? String == "bad_request")
        #expect((Self.decode(r)?["message"] as? String)?.contains("expired") == true)
    }

    @Test("garbage resume token (not even a UUID) returns bad_request")
    func garbageTokenIsBadRequest() async throws {
        let r = try await GlobTool(useSpotlight: false).execute(
            arguments: ["resume": .string("not-a-uuid")],
            context: TestToolContext.make()
        )
        #expect(!r.succeeded)
        #expect(Self.decode(r)?["stop_reason"] as? String == "bad_request")
    }

    @Test("LRU eviction: oldest token becomes bad_request once capacity is exceeded")
    func lruEviction() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        try Self.makeManyFiles(dir, count: 20)

        // Capacity 2 — opening a 3rd walk evicts the first.
        let tool = GlobTool(useSpotlight: false, walkStoreCapacity: 2)

        var tokens: [String] = []
        for _ in 0..<3 {
            let r = try await tool.execute(
                arguments: ["pattern": .string("**/*.bin"), "path": .string(dir.path), "limit": .int(1)],
                context: TestToolContext.make()
            )
            let t = (Self.decode(r)?["resume_token"] as? String) ?? ""
            #expect(!t.isEmpty)
            tokens.append(t)
        }

        // The very first token is evicted (cap=2, third insert pushed it out).
        let r = try await tool.execute(
            arguments: ["resume": .string(tokens[0])],
            context: TestToolContext.make()
        )
        #expect(!r.succeeded)
        #expect(Self.decode(r)?["stop_reason"] as? String == "bad_request")

        // The most recent token is still valid.
        let r2 = try await tool.execute(
            arguments: ["resume": .string(tokens[2]), "limit": .int(100)],
            context: TestToolContext.make()
        )
        #expect(r2.succeeded)
        #expect(Self.decode(r2)?["stop_reason"] as? String == "complete")
    }
}
