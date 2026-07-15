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

@Suite("FileWriteTool evidence auto-ingest")
struct FileWriteEvidenceIngestTests {

    @Test("a write into the evidence dir is auto-ingested; a writable path outside is not")
    func autoIngest() async throws {
        // /tmp resolves to /private/tmp, which FileWriteTool does NOT block (unlike /var/folders,
        // the OS temp dir). Both the evidence dir and the "outside" file live here so both writes
        // are genuinely permitted, isolating the ingest behavior from the path restriction.
        let base = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("fwtest-\(UUID().uuidString)", isDirectory: true)
        let evidenceDir = base.appendingPathComponent("evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let ingested = IngestRecorder()
        let context = TestToolContext.make(
            attachmentDataIngestor: { data, filename, mimeType in
                await ingested.record(filename)
                return (Attachment(filename: filename, mimeType: mimeType, byteCount: data.count, data: data), nil)
            },
            taskEvidenceDirectory: evidenceDir
        )

        // Inside the evidence dir → ingested, and the result notes it.
        let insidePath = evidenceDir.appendingPathComponent("PROOF.md").path
        let inside = try await FileWriteTool().execute(
            arguments: ["path": .string(insidePath), "content": .string("evidence")],
            context: context
        )
        #expect(inside.succeeded)
        #expect(inside.output.contains("ingested"))
        #expect(await ingested.contains("PROOF.md"))

        // Outside the evidence dir (but writable) → NOT ingested.
        let outsidePath = base.appendingPathComponent("scratch.md").path
        let outside = try await FileWriteTool().execute(
            arguments: ["path": .string(outsidePath), "content": .string("scratch")],
            context: context
        )
        #expect(outside.succeeded)
        #expect(!outside.output.contains("ingested"))
    }

    private actor IngestRecorder {
        private var names: [String] = []
        func record(_ name: String) { names.append(name) }
        func contains(_ name: String) -> Bool { names.contains(name) }
    }
}
