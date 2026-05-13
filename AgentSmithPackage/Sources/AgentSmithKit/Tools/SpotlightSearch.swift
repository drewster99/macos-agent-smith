import Foundation

/// Thin wrapper over `mdfind` (the Spotlight CLI) for filename-style queries scoped to a directory.
///
/// `mdfind`-via-`ProcessRunner` rather than `MDQuery` (CoreServices) directly: the plan considered
/// `MDQuery` for its main win — getting `kMDItemPath` + mod-date straight off each indexed item
/// with no per-result `stat`. But the Spotlight index can be stale, so `glob` `stat`-validates
/// every Spotlight hit anyway (existence + true mtime). That negates the `stat`-elimination win,
/// leaving only "no subprocess spawn" (~5–10 ms) against the real cost of hand-rolling the
/// CoreServices C API (manual `CFRelease`/`Unmanaged`, the synchronous-execute-on-detached-task +
/// `MDQueryStop` cancellation dance). `ProcessRunner` is already battle-tested for exactly this
/// shape (timeout + process-group kill + cooperative cancellation), so we reuse it. Swapping in
/// `MDQuery` later is a single-file change behind this façade.
enum SpotlightSearch {

    /// Result of a Spotlight query attempt.
    enum Outcome: Sendable {
        /// `mdfind` ran successfully — `paths` holds the matched absolute paths (may be empty).
        case ok([String])
        /// Spotlight is unavailable for this query: `mdfind` exited non-zero, timed out, was
        /// cancelled, or the scope directory doesn't exist. Caller should fall back to a walk.
        case unavailable
    }

    /// Runs `mdfind -0 -onlyin <scope> <nameQuery>` and returns its parsed result.
    ///
    /// `nameQuery` is the raw Spotlight query string, e.g. `kMDItemFSName == "*.swift"` or
    /// `kMDItemFSName == "*.ts" || kMDItemFSName == "*.tsx"`. It is passed as a single argv element
    /// — `ProcessRunner` doesn't go through a shell, so no quoting headaches.
    ///
    /// `-0` makes `mdfind` print NUL-separated paths, robust against the (rare but legal) case of a
    /// path containing a literal newline.
    static func run(scope: String, nameQuery: String, timeoutSeconds: Int) async -> Outcome {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: scope, isDirectory: &isDir), isDir.boolValue else {
            return .unavailable
        }
        let bounded = max(1, min(timeoutSeconds, 60))
        let result: ProcessRunner.Result
        do {
            result = try await ProcessRunner.run(
                executable: "/usr/bin/mdfind",
                arguments: ["-0", "-onlyin", scope, nameQuery],
                workingDirectory: nil,
                timeout: TimeInterval(bounded)
            )
        } catch {
            return .unavailable
        }
        guard !result.timedOut, result.exitCode == 0 else { return .unavailable }
        let paths = result.output
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map(String.init)
        return .ok(paths)
    }
}
