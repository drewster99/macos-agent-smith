import Testing
import Foundation
@testable import AgentSmithKit

/// Tests for `FileReadTool`. Covers happy-path text reads with `cat -n` line numbering,
/// `offset`/`limit` slicing, missing-file errors, path-restriction guard, and that
/// successful reads as Brown record the path with the file-read tracker (so subsequent
/// `file_write` calls on the same path are allowed).
@Suite("FileReadTool")
struct FileReadToolTests {

    @Test("reads a text file with cat -n line numbering")
    func readsTextWithLineNumbers() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let path = try dir.write("alpha\nbeta\ngamma\n", to: "fixture.txt")

        let result = try await FileReadTool().execute(
            arguments: ["path": .string(path)],
            context: TestToolContext.make()
        )

        #expect(result.succeeded)
        // cat -n format: 6-char right-justified line number, two spaces, content.
        #expect(result.output.contains("     1  alpha"))
        #expect(result.output.contains("     2  beta"))
        #expect(result.output.contains("     3  gamma"))
    }

    @Test("offset and limit slice the file")
    func offsetAndLimitSliceFile() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let body = (1...10).map { "line \($0)" }.joined(separator: "\n")
        let path = try dir.write(body, to: "fixture.txt")

        let result = try await FileReadTool().execute(
            arguments: [
                "path": .string(path),
                "startingLineNum": .int(3),
                "maxLines": .int(2)
            ],
            context: TestToolContext.make()
        )

        #expect(result.succeeded)
        #expect(result.output.contains("     3  line 3"))
        #expect(result.output.contains("     4  line 4"))
        #expect(!result.output.contains("line 5"))
        // Tail note that more remains.
        #expect(result.output.contains("[File has 10 total lines"))
    }

    @Test("startingLineNum past end of file returns failure")
    func startingLineNumPastEndIsFailure() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let path = try dir.write("only one line\n", to: "fixture.txt")

        let result = try await FileReadTool().execute(
            arguments: [
                "path": .string(path),
                "startingLineNum": .int(100)
            ],
            context: TestToolContext.make()
        )
        #expect(!result.succeeded)
        #expect(result.output.contains("startingLineNum"))
    }

    @Test("whole reads over five megabytes fail with line-window guidance")
    func wholeReadOverFiveMegabytesFails() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let path = try writeLargeLineFixture(in: dir)

        let result = try await FileReadTool().execute(
            arguments: ["path": .string(path)],
            context: TestToolContext.make()
        )

        #expect(!result.succeeded)
        #expect(result.output.contains("too large to read whole"))
        #expect(result.output.contains("startingLineNum"))
        #expect(result.output.contains("maxLines"))
    }

    @Test("line-window reads can select from files over five megabytes")
    func lineWindowReadOverFiveMegabytesSucceeds() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let path = try writeLargeLineFixture(in: dir)

        let result = try await FileReadTool().execute(
            arguments: [
                "path": .string(path),
                "startingLineNum": .int(5_500),
                "maxLines": .int(2)
            ],
            context: TestToolContext.make()
        )

        #expect(result.succeeded)
        #expect(result.output.contains("  5500  line-5500 "))
        #expect(result.output.contains("  5501  line-5501 "))
        #expect(!result.output.contains("line-5499"))
        #expect(!result.output.contains("line-5502"))
        #expect(result.output.contains("[File has 6000 total lines"))
    }

    @Test("missing file returns failure")
    func missingFileFailure() async throws {
        let result = try await FileReadTool().execute(
            arguments: ["path": .string("/tmp/agent-smith-tests/does-not-exist-\(UUID().uuidString).txt")],
            context: TestToolContext.make()
        )
        #expect(!result.succeeded)
    }

    @Test("blocks reads of ~/.ssh paths")
    func blocksSshReads() {
        let home = NSHomeDirectory()
        let blocked = (home as NSString).appendingPathComponent(".ssh/id_rsa")
        let result = FileReadTool.checkPathRestriction(blocked)
        #expect(result?.hasPrefix("BLOCKED") == true)
    }

    @Test("blocks /etc/master.passwd")
    func blocksSystemCredentials() {
        let result = FileReadTool.checkPathRestriction("/etc/master.passwd")
        #expect(result?.hasPrefix("BLOCKED") == true)
    }

    @Test("Brown's read records the path with the tracker")
    func brownReadRecordsPath() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let path = try dir.write("hi", to: "fixture.txt")

        let tracker = TestToolContext.FileReadTrackerStub()
        _ = try await FileReadTool().execute(
            arguments: ["path": .string(path)],
            context: TestToolContext.make(agentRole: .brown, fileReadTracker: tracker)
        )

        #expect(tracker.has(path))
    }

    @Test("Smith and Security Agent reads do not record (only Brown's reads gate file_write)")
    func nonBrownReadsDontRecord() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let path = try dir.write("hi", to: "fixture.txt")

        for role in [AgentRole.smith, .securityAgent] {
            let tracker = TestToolContext.FileReadTrackerStub()
            _ = try await FileReadTool().execute(
                arguments: ["path": .string(path)],
                context: TestToolContext.make(agentRole: role, fileReadTracker: tracker)
            )
            #expect(tracker.allRecorded.isEmpty, "role \(role) should not record reads")
        }
    }

    @Test("missing path argument throws")
    func missingPathArgumentThrows() async throws {
        do {
            _ = try await FileReadTool().execute(
                arguments: [:],
                context: TestToolContext.make()
            )
            Issue.record("expected throw")
        } catch ToolCallError.missingRequiredArgument(let name) {
            #expect(name == "path")
        }
    }

    // MARK: - normalizePath

    @Test("normalizePath leaves a clean absolute path alone")
    func normalizeCleanPath() {
        let raw = "/tmp/foo/bar.txt"
        #expect(FileReadTool.normalizePath(raw) == raw)
    }

    @Test("normalizePath strips file:// scheme")
    func normalizeFileScheme() {
        let raw = "file:///tmp/foo/bar.txt"
        #expect(FileReadTool.normalizePath(raw) == "/tmp/foo/bar.txt")
    }

    @Test("normalizePath percent-decodes spaces in file:// URLs")
    func normalizePercentDecode() {
        let raw = "file:///tmp/Foo%20Bar/baz%20qux.png"
        #expect(FileReadTool.normalizePath(raw) == "/tmp/Foo Bar/baz qux.png")
    }

    @Test("normalizePath un-shell-escapes spaces")
    func normalizeShellSpaces() {
        let raw = "/tmp/Foo\\ Bar/baz\\ qux.png"
        #expect(FileReadTool.normalizePath(raw) == "/tmp/Foo Bar/baz qux.png")
    }

    @Test("normalizePath handles parens and ampersand escapes")
    func normalizeShellSpecials() {
        let raw = "/tmp/foo\\(1\\)\\&bar"
        #expect(FileReadTool.normalizePath(raw) == "/tmp/foo(1)&bar")
    }

    @Test("normalizePath expands tilde")
    func normalizeTilde() {
        let raw = "~/foo.txt"
        let normalized = FileReadTool.normalizePath(raw)
        #expect(normalized.hasSuffix("/foo.txt"))
        #expect(!normalized.hasPrefix("~"))
    }

    @Test("normalizePath preserves backslash + non-special character")
    func normalizePreserveOtherEscapes() {
        // \n in a path is unusual but we shouldn't unescape it (newlines aren't valid
        // in macOS filenames anyway, but the principle is to only unescape known shell
        // specials).
        let raw = "/tmp/foo\\nbar"
        #expect(FileReadTool.normalizePath(raw) == "/tmp/foo\\nbar")
    }

    @Test("normalizePath handles file:// + percent-encoded + tilde combo")
    func normalizeCombo() {
        // Edge case: file:// scheme with percent-encoding. (We don't combine with
        // shell-escapes — no LLM produces both at once.)
        let raw = "file:///tmp/Application%20Support/foo%20bar.png"
        #expect(FileReadTool.normalizePath(raw) == "/tmp/Application Support/foo bar.png")
    }

    @Test("file_read accepts a file:// URL with percent-encoded spaces")
    func fileReadAcceptsFileURL() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let path = try dir.write("hello", to: "Foo Bar.txt")
        let fileURL = URL(fileURLWithPath: path).absoluteString  // file:///…/Foo%20Bar.txt
        let result = try await FileReadTool().execute(
            arguments: ["path": .string(fileURL)],
            context: TestToolContext.make()
        )
        #expect(result.succeeded)
        #expect(result.output.contains("hello"))
    }

    @Test("file_read accepts a shell-escaped path with literal backslash-space")
    func fileReadAcceptsShellEscapes() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let path = try dir.write("hello", to: "Foo Bar.txt")
        // Build the shell-escaped version: replace " " with "\\ "
        let shellEscaped = path.replacingOccurrences(of: " ", with: "\\ ")
        let result = try await FileReadTool().execute(
            arguments: ["path": .string(shellEscaped)],
            context: TestToolContext.make()
        )
        #expect(result.succeeded)
        #expect(result.output.contains("hello"))
    }

    @Test("a large file ending in a newline reports its real line count, with no phantom final line")
    func largeFileEndingInNewlineHasNoPhantomLine() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let path = try writeLargeLineFixture(in: dir, trailingNewline: true)

        let result = try await FileReadTool().execute(
            arguments: [
                "path": .string(path),
                "startingLineNum": .int(5_998),
                "maxLines": .int(10)
            ],
            context: TestToolContext.make()
        )

        #expect(result.succeeded)
        #expect(result.output.contains("  6000  line-6000"))
        // The file has exactly 6000 lines. Counting the empty remainder after the final
        // newline would report 6001 and emit a blank line 6001.
        #expect(!result.output.contains("6001"))
    }

    @Test("a line window past the end of a large file is refused, not answered with a blank line")
    func lineWindowPastEndOfLargeFileIsRefused() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let path = try writeLargeLineFixture(in: dir, trailingNewline: true)

        let result = try await FileReadTool().execute(
            arguments: [
                "path": .string(path),
                "startingLineNum": .int(6_001),
                "maxLines": .int(5)
            ],
            context: TestToolContext.make()
        )

        #expect(!result.succeeded)
        #expect(result.output.contains("beyond the end of the file"))
        #expect(result.output.contains("6000 lines"))
    }

    @Test("Extreme line arguments saturate instead of trapping")
    func extremeLineArgumentsDoNotTrap() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let small = try dir.write("alpha\nbravo\ncharlie\n", to: "small.txt")
        let large = try writeLargeLineFixture(in: dir, trailingNewline: true)

        // `startingLineNum` / `maxLines` arrive unbounded from LLM-emitted JSON. Overflow is a
        // TRAP, not a catchable error — before the saturating helper each of these killed the
        // process. Surviving the call IS the assertion; the outcomes are only sanity checks.
        let cases: [(path: String, start: Int, limit: Int?)] = [
            (small, 2, Int.max),          // the easiest kill: guard passes, then startIndex + limit
            (small, Int.max, nil),
            (small, Int.max, Int.max),
            (small, Int.min, Int.max),
            (large, Int.max, nil),        // >5MB path: default limit alone overflows
            (large, 1, Int.max),
            (large, Int.max, Int.max),
            (large, 2, Int.max)
        ]

        for testCase in cases {
            var arguments: [String: AnyCodable] = [
                "path": .string(testCase.path),
                "startingLineNum": .int(testCase.start)
            ]
            if let limit = testCase.limit { arguments["maxLines"] = .int(limit) }
            let result = try await FileReadTool().execute(arguments: arguments, context: TestToolContext.make())
            #expect(!result.output.isEmpty, "start=\(testCase.start) limit=\(String(describing: testCase.limit))")
        }
    }

    @Test("Truncated output stays contiguous — no line is skipped and silently backfilled")
    func truncatedOutputIsContiguous() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        // A giant middle line forces the budget to run out partway through the window. The old
        // code skipped it and kept appending later, shorter lines — yielding 1, 3, 4.
        let giant = String(repeating: "g", count: FileReadTool.maxCharacters + 1024)
        let body = "first\n\(giant)\nthird\nfourth\n"
        let path = try dir.write(body, to: "giantline.txt")

        let result = try await FileReadTool().execute(
            arguments: [
                "path": .string(path),
                "startingLineNum": .int(1),
                "maxLines": .int(10)
            ],
            context: TestToolContext.make()
        )

        #expect(result.succeeded)
        #expect(result.output.contains("     1  first"))
        #expect(!result.output.contains("third"), "a later short line must not backfill past the cut")
        #expect(!result.output.contains("fourth"))
        #expect(result.output.contains("after line 1"))
    }

    @Test("A single line wider than the output cap fails instead of succeeding empty")
    func oversizedSingleLineIsFailure() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let giant = String(repeating: "g", count: FileReadTool.maxCharacters + 1024)
        let path = try dir.write("\(giant)\nsecond\n", to: "oneline.txt")
        let tracker = TestToolContext.FileReadTrackerStub()

        let result = try await FileReadTool().execute(
            arguments: [
                "path": .string(path),
                "startingLineNum": .int(1),
                "maxLines": .int(1)
            ],
            context: TestToolContext.make(agentRole: .brown, fileReadTracker: tracker)
        )

        // Empty-but-successful would read to an agent as "the file is empty", and would also
        // satisfy the prior-read gate that file_edit checks.
        #expect(!result.succeeded)
        #expect(result.output.contains("output limit"))
    }

    private func writeLargeLineFixture(in dir: TempDir, trailingNewline: Bool = false) throws -> String {
        let filler = String(repeating: "x", count: 1024)
        var body = (1...6_000)
            .map { "line-\($0) \(filler)" }
            .joined(separator: "\n")
        if trailingNewline { body += "\n" }
        #expect(body.utf8.count > FileReadTool.maxCharacters)
        return try dir.write(body, to: "large.txt")
    }
}
