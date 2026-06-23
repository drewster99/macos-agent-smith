import Testing
import Foundation
@testable import AgentSmithKit

/// Live network test for the **temporary** DuckDuckGo HTML backend — the one part the
/// fixture-based `WebSearchTests` can't cover: the real `URLSession` request + parsing an actual
/// live SERP response. Gated behind `WEB_SEARCH_LIVE=1` because it makes a real outbound request
/// (flaky, rate-limited, and will break when DuckDuckGo reshuffles markup — exactly why this
/// backend is temporary), so it never runs in the default `swift test` pass.
///
///   WEB_SEARCH_LIVE=1 swift test --filter WebSearchLiveTests
@Suite("Web search live", .enabled(if: ProcessInfo.processInfo.environment["WEB_SEARCH_LIVE"] == "1"))
struct WebSearchLiveTests {

    @Test("DuckDuckGo HTML backend returns parseable results for a real query")
    func liveSearch() async throws {
        let backend = DuckDuckGoHTMLSearchBackend()
        let results = try await backend.search(query: "swift codable json tutorial", limit: 10)

        #expect(!results.isEmpty)
        for result in results {
            #expect(result.url.hasPrefix("http"))
            #expect(!result.title.isEmpty)
        }
    }

    @Test("tool-side domain filtering works on real results")
    func liveDomainFilter() async throws {
        let backend = DuckDuckGoHTMLSearchBackend()
        let results = try await backend.search(query: "apple developer documentation swift", limit: 10)
        try #require(!results.isEmpty)

        let blocked = WebSearchTool.applyDomainFilters(results, allowed: [], blocked: ["apple.com"])
        #expect(blocked.allSatisfy { URL(string: $0.url)?.host.map { !$0.hasSuffix("apple.com") } ?? true })
    }
}
