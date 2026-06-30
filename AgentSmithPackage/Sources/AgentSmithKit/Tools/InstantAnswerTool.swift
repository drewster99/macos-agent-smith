import Foundation

/// Brown tool: a quick factual summary for a recognized entity/topic via DuckDuckGo's Instant
/// Answer API (`api.duckduckgo.com`) — keyless, no account.
///
/// This is the complement to `web_search`, not a replacement: it returns a Wikipedia-style
/// abstract, key facts, the source/official URLs, and related topics for a *known* entity
/// (a person, place, organization, technology, concept). It returns nothing for open-ended
/// queries ("best laptop 2026") — those need `web_search`. (Verified June 2026: the JSON API no
/// longer returns dictionary definitions or unit conversions; it's effectively entity facts.)
struct InstantAnswerTool: AgentTool {
    let name = "instant_answer"

    private let service: DuckDuckGoInstantAnswerService

    /// Caps so a verbose entity (large infobox / many related topics) can't flood the output.
    private static let maxFacts = 12
    private static let maxRelated = 6

    init(service: DuckDuckGoInstantAnswerService = DuckDuckGoInstantAnswerService()) {
        self.service = service
    }

    var toolDescription: String {
        """
        Look up a quick factual summary for a recognized entity or topic — a person, place, \
        organization, technology, product, or concept — from DuckDuckGo's Instant Answer API \
        (sourced mainly from Wikipedia). Returns a short abstract, key facts, the source URL and \
        the entity's official site (when known), and related topics. \
        Use this for "what/who is X" style lookups when X is a nameable thing and you want fast, \
        sourced facts without reading a full page. \
        It is NOT a web search and NOT a dictionary/calculator: for open-ended queries (e.g. \
        "best laptop 2026", "how do I do X"), comparisons, or anything that isn't a specific \
        named entity, it returns nothing — use `web_search` for those.
        """
    }

    public func description(for role: AgentRole) -> String {
        switch role {
        case .brown:
            return toolDescription + " " + BrownBehavior.approvalGateNote(outcome: "the instant-answer summary")
        default:
            return toolDescription
        }
    }

    let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "query": .dictionary([
                "type": .string("string"),
                "description": .string("The entity or topic to look up (e.g. \"Swift programming language\", \"Grace Hopper\", \"Kyoto\").")
            ])
        ]),
        "required": .array([.string("query")])
    ]

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .brown
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard case .string(let query) = arguments["query"] else {
            throw ToolCallError.missingRequiredArgument("query")
        }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return .failure("Refused: the `query` argument was empty.")
        }

        let answer: InstantAnswer
        do {
            answer = try await service.lookup(query: trimmedQuery)
        } catch {
            return .failure("Instant answer lookup failed: \(error.localizedDescription)")
        }

        return .success(Self.formatOutput(answer, query: trimmedQuery))
    }

    // MARK: - Output formatting (pure, testable)

    /// Per-field output caps so a verbose entity can't flood the agent's context (only field
    /// COUNTS are bounded by `maxFacts`/`maxRelated` otherwise).
    private static let maxAbstractChars = 1200
    private static let maxFieldChars = 400
    private static let maxValueChars = 200

    static func truncated(_ text: String, _ maxChars: Int) -> String {
        text.count <= maxChars ? text : String(text.prefix(maxChars)) + "…"
    }

    static func formatOutput(_ answer: InstantAnswer, query: String) -> String {
        if answer.hasUsefulContent {
            var lines: [String] = []

            let headingLine = answer.heading.isEmpty ? query : answer.heading
            if answer.typeLabel.isEmpty {
                lines.append(headingLine)
            } else {
                lines.append("\(headingLine) (\(answer.typeLabel))")
            }

            if !answer.abstract.isEmpty {
                lines.append("")
                lines.append(truncated(answer.abstract, maxAbstractChars))
            }
            if !answer.answer.isEmpty {
                lines.append("")
                lines.append("Answer: \(truncated(answer.answer, maxFieldChars))")
            }
            if !answer.definition.isEmpty {
                lines.append("")
                lines.append("Definition: \(truncated(answer.definition, maxFieldChars))")
            }

            if let abstractURL = validatedHTTPURL(answer.abstractURL) {
                let source = answer.abstractSource.isEmpty ? "source" : answer.abstractSource
                lines.append("")
                lines.append("Source: \(source) — \(abstractURL)")
            }
            if let official = answer.officialSiteURL, let officialURL = validatedHTTPURL(official) {
                lines.append("Official site: \(officialURL)")
            }

            if !answer.infobox.isEmpty {
                lines.append("")
                lines.append("Key facts:")
                for fact in answer.infobox.prefix(maxFacts) {
                    lines.append("- \(fact.label): \(truncated(fact.value, maxValueChars))")
                }
            }

            if !answer.relatedTopics.isEmpty {
                lines.append("")
                lines.append("Related:")
                for topic in answer.relatedTopics.prefix(maxRelated) {
                    lines.append("- \(truncated(topic.text, maxValueChars))")
                }
            }

            return lines.joined(separator: "\n")
        }

        if !answer.relatedTopics.isEmpty {
            let headingLine = answer.heading.isEmpty ? query : answer.heading
            var lines = ["\"\(headingLine)\" is ambiguous — related topics:"]
            for topic in answer.relatedTopics.prefix(maxRelated) {
                if let url = validatedHTTPURL(topic.url) {
                    lines.append("- \(truncated(topic.text, maxValueChars)) — \(url)")
                } else {
                    lines.append("- \(truncated(topic.text, maxValueChars))")
                }
            }
            lines.append("")
            lines.append("Use `web_search` to search the web for a specific one.")
            return lines.joined(separator: "\n")
        }

        return """
            No instant answer for "\(query)". DuckDuckGo's Instant Answer API only covers \
            recognized entities/topics (sourced mainly from Wikipedia); it returns nothing for \
            open-ended queries. Use `web_search` to find web pages instead.
            """
    }

    /// Returns `raw` only if it parses to an absolute http(s) URL with a host; otherwise nil. The
    /// Instant Answer API's URLs are untrusted, so we never echo a `javascript:` / `data:` / relative
    /// or otherwise non-http(s) link to the agent (mirrors `web_search`'s URL sanitization).
    static func validatedHTTPURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else { return nil }
        return trimmed
    }
}
