import Foundation

/// A single web-search result. `title` / `url` / `snippet` are the universal fields every
/// backend can fill (the temporary DuckDuckGo scrape today, a keyed JSON API later). The
/// remaining fields are the *common-but-not-universal* extras that real keyed APIs return —
/// kept optional so a richer provider (Brave, Tavily) maps in with a direct field copy without
/// any change to `WebSearchTool`, while the scrape backend simply leaves them empty.
///
/// Field origins, for the eventual backend swap:
/// - `age`           ← Brave `age` / `page_age`, Tavily `published_date`
/// - `score`         ← Tavily `score` (provider's own scale)
/// - `extraSnippets` ← Brave `extra_snippets`
/// - `faviconURL`    ← Brave `meta_url.favicon`
public struct WebSearchResult: Sendable, Equatable {
    public let title: String
    public let url: String
    public let snippet: String

    /// Provider-formatted freshness / publish indicator (a display string, not a parsed `Date`,
    /// since providers format it differently). `nil` when the backend can't supply one.
    public let age: String?

    /// Backend relevance score in the provider's own scale, when available.
    public let score: Double?

    /// Additional alternative excerpts beyond `snippet`, when available.
    public let extraSnippets: [String]

    /// Favicon URL for the result's host, when the backend provides one.
    public let faviconURL: String?

    public init(
        title: String,
        url: String,
        snippet: String,
        age: String? = nil,
        score: Double? = nil,
        extraSnippets: [String] = [],
        faviconURL: String? = nil
    ) {
        self.title = title
        self.url = url
        self.snippet = snippet
        self.age = age
        self.score = score
        self.extraSnippets = extraSnippets
        self.faviconURL = faviconURL
    }
}

/// Failures a `WebSearchBackend` can surface. `blocked` is distinct from an empty result set:
/// it means the provider refused/throttled us (anti-bot challenge, rate limit), which a caller
/// may want to report differently from "the query legitimately matched nothing".
public enum WebSearchError: Error, LocalizedError, Equatable {
    case transport(String)
    case http(status: Int)
    case blocked(String)
    case parse(String)

    public var errorDescription: String? {
        switch self {
        case .transport(let detail): return "Web search transport error: \(detail)"
        case .http(let status): return "Web search backend returned HTTP \(status)."
        case .blocked(let detail): return "Web search backend blocked or throttled the request: \(detail)"
        case .parse(let detail): return "Could not parse web search results: \(detail)"
        }
    }
}

/// Pluggable source of web-search results behind the `web_search` tool.
///
/// This protocol exists specifically so the current **temporary** DuckDuckGo HTML-scrape
/// backend (`DuckDuckGoHTMLSearchBackend`) can be replaced — without touching `WebSearchTool`
/// or Brown's wiring — once we pick a permanent keyed provider (Brave / Tavily / …). See the
/// `DuckDuckGoHTMLSearchBackend` header and `ROADMAP.md` ("Web Search tool") for the plan.
///
/// Backends return raw, ranked results; domain allow/block filtering and the final result cap
/// are applied uniformly by `WebSearchTool` so every backend gets consistent behavior for free.
public protocol WebSearchBackend: Sendable {
    /// Stable identifier for logs/diagnostics, e.g. `"duckduckgo-html"`, `"brave"`.
    var identifier: String { get }

    /// A short human-facing label for the active backend, surfaced in tool output so it's
    /// obvious which source produced the results (and, today, that it's the temporary one).
    var displayName: String { get }

    /// Runs a search and returns up to `limit` ranked results. Throws `WebSearchError` on
    /// transport/HTTP/blocking/parse failures; returns an empty array when the query simply
    /// matched nothing.
    func search(query: String, limit: Int) async throws -> [WebSearchResult]
}
