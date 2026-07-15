import Foundation
import os

// ============================================================================================
//  TEMPORARY IMPLEMENTATION — DO NOT TREAT AS PERMANENT
//  --------------------------------------------------------------------------------------------
//  This backend scrapes DuckDuckGo's HTML SERP (`html.duckduckgo.com/html/`). It exists ONLY so
//  the rest of the harness can be developed against a `web_search` tool that is at least
//  somewhat usable, with NO API key or account required.
//
//  Why it's temporary:
//    - No engine exposes keyless *structured* (JSON) web results — verified June 2026: DDG and
//      Google both ignore `Accept: application/json` / `format=json` on their SERP and always
//      return HTML. DDG's keyless JSON endpoint (api.duckduckgo.com) is the Instant Answer API,
//      not web search, and returns nothing for normal queries.
//    - Scraping HTML is brittle (breaks if DuckDuckGo reshuffles `result__a` / `result__snippet`
//      markup), rate-limited, and ToS-gray. It must not ship as the long-term backend.
//
//  Replacement plan (target: re-evaluate week of 2026-06-30):
//    Pick a permanent provider — leading candidates Brave Search API or Tavily (keyed JSON,
//    domain filters, recency, SLA) — implement it as another `WebSearchBackend`, store its key
//    in Keychain (mirror `MCPSecretStore` / SwiftLLMKit `KeychainService`), and switch the
//    default backend in `BrownBehavior.tools()`. `WebSearchTool` and Brown's wiring should not
//    need to change. See ROADMAP.md → "Web Search tool".
// ============================================================================================

/// **Temporary** `WebSearchBackend` that scrapes the DuckDuckGo HTML SERP. See the file header
/// for why this is temporary and the replacement plan. Stateless and `Sendable`: one shared
/// `URLSession` request per search, no mutable state.
struct DuckDuckGoHTMLSearchBackend: WebSearchBackend {
    let identifier = "duckduckgo-html"
    let displayName = "DuckDuckGo (temporary HTML backend)"

    /// Injectable for deterministic tests (a `URLProtocol` stub); defaults to `.shared` in
    /// production.
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    private static let logger = Logger(subsystem: "AgentSmithKit", category: "WebSearch")

    /// A desktop-browser User-Agent. DuckDuckGo serves an empty/blocking page to obvious bot
    /// agents; a normal browser UA gets the standard results markup.
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private static let endpoint = "https://html.duckduckgo.com/html/"

