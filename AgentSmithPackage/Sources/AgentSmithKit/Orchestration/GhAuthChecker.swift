import Foundation

/// Runs `gh auth status` once at Brown spawn time so Brown's `gh` tool description can include
/// the verified auth state. Brown has historically refused GitHub work claiming "I don't have
/// access" or "I'm not authenticated" even when `gh` was logged in — surfacing the actual auth
/// output in the tool description short-circuits that confusion.
///
/// Stdin is redirected from `/dev/null` so any login-shell hook that tries to prompt
/// interactively (1Password CLI's `op signin`, keychain unlock, GUI askpass shims) gets EOF
/// immediately and bails out instead of blocking until our 30s timeout fires. `ProcessRunner`
/// already nulls stdin at the FileHandle level, but the `</dev/null` redirection inside the
/// `bash -lc` invocation belts-and-suspenders the same protection through the shell's own
/// rc-file processing.
///
/// The checker is an actor with a TTL cache so back-to-back Brown spawns don't each pay the
/// 30s upper-bound latency of `gh auth status`. The default TTL is four hours — long enough
/// to amortize the cost across a typical work session, short enough that auth changes are
/// reflected within the same day. Callers can force a refresh via `invalidate()`.
actor GhAuthChecker {
    /// How long a cached snapshot is considered fresh. Four hours covers a typical
    /// session of back-to-back tasks while keeping auth state from going stale across days.
    private static let cacheTTL: TimeInterval = 4 * 60 * 60

    /// Process-wide shared instance. Constructed lazily; the actor isolation makes the
    /// shared cache safe to read/write from concurrent Brown spawns.
    static let shared = GhAuthChecker()

    private var cachedSnapshot: String?
    private var cachedAt: Date?

    public init() {}

    /// Returns the current `gh auth status` snapshot, using the cached value if it is
    /// younger than `cacheTTL`. Otherwise re-runs `gh auth status` and caches the result.
    /// Always returns a string — runtime errors and timeouts produce a human-readable
    /// fallback instead of throwing, so the tool description always has *something* to show.
    public func authStatus() async -> String {
        if let snapshot = cachedSnapshot, let cachedAt,
           Date().timeIntervalSince(cachedAt) < Self.cacheTTL {
            return snapshot
        }
        let fresh = await runGhAuthStatus()
        cachedSnapshot = fresh
        cachedAt = Date()
        return fresh
    }

    /// Forces the next `authStatus()` call to re-run `gh auth status` instead of returning
    /// a cached value. Intended for the future stale-snapshot recovery path: when a `gh`
    /// tool call exits with auth-failure-shaped output, the tool can call this so the next
    /// Brown spawn picks up reality.
    public func invalidate() {
        cachedSnapshot = nil
        cachedAt = nil
    }

    /// Module-static convenience that delegates to `shared.authStatus()`. Preserves the
    /// pre-cache call sites (`await GhAuthChecker.authStatus()`) without making them
    /// reach into the actor explicitly.
    public static func authStatus() async -> String {
        await shared.authStatus()
    }

    /// Module-static convenience for `shared.invalidate()`.
    public static func invalidate() async {
        await shared.invalidate()
    }

    private func runGhAuthStatus() async -> String {
        do {
            let result = try await ProcessRunner.run(
                executable: "/bin/bash",
                arguments: ["-l", "-c", "gh auth status </dev/null"],
                workingDirectory: nil,
                timeout: 30
            )
            if result.timedOut {
                return "Could not capture `gh auth status` (timed out after 30s)."
            }
            if result.output.isEmpty {
                return "Could not capture `gh auth status` (no output, exit \(result.exitCode))."
            }
            return result.output
        } catch {
            return "Could not run `gh auth status`: \(error.localizedDescription). The `gh` tool may still work if `gh` is on PATH; treat absence of output as inconclusive, not as a failure."
        }
    }
}
