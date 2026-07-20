import Foundation
import SemanticSearch
@testable import AgentSmithKit

/// Test helpers for building a `ToolContext` without spinning up the full orchestration
/// runtime. Wave-1 tool tests (Glob/Grep/CurrentTime/FileRead/FileWrite/FileEdit) only
/// touch a handful of fields on `ToolContext`; this factory wires sensible stubs for the
/// rest so each test sets only what it cares about.
///
/// `MemoryStore` is constructed with a default `SemanticSearchEngine`, which is cheap —
/// the engine doesn't load MLX weights until `prepare()` or `embed()` is invoked, and
/// none of the wave-1 tools touch `memoryStore`.
enum TestToolContext {
    /// Captures mutations to the file-read tracker so tests can assert on what got recorded.
    /// Uses an unsynchronized backing store wrapped in an `NSLock` because Swift's actor
    /// model would force every read site to be `await`, defeating the value of a synchronous
    /// `hasFileBeenRead` callback shape.
    final class FileReadTrackerStub: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: Set<String> = []

        var allRecorded: Set<String> {
            lock.lock(); defer { lock.unlock() }
            return paths
        }

        func record(_ path: String) {
            lock.lock(); defer { lock.unlock() }
            paths.insert(PathNormalization.normalize(path))
        }

        func has(_ path: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return paths.contains(PathNormalization.normalize(path))
        }
    }

    /// Builds a `ToolContext` with sane stubs for every closure. Override only what your test
    /// needs by passing a custom `taskStore`, `channel`, or `fileReadTracker`.
    ///
    /// Note: `setToolExecutionStatus`, `hasToolSucceeded`, and `hasToolFailed` are wired to
    /// no-op stubs (returning `false` for the boolean queries) — the production defaults
    /// `assertionFailure(...)` (then degrade to `false`) to surface unwired callers, but
    /// tests of pure-logic tools don't exercise that path. If you're testing a tool that
    /// does, supply real closures.
    static func make(
        agentID: UUID = UUID(),
        agentRole: AgentRole = .brown,
        channel: MessageChannel = MessageChannel(),
        taskStore: TaskStore = TaskStore(),
        currentConfiguration: ModelConfiguration? = nil,
        currentProviderType: String? = nil,
        fileReadTracker: FileReadTrackerStub = FileReadTrackerStub(),
        memoryStore: MemoryStore = MemoryStore(engine: SemanticSearchEngine()),
        extractWebContent: @escaping @Sendable (String, String) async -> String? = { _, _ in nil },
        attachmentResolver: @escaping @Sendable ([String]) async -> (resolved: [Attachment], rejected: [String]) = { ids in ([], ids) },
        attachmentIngestor: @escaping @Sendable (String) async -> (attachment: Attachment?, error: String?) = { _ in (nil, "ingest not configured in test") },
        attachmentDataIngestor: @escaping @Sendable (Data, String, String) async -> (attachment: Attachment?, error: String?) = { data, filename, mimeType in
            (Attachment(filename: filename, mimeType: mimeType, byteCount: data.count, data: data), nil)
        },
        stagedAttachmentRecorder: StagedAttachmentRecorder = StagedAttachmentRecorder(),
        maxAttachmentBytesPerMessage: Int = 50 * 1024 * 1024,
        taskEvidenceDirectory: URL? = nil,
        loadEvaluatorRegistry: @escaping @Sendable () async -> EvaluatorRegistry? = { nil }
    ) -> ToolContext {
        ToolContext(
            agentID: agentID,
            agentRole: agentRole,
            channel: channel,
            taskStore: taskStore,
            currentConfiguration: currentConfiguration,
            currentProviderType: currentProviderType,
            spawnBrown: { nil },
            terminateAgent: { _, _ in false },
            abort: { _, _ in },
            agentRoleForID: { _ in nil },
            loadEvaluatorRegistry: loadEvaluatorRegistry,
            memoryStore: memoryStore,
            extractWebContent: extractWebContent,
            recordFileRead: { path in fileReadTracker.record(path) },
            hasFileBeenRead: { path in fileReadTracker.has(path) },
            setToolExecutionStatus: { _, _ in },
            hasToolSucceeded: { _ in false },
            hasToolFailed: { _ in false },
            resolveAttachments: attachmentResolver,
            ingestAttachmentFile: attachmentIngestor,
            ingestAttachmentData: attachmentDataIngestor,
            stageAttachmentsForNextTurn: { attachments, detail in
                await stagedAttachmentRecorder.record(attachments: attachments, detail: detail)
            },
            taskEvidenceDirectory: taskEvidenceDirectory,
            maxAttachmentBytesPerMessage: { maxAttachmentBytesPerMessage }
        )
    }

    /// Captures attach_file staging requests so tests can assert on them.
    final class StagedAttachmentRecorder: Sendable {
        private let lock = NSLock()
        nonisolated(unsafe) private var entries: [(attachments: [Attachment], detail: String)] = []

        func record(attachments: [Attachment], detail: String) {
            lock.lock(); defer { lock.unlock() }
            entries.append((attachments, detail))
        }

        func all() -> [(attachments: [Attachment], detail: String)] {
            lock.lock(); defer { lock.unlock() }
            return entries
        }
    }
}

/// Per-test scratch directory under `/tmp/agent-smith-tests/<uuid>/`. Created on init,
/// removed on `cleanup()`. Tests should `defer { dir.cleanup() }` so the directory is
/// removed even on early-return failures.
struct TempDir {
    let url: URL

    init() {
        let base = URL(fileURLWithPath: "/tmp/agent-smith-tests", isDirectory: true)
        let dir = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir
    }

    var path: String { url.path }

    /// Writes `content` to `relative` (creating any intermediate directories), returns the
    /// absolute path. Convenience for setting up fixture files.
    @discardableResult
    func write(_ content: String, to relative: String) throws -> String {
        let target = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: target, atomically: true, encoding: .utf8)
        return target.path
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }
}
