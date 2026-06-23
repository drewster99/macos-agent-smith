import Testing
import Foundation
import SwiftLLMKit
@testable import AgentSmithKit

// MARK: - Test doubles

/// In-memory `WebSearchBackend` for exercising `WebSearchTool.execute(...)` without a network.
private struct StubWebSearchBackend: WebSearchBackend {
    let identifier = "stub"
    let displayName = "Stub"
    let results: [WebSearchResult]
    let error: WebSearchError?

    init(results: [WebSearchResult] = [], error: WebSearchError? = nil) {
        self.results = results
        self.error = error
    }

    func search(query: String, limit: Int) async throws -> [WebSearchResult] {
        if let error { throw error }
        return Array(results.prefix(limit))
    }
}

/// Runs `body` and returns the error it threw (or `nil`). Lets a test assert on the specific
/// error case with a plain `#expect`, using a single trailing closure (no multiple-closure call).
private func caughtError(_ body: () async throws -> Void) async -> Error? {
    do {
        try await body()
        return nil
    } catch {
        return error
    }
}

/// True when `error` is of type `E` and satisfies `predicate`. Avoids pinning associated values
/// (detail strings) we don't want to hardcode while keeping call sites to a single closure.
private func matches<E: Error>(_ error: Error?, _ type: E.Type, _ predicate: (E) -> Bool) -> Bool {
    guard let typed = error as? E else { return false }
    return predicate(typed)
}

// MARK: - Tool execute() seams (no network)

@Suite("Web tools execute")
struct WebToolsExecuteTests {

    @Test("web_search: missing query throws missingRequiredArgument")
    func webSearchMissingQuery() async {
        let tool = WebSearchTool(backend: StubWebSearchBackend())
        let ctx = TestToolContext.make()
        let error = await caughtError { _ = try await tool.execute(arguments: [:], context: ctx) }
        #expect(matches(error, ToolCallError.self) { event in
            if case .missingRequiredArgument = event { return true }
            return false
        })
    }

    @Test("web_search: empty/whitespace query is refused, not searched")
    func webSearchEmptyQuery() async throws {
        let tool = WebSearchTool(backend: StubWebSearchBackend())
        let result = try await tool.execute(arguments: ["query": .string("   ")], context: TestToolContext.make())
        #expect(!result.succeeded)
        #expect(result.output.lowercased().contains("empty"))
    }

    @Test("web_search: success formats backend results")
    func webSearchSuccess() async throws {
        let backend = StubWebSearchBackend(results: [
            WebSearchResult(title: "Swift.org", url: "https://swift.org", snippet: "The Swift language")
        ])
        let tool = WebSearchTool(backend: backend)
        let result = try await tool.execute(arguments: ["query": .string("swift")], context: TestToolContext.make())
        #expect(result.succeeded)
        #expect(result.output.contains("Swift.org"))
        #expect(result.output.contains("https://swift.org"))
    }

    @Test("web_search: backend error is surfaced as a tool failure")
    func webSearchBackendError() async throws {
        let backend = StubWebSearchBackend(error: .http(status: 503))
        let tool = WebSearchTool(backend: backend)
        let result = try await tool.execute(arguments: ["query": .string("swift")], context: TestToolContext.make())
        #expect(!result.succeeded)
        #expect(result.output.contains("Web search failed"))
    }

    @Test("web_search: allowed + blocked domains both apply through execute")
    func webSearchDomainFilterThroughExecute() async throws {
        let backend = StubWebSearchBackend(results: [
            WebSearchResult(title: "good", url: "https://docs.swift.org/a", snippet: ""),
            WebSearchResult(title: "spam", url: "https://spam.swift.org/b", snippet: ""),
            WebSearchResult(title: "off", url: "https://example.com/c", snippet: "")
        ])
        let tool = WebSearchTool(backend: backend)
        let args: [String: AnyCodable] = [
            "query": .string("swift"),
            "allowed_domains": .array([.string("swift.org")]),
            "blocked_domains": .array([.string("spam.swift.org")])
        ]
        let result = try await tool.execute(arguments: args, context: TestToolContext.make())
        #expect(result.succeeded)
        #expect(result.output.contains("docs.swift.org"))
        #expect(!result.output.contains("spam.swift.org"))
        #expect(!result.output.contains("example.com"))
    }

    @Test("instant_answer: empty query is refused before any lookup")
    func instantAnswerEmptyQuery() async throws {
        let tool = InstantAnswerTool()
        let result = try await tool.execute(arguments: ["query": .string("  ")], context: TestToolContext.make())
        #expect(!result.succeeded)
        #expect(result.output.lowercased().contains("empty"))
    }

    @Test("instant_answer: missing query throws missingRequiredArgument")
    func instantAnswerMissingQuery() async {
        let tool = InstantAnswerTool()
        let ctx = TestToolContext.make()
        let error = await caughtError { _ = try await tool.execute(arguments: [:], context: ctx) }
        #expect(matches(error, ToolCallError.self) { event in
            if case .missingRequiredArgument = event { return true }
            return false
        })
    }
}

