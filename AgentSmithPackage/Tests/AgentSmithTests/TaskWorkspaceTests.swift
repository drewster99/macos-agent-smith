import Testing
import Foundation
@testable import AgentSmithKit

@Suite("TaskWorkspace")
struct TaskWorkspaceTests {

    @Test("evidence directory is nil without a workspace root; temp dir is always available")
    func directoriesWithAndWithoutRoot() {
        let taskID = UUID()
        let rootless = TaskWorkspace(taskID: taskID, workspaceRoot: nil)
        #expect(rootless.evidenceDirectory == nil)
        #expect(rootless.temporaryDirectory.path.contains(taskID.uuidString))

        let root = URL(fileURLWithPath: "/tmp/session-xyz", isDirectory: true)
        let rooted = TaskWorkspace(taskID: taskID, workspaceRoot: root)
        let evidence = rooted.evidenceDirectory
        #expect(evidence != nil)
        #expect(evidence?.path == "/tmp/session-xyz/tasks/\(taskID.uuidString)/evidence")
    }

    @Test("path containment is boundary-aware")
    func containment() {
        let dir = URL(fileURLWithPath: "/x/evidence", isDirectory: true)
        #expect(TaskWorkspace.path("/x/evidence/a.md", isInside: dir))
        #expect(TaskWorkspace.path("/x/evidence", isInside: dir))
        #expect(!TaskWorkspace.path("/x/evidence-backup/a.md", isInside: dir))
        #expect(!TaskWorkspace.path("/x/other/a.md", isInside: dir))
    }

    @Test("ensureDirectories creates both; cleanupTemporary removes only the temp dir")
    func lifecycle() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let ws = TaskWorkspace(taskID: UUID(), workspaceRoot: base)
        ws.ensureDirectories()
        #expect(FileManager.default.fileExists(atPath: ws.temporaryDirectory.path))
        #expect(FileManager.default.fileExists(atPath: ws.evidenceDirectory!.path))

        ws.cleanupTemporary()
        #expect(!FileManager.default.fileExists(atPath: ws.temporaryDirectory.path))
        #expect(FileManager.default.fileExists(atPath: ws.evidenceDirectory!.path), "evidence dir persists")
    }
}

@Suite("TaskCompleteTool evidence sweep")
struct EvidenceSweepTests {

    private func makeContext(evidenceDir: URL, recorder: IngestRecorder) -> ToolContext {
        TestToolContext.make(
            attachmentDataIngestor: { data, filename, mimeType in
                await recorder.record(filename)
                return (Attachment(filename: filename, mimeType: mimeType, byteCount: data.count, data: data), nil)
            },
            taskEvidenceDirectory: evidenceDir
        )
    }

    @Test("every file in the evidence dir is ingested, including binaries like screenshots")
    func sweepIngestsAll() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sweep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "report".write(to: dir.appendingPathComponent("PHASE1.md"), atomically: true, encoding: .utf8)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: dir.appendingPathComponent("shot.png"))

        let recorder = IngestRecorder()
        let context = makeContext(evidenceDir: dir, recorder: recorder)
        let ingested = await TaskCompleteTool.ingestEvidenceDirectory(context: context, existing: [])

        #expect(ingested.count == 2)
        #expect(await recorder.contains("PHASE1.md"))
        #expect(await recorder.contains("shot.png"))
        #expect(ingested.first { $0.filename == "shot.png" }?.mimeType == "image/png")
    }

    @Test("a file already referenced by the worker is not doubled")
    func sweepDedupesByFilename() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sweep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "x".write(to: dir.appendingPathComponent("PHASE1.md"), atomically: true, encoding: .utf8)

        let recorder = IngestRecorder()
        let context = makeContext(evidenceDir: dir, recorder: recorder)
        let already = Attachment(filename: "PHASE1.md", mimeType: "text/plain", byteCount: 1, data: Data("x".utf8))
        let ingested = await TaskCompleteTool.ingestEvidenceDirectory(context: context, existing: [already])

        #expect(ingested.isEmpty, "the already-referenced file must not be ingested again")
    }

    @Test("an evidence file cited by a deliverable is attached once, not again by the sweep")
    func deliverableEvidenceNotDoubled() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sweep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("echo-output.log")
        try "watch-test-B".write(to: file, atomically: true, encoding: .utf8)

        let store = TaskStore()
        let agentID = UUID()
        let task = await store.addTask(title: "t", description: "d")
        await store.updateStatus(id: task.id, status: .starting, cause: .startClaimed)
        #expect(await store.updateStatus(id: task.id, status: .running, cause: .workerStarted))
        await store.assignAgent(taskID: task.id, agentID: agentID)
        let context = TestToolContext.make(
            agentID: agentID,
            taskStore: store,
            attachmentIngestor: { path in
                let url = URL(fileURLWithPath: path)
                guard let data = try? Data(contentsOf: url) else { return (nil, "unreadable") }
                return (Attachment(filename: url.lastPathComponent, mimeType: "text/plain", byteCount: data.count, data: data), nil)
            },
            taskEvidenceDirectory: dir
        )
        let result = try await TaskCompleteTool().execute(arguments: [
            "result": .string("done"),
            "deliverables": .array([.dictionary([
                "ref": .string("echo"),
                "attachment_paths": .array([.string(file.path)])
            ])])
        ], context: context)
        #expect(result.succeeded)
        let stored = try #require(await store.task(id: task.id))
        #expect(stored.resultAttachments.map(\.filename) == ["echo-output.log"])
        let deliverableIDs = Set(stored.resultItems.flatMap(\.attachments).map(\.id))
        #expect(deliverableIDs == Set(stored.resultAttachments.map(\.id)), "the deliverable points at the one stored attachment")
    }

    @Test("no evidence directory → no-op")
    func noEvidenceDir() async {
        let recorder = IngestRecorder()
        let context = TestToolContext.make(
            attachmentDataIngestor: { data, filename, mimeType in
                await recorder.record(filename)
                return (Attachment(filename: filename, mimeType: mimeType, byteCount: data.count, data: data), nil)
            }
        )
        let ingested = await TaskCompleteTool.ingestEvidenceDirectory(context: context, existing: [])
        #expect(ingested.isEmpty)
    }

    private actor IngestRecorder {
        private var names: [String] = []
        func record(_ name: String) { names.append(name) }
        func contains(_ name: String) -> Bool { names.contains(name) }
    }
}
