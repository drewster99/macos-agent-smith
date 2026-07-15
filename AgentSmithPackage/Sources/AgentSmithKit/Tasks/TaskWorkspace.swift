import Foundation

/// The two on-disk working directories a task gets. Both are created lazily.
///
/// - `temporaryDirectory` — ephemeral scratch under the OS temp dir. NOT persisted; the system may
///   purge it (it survives until reboot, unlike a Caches dir which can be evicted anytime). For
///   throwaway intermediates a task doesn't need to keep.
/// - `evidenceDirectory` — persistent, session-scoped, lives with the task's other data and
///   survives relaunch. The sanctioned place for acceptance-criteria evidence artifacts; files
///   written here are auto-ingested as attachments so they resolve as clickable references. `nil`
///   when no workspace root is configured — then only the temp dir is available.
///
/// Giving agents these two named locations keeps evidence and scratch out of the user's own
/// project tree (where the worker used to litter markdown and screenshots).
public struct TaskWorkspace: Sendable {
    public let taskID: UUID
    /// The session directory. Evidence lives under `<root>/tasks/<taskID>/evidence`.
    public let workspaceRoot: URL?

    public init(taskID: UUID, workspaceRoot: URL?) {
        self.taskID = taskID
        self.workspaceRoot = workspaceRoot
    }

    public var temporaryDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSmith", isDirectory: true)
            .appendingPathComponent("tasks", isDirectory: true)
            .appendingPathComponent(taskID.uuidString, isDirectory: true)
    }

    public var evidenceDirectory: URL? {
        workspaceRoot?
            .appendingPathComponent("tasks", isDirectory: true)
            .appendingPathComponent(taskID.uuidString, isDirectory: true)
            .appendingPathComponent("evidence", isDirectory: true)
    }

    /// The `<root>/tasks/<taskID>` directory that holds the evidence dir — removed wholesale on
    /// hard task deletion. `nil` when no workspace root is configured.
    public var persistentTaskDirectory: URL? {
        workspaceRoot?
            .appendingPathComponent("tasks", isDirectory: true)
            .appendingPathComponent(taskID.uuidString, isDirectory: true)
    }

    /// Whether `resolvedPath` (already symlink-resolved) is inside `directory`. Boundary-aware so
    /// `/x/evidence-backup` is not treated as inside `/x/evidence`.
    public static func path(_ resolvedPath: String, isInside directory: URL) -> Bool {
        let root = directory.resolvingSymlinksInPath().path
        return resolvedPath == root || resolvedPath.hasPrefix(root + "/")
    }

    /// Creates both directories (best-effort). Safe to call repeatedly.
    public func ensureDirectories() {
        try? FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        if let evidenceDirectory {
            try? FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        }
    }

    /// Removes the ephemeral temp dir (best-effort). The evidence dir is persistent and is NOT
    /// removed here — only on hard task deletion via `cleanupAll()`.
    public func cleanupTemporary() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    /// Removes BOTH the temp dir and the persistent task dir — for hard task deletion only.
    public func cleanupAll() {
        cleanupTemporary()
        if let persistentTaskDirectory {
            try? FileManager.default.removeItem(at: persistentTaskDirectory)
        }
    }
}
