import Testing
import Foundation
@testable import AgentSmithKit

/// Tests for the `web_search` tool's pure logic: the **temporary** DuckDuckGo HTML parser
/// (`DuckDuckGoHTMLSearchBackend`) and `WebSearchTool`'s domain filtering / argument parsing.
/// Network I/O is not exercised here — these cover the parts that break silently if DuckDuckGo
/// reshuffles markup or if domain filtering regresses. When the temporary backend is replaced,
/// the parser tests go with it; the `WebSearchTool` tests stay (they're backend-agnostic).
@Suite("Web search")
struct WebSearchTests {

    // MARK: - DuckDuckGo HTML parsing

    /// A trimmed-down but structurally faithful DuckDuckGo HTML-SERP fragment: a direct-href
    /// result with entities + `<b>` highlights, a legacy `/l/?uddg=` redirect result, and a
    /// sponsored `/y.js` row that must be dropped.
    private static let fixture = """
    <div class="result results_links results_links_deep web-result">
      <h2 class="result__title">
        <a rel="nofollow" class="result__a" href="https://example.com/swift">Swift &amp; <b>JSON</b> Guide</a>
      </h2>
      <a class="result__snippet" href="https://example.com/swift">Learn Swift&#39;s Codable &amp; <b>JSON</b> decoding&hellip;</a>
    </div>
    <div class="result results_links results_links_deep web-result">
      <h2 class="result__title">
        <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fdeveloper.apple.com%2Fdocs&amp;rut=abc">Apple Developer Docs</a>
      </h2>
      <a class="result__snippet">Official Apple documentation.</a>
    </div>
    <div class="result result--ad">
      <a rel="nofollow" class="result__a" href="https://duckduckgo.com/y.js?ad_provider=foo">Sponsored Result</a>
      <a class="result__snippet">An ad we should skip.</a>
    </div>
    """

    @Test("parses titles, urls, and snippets in order")
    func parsesResults() {
        let results = DuckDuckGoHTMLSearchBackend.parseResults(from: Self.fixture)
        #expect(results.count == 2)

        #expect(results[0].title == "Swift & JSON Guide")
        #expect(results[0].url == "https://example.com/swift")
        #expect(results[0].snippet == "Learn Swift's Codable & JSON decoding…")
    }

    @Test("decodes the legacy /l/?uddg= redirect wrapper to the destination URL")
    func decodesRedirect() {
        let results = DuckDuckGoHTMLSearchBackend.parseResults(from: Self.fixture)
        #expect(results[1].title == "Apple Developer Docs")
        #expect(results[1].url == "https://developer.apple.com/docs")
        #expect(results[1].snippet == "Official Apple documentation.")
    }

    @Test("drops sponsored /y.js tracking results")
    func dropsAds() {
        let results = DuckDuckGoHTMLSearchBackend.parseResults(from: Self.fixture)
        #expect(!results.contains { $0.url.contains("y.js") })
        #expect(!results.contains { $0.title == "Sponsored Result" })
    }

    @Test("returns nothing for markup with no results")
    func emptyMarkup() {
        #expect(DuckDuckGoHTMLSearchBackend.parseResults(from: "<html><body>nope</body></html>").isEmpty)
    }

    // MARK: - URL resolution

