import Testing
import Foundation
@testable import AgentSmithKit

/// Tests for the `instant_answer` tool: the DuckDuckGo Instant Answer JSON parser
/// (`DuckDuckGoInstantAnswerService.parse`) and `InstantAnswerTool.formatOutput`. Network I/O is
/// covered separately by the gated `InstantAnswerLiveTests`.
@Suite("Instant answer")
struct InstantAnswerTests {

    /// A representative entity response: abstract + source/official URLs + an infobox (including a
    /// numeric value) + related topics (one flat, one inside a grouped "Name"/"Topics" entry).
    private static let entityJSON = """
    {
      "Heading": "Swift (programming language)",
      "AbstractText": "Swift is a high-level general-purpose programming language created by Apple.",
      "AbstractSource": "Wikipedia",
      "AbstractURL": "https://en.wikipedia.org/wiki/Swift_(programming_language)",
      "Answer": "",
      "AnswerType": "",
      "Definition": "",
      "Type": "A",
      "Results": [ { "FirstURL": "https://www.swift.org/", "Text": "Official site" } ],
      "Infobox": { "content": [
        { "label": "Paradigm", "value": "Multi-paradigm", "data_type": "string" },
        { "label": "Designed by", "value": "Chris Lattner", "data_type": "string" },
        { "label": "First appeared", "value": 2014, "data_type": "number" }
      ] },
      "RelatedTopics": [
        { "FirstURL": "https://duckduckgo.com/Objective-C", "Text": "Objective-C - A programming language." },
        { "Name": "Tools", "Topics": [
          { "FirstURL": "https://duckduckgo.com/LLVM", "Text": "LLVM - A compiler infrastructure." }
        ] }
      ]
    }
    """

    private static let disambiguationJSON = """
    {
      "Heading": "Python",
      "AbstractText": "",
      "Type": "D",
      "RelatedTopics": [
        { "FirstURL": "https://duckduckgo.com/Python_(programming_language)", "Text": "Python (programming language) - A high-level language." }
      ]
    }
    """

    // MARK: - Parsing

    @Test("parses an entity response: abstract, source, official site, infobox, related")
    func parsesEntity() throws {
        let a = try DuckDuckGoInstantAnswerService.parse(Data(Self.entityJSON.utf8))
        #expect(a.heading == "Swift (programming language)")
        #expect(a.abstract.hasPrefix("Swift is a high-level"))
        #expect(a.abstractSource == "Wikipedia")
        #expect(a.abstractURL == "https://en.wikipedia.org/wiki/Swift_(programming_language)")
        #expect(a.type == "A")
        #expect(a.typeLabel == "article")
        #expect(a.officialSiteURL == "https://www.swift.org/")
        #expect(a.hasUsefulContent)
    }

    @Test("infobox coerces numeric values to strings and keeps order")
    func parsesInfobox() throws {
        let a = try DuckDuckGoInstantAnswerService.parse(Data(Self.entityJSON.utf8))
        #expect(a.infobox.count == 3)
        #expect(a.infobox[0] == InstantAnswer.Fact(label: "Paradigm", value: "Multi-paradigm"))
        #expect(a.infobox[2] == InstantAnswer.Fact(label: "First appeared", value: "2014"))
    }

    @Test("related topics include flat entries and flatten grouped entries")
    func parsesRelated() throws {
        let a = try DuckDuckGoInstantAnswerService.parse(Data(Self.entityJSON.utf8))
        #expect(a.relatedTopics.count == 2)
        #expect(a.relatedTopics[0].text.hasPrefix("Objective-C"))
        #expect(a.relatedTopics[1].url == "https://duckduckgo.com/LLVM")
    }

    @Test("a disambiguation page has no useful content but carries related topics")
    func parsesDisambiguation() throws {
        let a = try DuckDuckGoInstantAnswerService.parse(Data(Self.disambiguationJSON.utf8))
        #expect(!a.hasUsefulContent)
        #expect(a.relatedTopics.count == 1)
    }

