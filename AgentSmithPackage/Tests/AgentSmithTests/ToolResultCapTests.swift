import Foundation
import Testing
@testable import AgentSmithKit

/// `ToolResultCap` caps every tool result entering an agent's or validator's context (#22): a result
/// that fits passes through untouched; one that doesn't keeps a head preview inline and spills the
/// FULL text to a file the reader pages through.
@Suite("ToolResultCap")
struct ToolResultCapTests {
    /// The overflow file a capped result names.
    private static func overflowPath(in capped: String) throws -> String {
        let line = try #require(capped.split(separator: "\n").first { $0.hasPrefix("/") && $0.hasSuffix(".txt") })
        return String(line)
    }

    /// Runs `body` with a fresh overflow directory and removes it after — never the shared one the
    /// running app also uses.
    private static func withOverflowDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tool-result-cap-tests-\(UUID().uuidString)", isDirectory: true)
        defer {
            do {
                if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
            } catch {
                Issue.record("could not remove \(directory.path): \(error)")
            }
        }
        try body(directory)
    }

    @Test("A result at or under the limit is returned unchanged, including exactly at it")
    func underLimitUnchanged() throws {
        try Self.withOverflowDirectory { directory in
            for text in ["", "short", String(repeating: "a", count: ToolResultCap.maxCharacters)] {
                #expect(ToolResultCap.cap(text, overflowingInto: directory) == text)
            }
            #expect(!FileManager.default.fileExists(atPath: directory.path), "nothing fits, nothing is written")
        }
    }

    @Test("One character over: a head preview inline, and the byte-identical original in an overflow file")
    func oneOverOverflows() throws {
        try Self.withOverflowDirectory { directory in
            let original = String(repeating: "abcdefghij", count: ToolResultCap.maxCharacters / 10) + "Z"
            #expect(original.count == ToolResultCap.maxCharacters + 1)
            let capped = ToolResultCap.cap(original, overflowingInto: directory)

            #expect(capped.hasPrefix("[HEAD PREVIEW"))
            #expect(capped.contains(String(original.prefix(ToolResultCap.previewCharacters))))
            #expect(!capped.contains(String(original.prefix(ToolResultCap.previewCharacters + 1))), "the preview is exactly the head")
            let path = try Self.overflowPath(in: capped)
            #expect(path.hasPrefix(directory.path))
            let saved = try String(contentsOfFile: path, encoding: .utf8)
            #expect(saved == original)
        }
    }

    @Test("Multibyte text: the preview never splits a grapheme, and the file round-trips exactly")
    func multibyte() throws {
        try Self.withOverflowDirectory { directory in
            // Each 👨‍👩‍👧‍👦 is one Character of seven scalars; a split would leave a broken one in the preview.
            let original = String(repeating: "👨‍👩‍👧‍👦漢字", count: ToolResultCap.maxCharacters / 3 + 1)
            let capped = ToolResultCap.cap(original, overflowingInto: directory)
            #expect(capped.contains(String(original.prefix(ToolResultCap.previewCharacters))))
            let saved = try String(contentsOfFile: try Self.overflowPath(in: capped), encoding: .utf8)
            #expect(saved == original)
        }
    }

    @Test("Two overflows go to two distinct files")
    func distinctFiles() throws {
        try Self.withOverflowDirectory { directory in
            let text = String(repeating: "x", count: ToolResultCap.maxCharacters + 10)
            let first = try Self.overflowPath(in: ToolResultCap.cap(text, overflowingInto: directory))
            let second = try Self.overflowPath(in: ToolResultCap.cap(text, overflowingInto: directory))
            #expect(first != second)
            let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(files.count == 2)
        }
    }

    @Test("When the overflow can't be written, the preview says so and how much was omitted")
    func writeFailureFallback() throws {
        try Self.withOverflowDirectory { directory in
            // A regular FILE where the directory should be: creating the directory fails.
            try "not a directory".write(to: directory, atomically: true, encoding: .utf8)
            let text = String(repeating: "y", count: ToolResultCap.maxCharacters + 500)
            let capped = ToolResultCap.cap(text, overflowingInto: directory)
            #expect(capped.hasPrefix(String(text.prefix(ToolResultCap.previewCharacters))))
            #expect(capped.contains("could not be saved"))
            #expect(capped.contains("\(text.count - ToolResultCap.previewCharacters) characters omitted"))
        }
    }
}