    @Test("resolveURL handles scheme-relative, redirect, and rejects ads/non-http")
    func resolveURLCases() {
        #expect(DuckDuckGoHTMLSearchBackend.resolveURL("https://a.com/x") == "https://a.com/x")
        #expect(DuckDuckGoHTMLSearchBackend.resolveURL("//host.com/y") == "https://host.com/y")
        #expect(DuckDuckGoHTMLSearchBackend.resolveURL("https://duckduckgo.com/y.js?ad=1") == nil)
        #expect(DuckDuckGoHTMLSearchBackend.resolveURL("javascript:void(0)") == nil)
        #expect(DuckDuckGoHTMLSearchBackend.resolveURL("") == nil)
        #expect(
            DuckDuckGoHTMLSearchBackend.resolveURL("//duckduckgo.com/l/?uddg=https%3A%2F%2Fz.org%2Fp%3Fa%3D1")
                == "https://z.org/p?a=1"
        )
    }

    // MARK: - HTML entity decoding

    @Test("decodes named, decimal, and hex entities and strips tags")
    func entityDecoding() {
        #expect(DuckDuckGoHTMLSearchBackend.decodeHTMLText("a &amp; b") == "a & b")
        #expect(DuckDuckGoHTMLSearchBackend.decodeHTMLText("don&#39;t") == "don't")
        #expect(DuckDuckGoHTMLSearchBackend.decodeHTMLText("don&#x27;t") == "don't")
        // Uppercase hex character reference must also decode (regex allows [xX]).
        #expect(DuckDuckGoHTMLSearchBackend.decodeHTMLText("don&#X27;t") == "don't")
        #expect(DuckDuckGoHTMLSearchBackend.decodeHTMLText("<b>bold</b> text") == "bold text")
        #expect(DuckDuckGoHTMLSearchBackend.decodeHTMLText("  spaced   out \n line  ") == "spaced out line")
    }

    @Test("double-encoded entities decode exactly one level, deterministically")
    func doubleEncodedEntities() {
        // `&amp;` must be applied last, so `&amp;lt;` decodes to `&lt;` (one level), never `<`.
        // Run repeatedly to catch the old dictionary-iteration-order non-determinism.
        for _ in 0..<50 {
            #expect(DuckDuckGoHTMLSearchBackend.decodeHTMLText("5 &amp;lt; 10") == "5 &lt; 10")
        }
    }

    // MARK: - Domain filtering

    private func result(_ url: String) -> WebSearchResult {
        WebSearchResult(title: "t", url: url, snippet: "s")
    }

    @Test("allowed_domains keeps only matching hosts and subdomains")
    func allowedDomains() {
        let results = [
            result("https://apple.com/a"),
            result("https://developer.apple.com/b"),
            result("https://example.com/c")
        ]
        let filtered = WebSearchTool.applyDomainFilters(results, allowed: ["apple.com"], blocked: [])
        #expect(filtered.map(\.url) == ["https://apple.com/a", "https://developer.apple.com/b"])
    }

    @Test("blocked_domains drops matching hosts")
    func blockedDomains() {
        let results = [result("https://spam.com/a"), result("https://good.com/b")]
        let filtered = WebSearchTool.applyDomainFilters(results, allowed: [], blocked: ["spam.com"])
        #expect(filtered.map(\.url) == ["https://good.com/b"])
    }

    @Test("hostMatches ignores a leading www. on the domain")
    func wwwInsensitive() {
        #expect(WebSearchTool.hostMatches("www.apple.com", domain: "apple.com"))
        #expect(WebSearchTool.hostMatches("apple.com", domain: "www.apple.com"))
        #expect(!WebSearchTool.hostMatches("notapple.com", domain: "apple.com"))
        #expect(!WebSearchTool.hostMatches("apple.com.evil.com", domain: "apple.com"))
    }

    @Test("no filters returns results unchanged")
    func noFilters() {
        let results = [result("https://a.com"), result("https://b.com")]
        #expect(WebSearchTool.applyDomainFilters(results, allowed: [], blocked: []).count == 2)
    }

    // MARK: - max_results clamping

    // MARK: - Enriched result fields (forward-compat with keyed APIs)

    @Test("optional fields default to empty for backends that don't supply them")
    func enrichedDefaults() {
        let r = WebSearchResult(title: "t", url: "https://a.com", snippet: "s")
        #expect(r.age == nil)
        #expect(r.score == nil)
        #expect(r.extraSnippets.isEmpty)
        #expect(r.faviconURL == nil)
    }

    @Test("a Brave/Tavily-style result with freshness surfaces age in the output")
    func ageSurfacedInOutput() {
        let rich = WebSearchResult(
            title: "Swift 6 release notes",
            url: "https://swift.org/blog/swift-6",
            snippet: "What's new",
            age: "2 days ago",
            score: 0.97,
            extraSnippets: ["concurrency", "typed throws"],
            faviconURL: "https://swift.org/favicon.ico"
        )
        let output = WebSearchTool.formatOutput(
            results: [rich], query: "swift 6", backendName: "Brave",
            hadRawResults: true, allowed: [], blocked: []
        )
        #expect(output.contains("https://swift.org/blog/swift-6 (2 days ago)"))
        #expect(output.contains("Swift 6 release notes"))
    }

    @Test("results without freshness omit the age suffix")
    func noAgeNoSuffix() {
        let plain = WebSearchResult(title: "t", url: "https://a.com/x", snippet: "s")
        let output = WebSearchTool.formatOutput(
            results: [plain], query: "q", backendName: "DuckDuckGo",
            hadRawResults: true, allowed: [], blocked: []
        )
        #expect(output.contains("https://a.com/x"))
        #expect(!output.contains("()"))
    }

    @Test("long titles and snippets are length-capped in output")
    func truncatesLongFields() {
        let huge = String(repeating: "x", count: 5000)
        let result = WebSearchResult(title: huge, url: "https://a.com", snippet: huge)
        let out = WebSearchTool.formatOutput(
            results: [result], query: "q", backendName: "B",
            hadRawResults: true, allowed: [], blocked: []
        )
        #expect(out.contains("…"))
        // Bounded well under the raw 10k chars of title+snippet.
        #expect(out.count < 1000)
    }

    @Test("max_results clamps to [1, 20] and defaults sensibly")
    func maxResultsClamp() {
        #expect(WebSearchTool.clampedMaxResults(.int(5)) == 5)
        #expect(WebSearchTool.clampedMaxResults(.int(999)) == 20)
        #expect(WebSearchTool.clampedMaxResults(.int(0)) == 1)
        #expect(WebSearchTool.clampedMaxResults(.string("7")) == 7)
        #expect(WebSearchTool.clampedMaxResults(nil) == 10)
    }
}
