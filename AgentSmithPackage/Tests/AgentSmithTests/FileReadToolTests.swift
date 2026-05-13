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
                "offset": .int(3),
                "limit": .int(2)
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

    @Test("offset past end of file returns failure")
    func offsetPastEndIsFailure() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let path = try dir.write("only one line\n", to: "fixture.txt")

        let result = try await FileReadTool().execute(
            arguments: [
                "path": .string(path),
                "offset": .int(100)
            ],
            context: TestToolContext.make()
        )
        #expect(!result.succeeded)
        #expect(result.output.contains("offset"))
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

    @Test("Smith and Jones reads do not record (only Brown's reads gate file_write)")
    func nonBrownReadsDontRecord() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let path = try dir.write("hi", to: "fixture.txt")

        for role in [AgentRole.smith, .jones] {
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
}
