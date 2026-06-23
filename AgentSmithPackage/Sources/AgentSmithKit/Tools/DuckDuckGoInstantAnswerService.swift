import Foundation

/// A parsed DuckDuckGo Instant Answer. This is the "answer box" data — sourced mainly from
/// Wikipedia/Wikidata — for a recognized entity/topic. It is NOT web search: for open-ended
/// queries every field comes back empty (use `web_search` for those). Verified June 2026:
/// definition and unit-conversion instant answers are no longer returned by the JSON API
/// (they're JS-only "spice" endpoints), so in practice this carries entity abstracts + infobox
/// facts + official site + related topics.
public struct InstantAnswer: Sendable, Equatable {
    public struct Fact: Sendable, Equatable {
        public let label: String
        public let value: String
        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    public struct RelatedTopic: Sendable, Equatable {
        public let text: String
        public let url: String
        public init(text: String, url: String) {
            self.text = text
            self.url = url
        }
    }

    public let heading: String
    public let abstract: String
    public let abstractSource: String
    public let abstractURL: String
    public let answer: String
    public let answerType: String
    public let definition: String
    public let definitionSource: String
    public let definitionURL: String
    /// Raw DuckDuckGo response type: `A` article, `D` disambiguation, `C` category, `N` name,
    /// `E` exclusive, or `""` (no instant answer).
    public let type: String
    /// The entity's official site, when DuckDuckGo supplies one (response `Results[0].FirstURL`).
    public let officialSiteURL: String?
    public let infobox: [Fact]
    public let relatedTopics: [RelatedTopic]

    public init(
        heading: String, abstract: String, abstractSource: String, abstractURL: String,
        answer: String, answerType: String, definition: String, definitionSource: String,
        definitionURL: String, type: String, officialSiteURL: String?,
        infobox: [Fact], relatedTopics: [RelatedTopic]
    ) {
        self.heading = heading
        self.abstract = abstract
        self.abstractSource = abstractSource
        self.abstractURL = abstractURL
        self.answer = answer
        self.answerType = answerType
        self.definition = definition
        self.definitionSource = definitionSource
        self.definitionURL = definitionURL
        self.type = type
        self.officialSiteURL = officialSiteURL
        self.infobox = infobox
        self.relatedTopics = relatedTopics
    }

    /// True when the answer carries a usable summary/fact (abstract, answer, definition, or
    /// infobox). A disambiguation page with only related topics is not "useful content" but is
    /// still handled specially by the tool's formatter.
    public var hasUsefulContent: Bool {
        !abstract.isEmpty || !answer.isEmpty || !definition.isEmpty || !infobox.isEmpty
    }

    /// Human-readable form of `type`.
    public var typeLabel: String {
        switch type {
        case "A": return "article"
        case "D": return "disambiguation"
        case "C": return "category"
        case "N": return "name"
        case "E": return "exclusive"
        default: return ""
        }
    }
}

/// Errors from the Instant Answer service.
public enum InstantAnswerError: Error, LocalizedError, Equatable {
    case transport(String)
    case http(status: Int)
    case parse(String)

    public var errorDescription: String? {
        switch self {
        case .transport(let detail): return "Instant Answer transport error: \(detail)"
        case .http(let status): return "Instant Answer API returned HTTP \(status)."
        case .parse(let detail): return "Could not parse Instant Answer response: \(detail)"
        }
    }
}

/// Client for DuckDuckGo's Instant Answer JSON API (`api.duckduckgo.com`). Unlike the web-search
/// backend, this is a single official, keyless JSON endpoint — there's no provider to swap, so
/// no protocol abstraction. Stateless and `Sendable`.
struct DuckDuckGoInstantAnswerService: Sendable {
    private static let endpoint = "https://api.duckduckgo.com/"
    /// DuckDuckGo asks Instant Answer API consumers to identify their app via the `t` parameter.
    private static let appToken = "AgentSmith"

    /// Injectable for deterministic tests (a `URLProtocol` stub); defaults to `.shared` in
    /// production.
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func lookup(query: String) async throws -> InstantAnswer {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Self.empty
        }

        var components = URLComponents(string: Self.endpoint)
        components?.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "no_html", value: "1"),
            URLQueryItem(name: "t", value: Self.appToken)
        ]
        guard let url = components?.url else {
            throw InstantAnswerError.transport("could not build request URL for query")
        }

        var request = URLRequest(url: url)
        request.setValue("AgentSmith/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw InstantAnswerError.transport(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw InstantAnswerError.http(status: http.statusCode)
        }

        return try Self.parse(data)
    }

    static let empty = InstantAnswer(
        heading: "", abstract: "", abstractSource: "", abstractURL: "",
        answer: "", answerType: "", definition: "", definitionSource: "",
        definitionURL: "", type: "", officialSiteURL: nil, infobox: [], relatedTopics: []
    )

    // MARK: - Parsing (pure, testable)

    /// Parses the Instant Answer JSON. Uses `JSONSerialization` rather than `Codable` because the
    /// response is loosely typed: `RelatedTopics` mixes flat topics with nested topic groups, and
    /// `Infobox.content[].value` can be a string or a number.
    static func parse(_ data: Data) throws -> InstantAnswer {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw InstantAnswerError.parse("response was not a JSON object")
        }

        func string(_ key: String) -> String { (obj[key] as? String) ?? "" }

        var infobox: [InstantAnswer.Fact] = []
        if let ib = obj["Infobox"] as? [String: Any],
           let content = ib["content"] as? [[String: Any]] {
            for item in content {
                let label = (item["label"] as? String) ?? ""
                let value: String
                if let s = item["value"] as? String {
                    value = s
                } else if let n = item["value"] as? NSNumber {
                    value = n.stringValue
                } else {
                    value = ""
                }
                if !label.isEmpty, !value.isEmpty {
                    infobox.append(.init(label: label, value: value))
                }
            }
        }

        var related: [InstantAnswer.RelatedTopic] = []
        if let topics = obj["RelatedTopics"] as? [[String: Any]] {
            for entry in topics {
                if let text = entry["Text"] as? String, !text.isEmpty,
                   let url = entry["FirstURL"] as? String, !url.isEmpty {
                    related.append(.init(text: text, url: url))
                } else if let grouped = entry["Topics"] as? [[String: Any]] {
                    // A grouped "Name"/"Topics" entry — flatten its members.
                    for member in grouped {
                        if let text = member["Text"] as? String, !text.isEmpty,
                           let url = member["FirstURL"] as? String, !url.isEmpty {
                            related.append(.init(text: text, url: url))
                        }
                    }
                }
            }
        }

        var officialSiteURL: String?
        if let results = obj["Results"] as? [[String: Any]],
           let first = results.first,
           let url = first["FirstURL"] as? String, !url.isEmpty {
            officialSiteURL = url
        }

        return InstantAnswer(
            heading: string("Heading"),
            abstract: string("AbstractText"),
            abstractSource: string("AbstractSource"),
            abstractURL: string("AbstractURL"),
            answer: string("Answer"),
            answerType: string("AnswerType"),
            definition: string("Definition"),
            definitionSource: string("DefinitionSource"),
            definitionURL: string("DefinitionURL"),
            type: string("Type"),
            officialSiteURL: officialSiteURL,
            infobox: infobox,
            relatedTopics: related
        )
    }
}
