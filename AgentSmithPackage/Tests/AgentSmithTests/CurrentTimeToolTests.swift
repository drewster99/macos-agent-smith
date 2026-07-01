import Testing
import Foundation
@testable import AgentSmithKit

/// Tests for `CurrentTimeTool`. The tool returns "now" formatted in the user's locale and
/// timezone, so we can't pin the value — but the output shape (six labeled lines, ISO-8601
/// formatting, unix epoch parses as an integer) is fully assertable.
@Suite("CurrentTimeTool")
struct CurrentTimeToolTests {

    @Test("output has all six labeled lines in order")
    func outputShapeIsStable() async throws {
        let result = try await CurrentTimeTool().execute(
            arguments: [:],
            context: TestToolContext.make()
        )
        #expect(result.succeeded)

        let lines = result.output.components(separatedBy: "\n")
        #expect(lines.count == 6)
        #expect(lines[0].hasPrefix("local: "))
        #expect(lines[1].hasPrefix("utc: "))
        #expect(lines[2].hasPrefix("timezone: "))
        #expect(lines[3].hasPrefix("locale: "))
        #expect(lines[4].hasPrefix("human: "))
        #expect(lines[5].hasPrefix("unix_epoch_seconds: "))
    }

    @Test("local and utc lines are valid ISO-8601")
    func isoFormatParseable() async throws {
        let result = try await CurrentTimeTool().execute(
            arguments: [:],
            context: TestToolContext.make()
        )
        let lines = result.output.components(separatedBy: "\n")
        let local = String(lines[0].dropFirst("local: ".count))
        let utc = String(lines[1].dropFirst("utc: ".count))

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        #expect(formatter.date(from: local) != nil)
        #expect(formatter.date(from: utc) != nil)
    }

    @Test("unix_epoch_seconds is a parseable integer near now")
    func unixEpochIsRecent() async throws {
        let before = Int(Date().timeIntervalSince1970)
        let result = try await CurrentTimeTool().execute(
            arguments: [:],
            context: TestToolContext.make()
        )
        let after = Int(Date().timeIntervalSince1970)

        let lines = result.output.components(separatedBy: "\n")
        let epochStr = String(lines[5].dropFirst("unix_epoch_seconds: ".count))
        let epoch = try #require(Int(epochStr))
        #expect(epoch >= before && epoch <= after)
    }

    @Test("timezone line includes UTC offset in ±HH:MM form")
    func timezoneLineHasOffset() async throws {
        let result = try await CurrentTimeTool().execute(
            arguments: [:],
            context: TestToolContext.make()
        )
        let lines = result.output.components(separatedBy: "\n")
        // e.g. "timezone: America/Los_Angeles (PST, UTC-08:00)"
        #expect(lines[2].contains("UTC"))
        // The offset substring contains a sign and a colon-separated H:M.
        let regex = try NSRegularExpression(pattern: "UTC[+-]\\d{2}:\\d{2}")
        let range = NSRange(lines[2].startIndex..<lines[2].endIndex, in: lines[2])
        #expect(regex.firstMatch(in: lines[2], range: range) != nil)
    }

    @Test("availability: smith and brown only")
    func availability() {
        let tool = CurrentTimeTool()
        for role in [AgentRole.smith, .brown] {
            #expect(tool.isAvailable(in: ToolAvailabilityContext(agentRole: role)))
        }
        #expect(!tool.isAvailable(in: ToolAvailabilityContext(agentRole: .securityAgent)))
    }
}
