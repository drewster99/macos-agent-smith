import Testing
import Foundation
@testable import AgentSmithKit

/// Tests for `FileEditTool`. Covers the read-before-edit gate, single-occurrence
/// replacement (default), the must-be-unique guard, the `replace_all` opt-in, the
/// no-match failure, and the `old_string == new_string` rejection. Path restrictions
/// delegate to `FileWriteTool.checkPathRestriction`, which has its own test coverage.
@Suite("FileEditTool")
struct FileEditToolTests {

    /// Builds a Brown tool context with `path` already pre-recorded as read, so the
    /// edit-gate doesn't reject the test before exercising the behavior under test.
    private func contextThatHasRead(_ path: String) -> ToolContext {
        let tracker = TestToolContext.FileReadTrackerStub()
        tracker.record(path)
        return TestToolContext.make(agentRole: .brown, fileReadTracker: tracker)
    }

    @Test("rejects edit when file_read was not called first")
    func rejectsUnreadFile() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let path = try dir.write("alpha beta gamma\n", to: "f.txt")

        let result = try await FileEditTool().execute(
            arguments: [
                "file_path": .string(path),
                "old_string": .string("beta"),
                "new_string": .string("BETA")
            ],
            context: TestToolContext.make(agentRole: .brown)
        )
        #expect(!result.succeeded)
        #expect(result.output.contains("requires a prior file_read"))
        let written = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        #expect(written == "alpha beta gamma\n", "file should be untouched on gate rejection")
    }

    @Test("replaces a single unique occurrence")
    func replacesSingleOccurrence() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let path = try dir.write("alpha beta gamma\n", to: "f.txt")

        let result = try await FileEditTool().execute(
            arguments: [
                "file_path": .string(path),
                "old_string": .string("beta"),
                "new_string": .string("BETA")
            ],
            context: contextThatHasRead(path)
        )
        #expect(result.succeeded)
        #expect(result.output.contains("Successfully replaced 1"))
        let written = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        #expect(written == "alpha BETA gamma\n")
    }

    @Test("file_edit matches a prior file_read recorded under a file:// spelling")
    func matchesNormalizedPriorRead() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let path = try dir.write("alpha beta gamma\n", to: "f.txt")

        // The read tracker recorded the file under a `file://` URL spelling; an edit that
        // passes the plain path must still satisfy the read-before-edit gate.
        let tracker = TestToolContext.FileReadTrackerStub()
        tracker.record("file://\(path)")
        let result = try await FileEditTool().execute(
            arguments: [
                "file_path": .string(path),
                "old_string": .string("beta"),
                "new_string": .string("BETA")
            ],
            context: TestToolContext.make(agentRole: .brown, fileReadTracker: tracker)
        )
        #expect(result.succeeded)
        let written = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        #expect(written == "alpha BETA gamma\n")
    }

    @Test("non-unique old_string without replace_all returns failure")
    func nonUniqueWithoutReplaceAllFails() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let path = try dir.write("foo foo foo\n", to: "f.txt")

        let result = try await FileEditTool().execute(
            arguments: [
                "file_path": .string(path),
                "old_string": .string("foo"),
                "new_string": .string("bar")
            ],
            context: contextThatHasRead(path)
        )
        #expect(!result.succeeded)
        #expect(result.output.contains("appears 3 times"))
        let written = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        #expect(written == "foo foo foo\n", "file should be untouched on failure")
    }

    @Test("replace_all replaces every occurrence")
    func replaceAllReplacesEvery() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let path = try dir.write("foo foo foo\n", to: "f.txt")

        let result = try await FileEditTool().execute(
            arguments: [
                "file_path": .string(path),
                "old_string": .string("foo"),
                "new_string": .string("bar"),
                "replace_all": .bool(true)
            ],
            context: contextThatHasRead(path)
        )
        #expect(result.succeeded)
        #expect(result.output.contains("Successfully replaced 3 occurrences"))
        let written = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        #expect(written == "bar bar bar\n")
    }

    @Test("old_string not found returns failure")
    func oldStringNotFoundFails() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let path = try dir.write("nothing matches here\n", to: "f.txt")

        let result = try await FileEditTool().execute(
            arguments: [
                "file_path": .string(path),
                "old_string": .string("missing"),
                "new_string": .string("ignored")
            ],
            context: contextThatHasRead(path)
        )
        #expect(!result.succeeded)
        #expect(result.output.contains("not found"))
    }

    @Test("identical old_string and new_string returns failure")
    func identicalStringsFail() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let path = try dir.write("anything\n", to: "f.txt")

        let result = try await FileEditTool().execute(
            arguments: [
                "file_path": .string(path),
                "old_string": .string("anything"),
                "new_string": .string("anything")
            ],
            context: contextThatHasRead(path)
        )
        #expect(!result.succeeded)
        #expect(result.output.contains("identical"))
    }

    @Test("missing file returns failure")
    func missingFileFails() async throws {
        let path = "/tmp/agent-smith-tests/missing-\(UUID().uuidString).txt"
        let result = try await FileEditTool().execute(
            arguments: [
                "file_path": .string(path),
                "old_string": .string("a"),
                "new_string": .string("b")
            ],
            context: contextThatHasRead(path)
        )
        #expect(!result.succeeded)
        #expect(result.output.contains("does not exist"))
    }

    @Test("relative file_path is rejected")
    func relativePathRejected() async throws {
        let result = try await FileEditTool().execute(
            arguments: [
                "file_path": .string("relative/path.txt"),
                "old_string": .string("a"),
                "new_string": .string("b")
            ],
            context: TestToolContext.make(agentRole: .brown)
        )
        #expect(!result.succeeded)
        #expect(result.output.contains("absolute"))
    }
}