// MARK: - Network layer (deterministic via URLProtocolStub)

@Suite("Web tools network", .serialized)
struct WebToolsNetworkTests {

    private static let ddgResultsHTML = """
    <div class="result"><a class="result__a" href="https://a.com/x">A title</a>
    <a class="result__snippet">A snippet.</a></div>
    """

    private static let entityJSON = """
    { "Heading": "Swift", "AbstractText": "A language.", "AbstractSource": "Wikipedia",
      "AbstractURL": "https://en.wikipedia.org/wiki/Swift", "Type": "A" }
    """

    @Test("DuckDuckGo backend: non-200 throws .http")
    func ddgNon200() async {
        let session = URLProtocolStub.makeSession(statusCode: 503, body: Data())
        let backend = DuckDuckGoHTMLSearchBackend(session: session)
        let error = await caughtError { _ = try await backend.search(query: "swift", limit: 5) }
        #expect(matches(error, WebSearchError.self) { event in
            if case .http(let status) = event { return status == 503 }
            return false
        })
    }

    @Test("DuckDuckGo backend: 200 challenge page with no results throws .blocked")
    func ddgBlockedPage() async {
        let session = URLProtocolStub.makeSession(
            statusCode: 200,
            body: Data(String(repeating: "x", count: 600).appending(" unusual traffic detected ").utf8)
        )
        let backend = DuckDuckGoHTMLSearchBackend(session: session)
        let error = await caughtError { _ = try await backend.search(query: "swift", limit: 5) }
        #expect(matches(error, WebSearchError.self) { event in
            if case .blocked = event { return true }
            return false
        })
    }

    @Test("DuckDuckGo backend: non-UTF-8 body throws .parse")
    func ddgNonUTF8() async {
        let session = URLProtocolStub.makeSession(statusCode: 200, body: Data([0xFF, 0xFE, 0xFF, 0xFE]))
        let backend = DuckDuckGoHTMLSearchBackend(session: session)
        let error = await caughtError { _ = try await backend.search(query: "swift", limit: 5) }
        #expect(matches(error, WebSearchError.self) { event in
            if case .parse = event { return true }
            return false
        })
    }

    @Test("DuckDuckGo backend: valid HTML returns parsed results")
    func ddgValid() async throws {
        let session = URLProtocolStub.makeSession(statusCode: 200, body: Data(Self.ddgResultsHTML.utf8))
        let backend = DuckDuckGoHTMLSearchBackend(session: session)
        let results = try await backend.search(query: "swift", limit: 5)
        #expect(results.count == 1)
        #expect(results[0].url == "https://a.com/x")
        #expect(results[0].title == "A title")
    }

    @Test("Instant Answer service: non-200 throws .http")
    func iaNon200() async {
        let session = URLProtocolStub.makeSession(statusCode: 500, body: Data())
        let service = DuckDuckGoInstantAnswerService(session: session)
        let error = await caughtError { _ = try await service.lookup(query: "swift") }
        #expect(matches(error, InstantAnswerError.self) { event in
            if case .http(let status) = event { return status == 500 }
            return false
        })
    }

    @Test("Instant Answer service: malformed (non-object) JSON throws .parse")
    func iaMalformed() async {
        let session = URLProtocolStub.makeSession(statusCode: 200, body: Data("[]".utf8))
        let service = DuckDuckGoInstantAnswerService(session: session)
        let error = await caughtError { _ = try await service.lookup(query: "swift") }
        #expect(matches(error, InstantAnswerError.self) { event in
            if case .parse = event { return true }
            return false
        })
    }

    @Test("Instant Answer service: valid JSON parses an entity")
    func iaValid() async throws {
        let session = URLProtocolStub.makeSession(statusCode: 200, body: Data(Self.entityJSON.utf8))
        let service = DuckDuckGoInstantAnswerService(session: session)
        let answer = try await service.lookup(query: "swift")
        #expect(answer.heading == "Swift")
        #expect(answer.hasUsefulContent)
    }

    @Test("instant_answer tool: success and error both flow through execute")
    func iaToolExecute() async throws {
        let okSession = URLProtocolStub.makeSession(statusCode: 200, body: Data(Self.entityJSON.utf8))
        let okTool = InstantAnswerTool(service: DuckDuckGoInstantAnswerService(session: okSession))
        let okResult = try await okTool.execute(arguments: ["query": .string("swift")], context: TestToolContext.make())
        #expect(okResult.succeeded)
        #expect(okResult.output.contains("Swift"))

        let errSession = URLProtocolStub.makeSession(statusCode: 500, body: Data())
        let errTool = InstantAnswerTool(service: DuckDuckGoInstantAnswerService(session: errSession))
        let failed = try await errTool.execute(arguments: ["query": .string("swift")], context: TestToolContext.make())
        #expect(!failed.succeeded)
        #expect(failed.output.contains("Instant answer lookup failed"))
    }
}