    @Test("an empty object yields no content; non-object JSON throws")
    func parsesEmptyAndInvalid() throws {
        let empty = try DuckDuckGoInstantAnswerService.parse(Data("{}".utf8))
        #expect(!empty.hasUsefulContent)
        #expect(empty.relatedTopics.isEmpty)
        #expect(throws: InstantAnswerError.self) {
            _ = try DuckDuckGoInstantAnswerService.parse(Data("[]".utf8))
        }
    }

    // MARK: - Output formatting

    @Test("entity output includes heading, abstract, source, official site, facts, related")
    func formatsEntity() throws {
        let a = try DuckDuckGoInstantAnswerService.parse(Data(Self.entityJSON.utf8))
        let out = InstantAnswerTool.formatOutput(a, query: "swift")
        #expect(out.contains("Swift (programming language) (article)"))
        #expect(out.contains("Swift is a high-level"))
        #expect(out.contains("Source: Wikipedia — https://en.wikipedia.org/wiki/Swift_(programming_language)"))
        #expect(out.contains("Official site: https://www.swift.org/"))
        #expect(out.contains("- Paradigm: Multi-paradigm"))
        #expect(out.contains("Related:"))
    }

    @Test("disambiguation output points the agent at web_search")
    func formatsDisambiguation() throws {
        let a = try DuckDuckGoInstantAnswerService.parse(Data(Self.disambiguationJSON.utf8))
        let out = InstantAnswerTool.formatOutput(a, query: "python")
        #expect(out.contains("is ambiguous"))
        #expect(out.contains("Python (programming language)"))
        #expect(out.contains("web_search"))
    }

    @Test("empty result tells the agent to use web_search")
    func formatsEmpty() {
        let out = InstantAnswerTool.formatOutput(DuckDuckGoInstantAnswerService.empty, query: "best laptop 2026")
        #expect(out.contains("No instant answer for \"best laptop 2026\""))
        #expect(out.contains("web_search"))
    }

    @Test("validatedHTTPURL keeps http(s) URLs and drops non-http / relative ones the agent could be tricked by")
    func validatesEchoedURLs() {
        #expect(InstantAnswerTool.validatedHTTPURL("https://example.com/x") == "https://example.com/x")
        #expect(InstantAnswerTool.validatedHTTPURL("http://example.com") == "http://example.com")
        #expect(InstantAnswerTool.validatedHTTPURL("  https://example.com/y  ") == "https://example.com/y")
        #expect(InstantAnswerTool.validatedHTTPURL("javascript:alert(1)") == nil)
        #expect(InstantAnswerTool.validatedHTTPURL("data:text/html,<b>x</b>") == nil)
        #expect(InstantAnswerTool.validatedHTTPURL("ftp://example.com/f") == nil)
        #expect(InstantAnswerTool.validatedHTTPURL("/relative/path") == nil)
        #expect(InstantAnswerTool.validatedHTTPURL("") == nil)
    }
}

/// Live network tests for the Instant Answer service — gated behind `WEB_SEARCH_LIVE=1` (same
/// flag as the web-search live suite) so the default `swift test` pass stays offline.
///
///   WEB_SEARCH_LIVE=1 swift test --filter InstantAnswerLiveTests
@Suite("Instant answer live", .enabled(if: ProcessInfo.processInfo.environment["WEB_SEARCH_LIVE"] == "1"))
struct InstantAnswerLiveTests {

    @Test("a recognized entity returns a usable abstract")
    func liveEntity() async throws {
        let service = DuckDuckGoInstantAnswerService()
        let answer = try await service.lookup(query: "Swift programming language")
        #expect(!answer.heading.isEmpty)
        #expect(answer.hasUsefulContent)
    }

    @Test("an open-ended query returns no useful content")
    func liveOpenEnded() async throws {
        let service = DuckDuckGoInstantAnswerService()
        let answer = try await service.lookup(query: "best laptop for swift development 2026 opinions")
        #expect(!answer.hasUsefulContent)
    }
}
