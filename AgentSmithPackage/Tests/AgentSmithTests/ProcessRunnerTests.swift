import Testing
import Foundation
@testable import AgentSmithKit

/// Covers the `posix_spawn`-based ProcessRunner: basic execution, working directory, exit codes,
/// timeout, output preservation, and — the reason for the rewrite — that a timeout kills the whole
/// process GROUP, so a backgrounded child can't leak past the timeout.
@Suite("ProcessRunner", .serialized)
struct ProcessRunnerTests {

    private func bash(_ command: String, workingDirectory: String? = nil, timeout: TimeInterval = 10) async throws -> ProcessRunner.Result {
        try await ProcessRunner.run(
            executable: "/bin/bash",
            arguments: ["-c", command],
            workingDirectory: workingDirectory,
            timeout: timeout
        )
    }

    @Test("captures stdout and a zero exit code")
    func basicOutput() async throws {
        let result = try await bash("echo hello world")
        #expect(result.output == "hello world\n")
        #expect(result.exitCode == 0)
        #expect(result.timedOut == false)
    }

    @Test("merges stderr into the output")
    func stderrMerged() async throws {
        let result = try await bash("echo out; echo err 1>&2")
        #expect(result.output.contains("out"))
        #expect(result.output.contains("err"))
    }

    @Test("a discarded stderr leaves the output exactly what the command wrote to stdout")
    func stderrDiscarded() async throws {
        let result = try await ProcessRunner.run(
            executable: "/bin/bash", arguments: ["-c", "echo out; echo err 1>&2; exit 3"],
            workingDirectory: nil, timeout: 10, standardError: .discarded
        )
        #expect(result.output == "out\n")
        #expect(result.exitCode == 3)
    }

    @Test("output that isn't UTF-8 is flagged, so a parser never reads the placeholder text")
    func nonUTF8Flagged() async throws {
        let bad = try await bash("printf '\\xff\\xfe'")
        #expect(!bad.outputIsUTF8)
        let good = try await bash("echo ok")
        #expect(good.outputIsUTF8)
    }

    @Test("reports a non-zero exit code")
    func nonZeroExit() async throws {
        let result = try await bash("exit 7")
        #expect(result.exitCode == 7)
        #expect(result.timedOut == false)
    }

    @Test("a signal-terminated command reports 128 + signal")
    func signalExit() async throws {
        // The shell kills itself with SIGKILL (9) → 128 + 9 = 137.
        let result = try await bash("kill -9 $$")
        #expect(result.exitCode == 137)
    }

    @Test("runs in the requested working directory")
    func workingDirectory() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pr-wd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = try await bash("pwd", workingDirectory: dir.path)
        // /tmp is a symlink to /private/tmp on macOS, so compare the resolved suffix.
        #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(dir.lastPathComponent))
    }

    @Test("times out and flags it")
    func timesOut() async throws {
        let result = try await bash("sleep 10", timeout: 0.5)
        #expect(result.timedOut)
    }

    @Test("preserves output produced before a timeout")
    func outputBeforeTimeout() async throws {
        let result = try await bash("echo early; sleep 10", timeout: 0.7)
        #expect(result.timedOut)
        #expect(result.output.contains("early"))
    }

    /// The core of the rewrite: a shell that backgrounds a child and waits. On timeout, the whole
    /// group is killed, so the child dies too and never touches its marker. The old single-pid
    /// kill would have reaped only the shell, orphaning the child, which would then create the
    /// marker — this test would fail.
    @Test("timeout kills the whole process group, not just the shell")
    func timeoutKillsProcessGroup() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("pr-pgtest-\(UUID().uuidString).marker")
        try? FileManager.default.removeItem(at: marker)
        defer { try? FileManager.default.removeItem(at: marker) }

        let result = try await bash("(sleep 2; touch '\(marker.path)') & wait", timeout: 0.7)
        #expect(result.timedOut)

        // Wait past when the child WOULD have created the marker (2s) if it had survived.
        try await Task.sleep(for: .seconds(3))
        #expect(
            FileManager.default.fileExists(atPath: marker.path) == false,
            "backgrounded child survived the timeout — the process group wasn't killed"
        )
    }
}