// MARK: - Classification & wiring

@Suite("Web tools wiring")
struct WebToolsWiringTests {

    @Test("both tools are open-world, non-destructive, read-only")
    func classification() {
        let web = WebSearchTool()
        let instant = InstantAnswerTool()
        #expect(web.isOpenWorld)
        #expect(!web.isDestructive)
        #expect(!ToolSafetyClassification.hasSideEffects(toolName: "web_search"))
        #expect(instant.isOpenWorld)
        #expect(!instant.isDestructive)
        #expect(!ToolSafetyClassification.hasSideEffects(toolName: "instant_answer"))
    }

    @Test("both names are known to the classification table")
    func knownNames() {
        #expect(ToolSafetyClassification.knownBuiltInNames.contains("web_search"))
        #expect(ToolSafetyClassification.knownBuiltInNames.contains("instant_answer"))
    }

    @Test("Brown exposes both tools and Smith's manifest lists them")
    func brownWiringAndManifest() {
        #expect(BrownBehavior.toolNames.contains("web_search"))
        #expect(BrownBehavior.toolNames.contains("instant_answer"))
        let manifest = BrownBehavior.smithFacingToolManifest()
        #expect(manifest.contains("web_search"))
        #expect(manifest.contains("instant_answer"))
    }
}

// MARK: - Brave backend (proves swappability)

@Suite("Brave backend mapping")
struct BraveSearchBackendTests {

    private static let braveJSON = """
    { "web": { "results": [
      { "title": "Swift.org",
        "url": "https://swift.org",
        "description": "The <strong>Swift</strong> programming language.",
        "page_age": "2025-01-02T00:00:00Z",
        "age": "5 months ago",
        "extra_snippets": ["Open source", "Backed by Apple"],
        "meta_url": { "favicon": "https://swift.org/favicon.ico", "hostname": "swift.org" } }
    ] } }
    """

    @Test("maps every WebSearchResult field from a Brave response (highlight tags stripped)")
    func mapsFields() throws {
        let results = try BraveSearchBackend.parse(Data(Self.braveJSON.utf8), limit: 10)
        #expect(results.count == 1)
        let result = results[0]
        #expect(result.title == "Swift.org")
        #expect(result.url == "https://swift.org")
        #expect(result.snippet == "The Swift programming language.")
        #expect(result.age == "5 months ago")
        #expect(result.extraSnippets == ["Open source", "Backed by Apple"])
        #expect(result.faviconURL == "https://swift.org/favicon.ico")
    }

    @Test("missing API key throws .blocked before any request")
    func missingKey() async {
        let backend = BraveSearchBackend(apiKey: { nil })
        let error = await caughtError { _ = try await backend.search(query: "swift", limit: 5) }
        #expect(matches(error, WebSearchError.self) { event in
            if case .blocked = event { return true }
            return false
        })
    }

    @Test("empty results array yields no results")
    func emptyResults() throws {
        let results = try BraveSearchBackend.parse(Data("{\"web\":{\"results\":[]}}".utf8), limit: 10)
        #expect(results.isEmpty)
    }
}
