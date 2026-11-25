import Foundation

/// Where one owner's oversized tool results are kept, and the only reader and writer of them.
///
/// A result too large for a model's context is "spilled": `ToolResultCap` keeps a preview inline and
/// saves the full text here. The agent reads it back BY HANDLE through `read_tool_output`, never by
/// path — a path would make reading the app's own saved output a filesystem read, judged against
/// the task's path rules (on 2026-11-24 the Security Agent correctly aborted a worker for exactly
/// that).
///
/// Each task has its own folder, so nothing one task saved is reachable from another. See
/// `docs/plans/SpilledToolOutputByHandle.md`.
struct SpilledToolOutputStore: Sendable, Equatable {
    /// Under the OS temp dir: saved output is only useful while its conversation is alive, and the
    /// operating system clears whatever the app does not.
    static let rootDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgentSmith-tool-output", isDirectory: true)

    /// The folder holding this owner's saved output. Created on the first save.
    let directory: URL

    /// The store shared by a task's worker and that task's validators.
    static func forTask(_ taskID: UUID, under root: URL = rootDirectory) -> SpilledToolOutputStore {
        SpilledToolOutputStore(directory: root.appendingPathComponent(taskID.uuidString, isDirectory: true))
    }

    /// The store of an agent that is bound to no task (Smith).
    static func forAgent(_ agentID: UUID, under root: URL = rootDirectory) -> SpilledToolOutputStore {
        SpilledToolOutputStore(directory: root.appendingPathComponent("agent-\(agentID.uuidString)", isDirectory: true))
    }

    /// Saves `output` and returns the handle that reads it back.
    func save(_ output: String) throws -> UUID {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let handle = UUID()
        try output.write(to: fileURL(forHandle: handle), atomically: true, encoding: .utf8)
        return handle
    }

    /// The saved output for `handle`, or nil when this owner has none under that handle — never
    /// saved here, or already cleared.
    func output(forHandle handle: UUID) throws -> String? {
        let fileURL = fileURL(forHandle: handle)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    /// Removes everything this owner saved. Not an error when nothing was ever saved.
    func removeAll() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    /// Built from the parsed UUID, never from caller text, so a handle cannot name another path.
    func fileURL(forHandle handle: UUID) -> URL {
        directory.appendingPathComponent("tool-output-\(handle.uuidString).txt")
    }
}
