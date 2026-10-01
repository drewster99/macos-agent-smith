import Foundation
import Testing
@testable import AgentSmithKit

@Suite struct GrepToolNumericCapTests {
    @Test func hugeFiniteCapsDoNotTrap() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("Fixture cleanup failed: \(error)") }
        }
        let file = directory.appendingPathComponent("match.txt")
        try "needle\n".write(to: file, atomically: true, encoding: .utf8)
        for key in ["max_file_count", "max_line_count", "max_file_size_mb"] {
            for value in [AnyCodable.double(1e300), .int(Int.max)] {
                let result = try await GrepTool().execute(
                    arguments: ["pattern": .string("needle"), "path": .string(file.path), key: value],
                    context: TestToolContext.make())
                #expect(result.succeeded)
            }
        }
    }

    @Test func nonFiniteCapsAreRejected() async throws {
        for key in ["max_file_count", "max_line_count", "max_file_size_mb"] {
            for value in [Double.nan, .infinity, -.infinity] {
                let result = try await GrepTool().execute(
                    arguments: ["pattern": .string("."), "path": .string("/tmp"), key: .double(value)],
                    context: TestToolContext.make())
                #expect(!result.succeeded)
            }
        }
    }

    @Test func capsClampBeforeConversion() {
        for ceiling in [GrepTool.hardMaxFileMatches, GrepTool.hardMaxContentLines, GrepTool.hardMaxFileSizeMB] {
            for value in [AnyCodable.double(1e300), .int(Int.max), .int(ceiling + 1)] {
                #expect(GrepTool.positiveInt(value, or: 16, ceiling: ceiling) == ceiling)
            }
            #expect(GrepTool.positiveInt(.int(ceiling), or: 16, ceiling: ceiling) == ceiling)
            #expect(GrepTool.positiveInt(.double(Double(ceiling)), or: 16, ceiling: ceiling) == ceiling)
            #expect(GrepTool.positiveInt(.double(-1e300), or: 16, ceiling: ceiling) == 1)
            #expect(GrepTool.positiveInt(.int(Int.min), or: 16, ceiling: ceiling) == 1)
            #expect(GrepTool.positiveInt(.double(3.9), or: 16, ceiling: ceiling) == 3)
            #expect(GrepTool.positiveInt(.double(0.5), or: 16, ceiling: ceiling) == 1)
            #expect(GrepTool.positiveInt(.int(0), or: 16, ceiling: ceiling) == 1)
            #expect(GrepTool.positiveInt(nil, or: 16, ceiling: ceiling) == 16)
            #expect(GrepTool.positiveInt(.string(""), or: 16, ceiling: ceiling) == 16)
            for value in [Double.nan, .infinity, -.infinity] {
                #expect(GrepTool.positiveInt(.double(value), or: 16, ceiling: ceiling) == nil)
            }
        }
    }
}