    func search(query: String, limit: Int) async throws -> [WebSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(string: Self.endpoint)
        components?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        guard let url = components?.url else {
            throw WebSearchError.transport("could not build request URL for query")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.timeoutInterval = 20

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await BoundedResponseReader.data(for: request, using: session)
        } catch {
            throw WebSearchError.transport(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            // 202 is what the endpoint returns for some malformed/refused requests; treat any
            // non-200 as a failure so the tool can report it rather than parsing a junk page.
            throw WebSearchError.http(status: http.statusCode)
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw WebSearchError.parse("response body was not valid UTF-8")
        }

        let results = Self.parseResults(from: html)
        if results.isEmpty, Self.looksBlocked(html) {
            Self.logger.debug("DuckDuckGo returned no parseable results and looks like a block/challenge page")
            throw WebSearchError.blocked("DuckDuckGo returned no results and the page looks like a challenge/anti-bot response")
        }
        return Array(results.prefix(max(0, limit)))
    }

    // MARK: - Parsing (pure, testable)

    /// Heuristic: a 200 response with zero parseable results *and* no "no results" marker is
    /// more likely a challenge/anomaly page than a genuine empty result set. Kept conservative
    /// — a false negative just yields an empty result list, which the tool reports cleanly.
    static func looksBlocked(_ html: String) -> Bool {
        let lowered = html.lowercased()
        if lowered.contains("no results") || lowered.contains("no more results") { return false }
        let markers = ["anomaly", "challenge", "unusual traffic", "if this error persists", "captcha"]
        return markers.contains { lowered.contains($0) } || html.count < 400
    }

    /// Parses DuckDuckGo HTML-SERP markup into results. Each organic result is an
    /// `<a class="result__a" href="…">Title</a>` followed by an `<a class="result__snippet">…</a>`.
    /// Snippets are paired to the *nearest following* title anchor (not by index) so sponsored
    /// rows or a missing snippet can't desync the pairing. `href`s are normally absolute; the
    /// legacy `/l/?uddg=<encoded>` redirect form is decoded, and ad/tracking links (`/y.js`) and
    /// non-http schemes are dropped.
    static func parseResults(from html: String) -> [WebSearchResult] {
        let ns = html as NSString
        let full = NSRange(location: 0, length: ns.length)

        guard
            let titleRegex = try? NSRegularExpression(
                pattern: "class=\"result__a\"[^>]*href=\"([^\"]*)\"[^>]*>(.*?)</a>",
                options: [.dotMatchesLineSeparators, .caseInsensitive]
            ),
            let snippetRegex = try? NSRegularExpression(
                pattern: "class=\"result__snippet\"[^>]*>(.*?)</a>",
                options: [.dotMatchesLineSeparators, .caseInsensitive]
            )
        else {
            return []
        }

        let titleMatches = titleRegex.matches(in: html, range: full)
        let snippetMatches = snippetRegex.matches(in: html, range: full)

        var results: [WebSearchResult] = []
        for (index, match) in titleMatches.enumerated() {
            guard match.numberOfRanges >= 3 else { continue }
            let href = ns.substring(with: match.range(at: 1))
            guard let resolvedURL = resolveURL(href) else { continue }

            let title = decodeHTMLText(ns.substring(with: match.range(at: 2)))
            guard !title.isEmpty else { continue }

            // The snippet for this result is the first snippet anchor occurring between this
            // title anchor and the next one.
            let lowerBound = match.range.location + match.range.length
            let upperBound = index + 1 < titleMatches.count
                ? titleMatches[index + 1].range.location
                : ns.length
            var snippet = ""
            for snippetMatch in snippetMatches
            where snippetMatch.range.location >= lowerBound && snippetMatch.range.location < upperBound {
                if snippetMatch.numberOfRanges >= 2 {
                    snippet = decodeHTMLText(ns.substring(with: snippetMatch.range(at: 1)))
                }
                break
            }

            results.append(WebSearchResult(title: title, url: resolvedURL, snippet: snippet))
        }
        return results
    }

    /// Resolves a SERP href to an absolute http(s) URL. Returns `nil` for ad/tracking links
    /// (`/y.js`), empty hrefs, and non-http schemes. Handles the legacy DuckDuckGo redirect
    /// wrapper `…/l/?uddg=<percent-encoded-destination>` and scheme-relative `//host/…` hrefs.
    static func resolveURL(_ rawHref: String) -> String? {
        var href = rawHref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !href.isEmpty else { return nil }

        // Decode the legacy redirect wrapper if present. Use the raw percent-encoded value and
        // decode exactly once, so a destination URL that legitimately contains escapes isn't
        // double-decoded.
        if href.contains("/l/?") || href.contains("uddg=") {
            if let comps = URLComponents(string: href.hasPrefix("//") ? "https:" + href : href),
               let rawUddg = comps.percentEncodedQueryItems?.first(where: { $0.name == "uddg" })?.value,
               let decoded = rawUddg.removingPercentEncoding {
                href = decoded
            }
        }

        // Drop DuckDuckGo's ad/tracking redirector.
        if href.contains("duckduckgo.com/y.js") { return nil }

        if href.hasPrefix("//") { href = "https:" + href }

        guard href.hasPrefix("http://") || href.hasPrefix("https://") else { return nil }
        return href
    }

    /// Strips HTML tags (e.g. `<b>` query highlights) and decodes common HTML entities, then
    /// collapses internal whitespace. Good enough for SERP titles/snippets; not a general
    /// HTML-to-text converter.
    static func decodeHTMLText(_ raw: String) -> String {
        let withoutTags = raw.replacingOccurrences(
            of: "<[^>]+>", with: "", options: .regularExpression
        )
        let decoded = decodeEntities(withoutTags)
        return decoded
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Decodes the small set of HTML entities that appear in SERP text, plus numeric
    /// (`&#39;`) and hex (`&#x27;` / `&#X27;`) character references.
    static func decodeEntities(_ input: String) -> String {
        var result = input
        // Ordered, NOT a dictionary: dictionary iteration order is randomized per process, which
        // makes decoding of double-encoded input (e.g. `&amp;lt;`) non-deterministic. `&amp;`
        // MUST be applied last so `&amp;lt;` decodes one level to `&lt;` rather than collapsing
        // all the way to `<`.
        let named: [(entity: String, replacement: String)] = [
            ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&apos;", "'"), ("&#39;", "'"), ("&nbsp;", " "), ("&hellip;", "…"),
            ("&mdash;", "—"), ("&ndash;", "–"), ("&rsquo;", "’"), ("&lsquo;", "‘"),
            ("&ldquo;", "“"), ("&rdquo;", "”"), ("&amp;", "&")
        ]
        for pair in named {
            result = result.replacingOccurrences(of: pair.entity, with: pair.replacement)
        }

        // Numeric character references: &#NNN; (decimal) and &#xHH; / &#XHH; (hex).
        guard let regex = try? NSRegularExpression(pattern: "&#([xX]?[0-9a-fA-F]+);") else { return result }
        let ns = result as NSString
        var output = ""
        var lastEnd = 0
        for match in regex.matches(in: result, range: NSRange(location: 0, length: ns.length)) {
            output += ns.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            let token = ns.substring(with: match.range(at: 1))
            let scalarValue: UInt32?
            if token.hasPrefix("x") || token.hasPrefix("X") {
                scalarValue = UInt32(token.dropFirst(), radix: 16)
            } else {
                scalarValue = UInt32(token, radix: 10)
            }
            if let value = scalarValue, let scalar = Unicode.Scalar(value) {
                output += String(scalar)
            } else {
                output += ns.substring(with: match.range)
            }
            lastEnd = match.range.location + match.range.length
        }
        output += ns.substring(with: NSRange(location: lastEnd, length: ns.length - lastEnd))
        return output
    }
}
