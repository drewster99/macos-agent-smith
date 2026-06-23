import Foundation

// ============================================================================================
//  REFERENCE IMPLEMENTATION — NOT YET WIRED
//  --------------------------------------------------------------------------------------------
//  A keyed `WebSearchBackend` for the Brave Search API, written to PROVE the abstraction is
//  swappable: it exists, compiles, conforms to `WebSearchBackend`, and maps a Brave response
//  field-for-field into `WebSearchResult`. It is intentionally NOT added to
//  `BrownBehavior.tools()` — the permanent search provider is still being chosen (see the
//  `DuckDuckGoHTMLSearchBackend` header + ROADMAP "Web Search tool"). When Brave is confirmed,
//  going live is: supply the API key (Keychain, mirroring `MCPSecretStore` / SwiftLLMKit
//  `KeychainService`) to `init(apiKey:)`, and swap the default backend in `BrownBehavior.tools()`
//  from `DuckDuckGoHTMLSearchBackend()` to `BraveSearchBackend(apiKey:)`. Nothing in
//  `WebSearchTool` or Brown changes.
// ============================================================================================

/// Keyed `WebSearchBackend` for the Brave Search API (`api.search.brave.com`). See the file
/// header — this is a not-yet-wired reference implementation. Stateless and `Sendable`.
struct BraveSearchBackend: WebSearchBackend {
    let identifier = "brave"
    let displayName = "Brave Search"

    /// Resolved at call time (Keychain in production), so no key material is stored in the struct.
    private let apiKey: @Sendable () -> String?
    private let session: URLSession

    init(apiKey: @escaping @Sendable () -> String?, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    private static let endpoint = "https://api.search.brave.com/res/v1/web/search"

    func search(query: String, limit: Int) async throws -> [WebSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let key = apiKey(), !key.isEmpty else {
            throw WebSearchError.blocked("Brave Search API key is not configured")
        }

        var components = URLComponents(string: Self.endpoint)
        components?.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "count", value: String(max(1, min(20, limit)))),
            URLQueryItem(name: "extra_snippets", value: "true")
        ]
        guard let url = components?.url else {
            throw WebSearchError.transport("could not build request URL for query")
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
        request.timeoutInterval = 20

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw WebSearchError.transport(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw WebSearchError.http(status: http.statusCode)
        }

        return try Self.parse(data, limit: limit)
    }

    // MARK: - Parsing (pure, testable)

    /// Maps Brave's `web.results[]` into `WebSearchResult`. Demonstrates the field-for-field
    /// mapping the swap relies on: `title`/`url` direct, `description` → `snippet` (with
    /// `<strong>` highlight tags stripped via the shared `DuckDuckGoHTMLSearchBackend` helper),
    /// `age`/`page_age` → `age`, `extra_snippets` → `extraSnippets`, `meta_url.favicon` →
    /// `faviconURL`.
    static func parse(_ data: Data, limit: Int) throws -> [WebSearchResult] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw WebSearchError.parse("response was not a JSON object")
        }
        guard let web = obj["web"] as? [String: Any],
              let results = web["results"] as? [[String: Any]] else {
            return []
        }

        var mapped: [WebSearchResult] = []
        for item in results {
            guard let url = item["url"] as? String, !url.isEmpty else { continue }
            let title = DuckDuckGoHTMLSearchBackend.decodeHTMLText((item["title"] as? String) ?? "")
            let snippet = DuckDuckGoHTMLSearchBackend.decodeHTMLText((item["description"] as? String) ?? "")

            let age: String?
            if let a = item["age"] as? String, !a.isEmpty {
                age = a
            } else if let pa = item["page_age"] as? String, !pa.isEmpty {
                age = pa
            } else {
                age = nil
            }

            let extraSnippets: [String]
            if let extras = item["extra_snippets"] as? [String] {
                extraSnippets = extras
            } else {
                extraSnippets = []
            }

            var faviconURL: String?
            if let meta = item["meta_url"] as? [String: Any],
               let favicon = meta["favicon"] as? String, !favicon.isEmpty {
                faviconURL = favicon
            }

            mapped.append(WebSearchResult(
                title: title.isEmpty ? url : title,
                url: url,
                snippet: snippet,
                age: age,
                score: nil,
                extraSnippets: extraSnippets,
                faviconURL: faviconURL
            ))
        }
        return Array(mapped.prefix(max(0, limit)))
    }
}
