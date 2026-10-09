import Testing
import Foundation
import CoreGraphics
import ImageIO
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
        let ingested = await TaskCompleteTool.ingestEvidenceDirectory(context: context, existing: []).attachments

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
        let ingested = await TaskCompleteTool.ingestEvidenceDirectory(context: context, existing: [already]).attachments

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

    @Test("a file named both top-level and in a deliverable is one attachment")
    func samePathTopLevelAndDeliverable() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("paths-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("report.md")
        try "report".write(to: file, atomically: true, encoding: .utf8)

        let store = TaskStore()
        let agentID = UUID()
        let task = await store.addTask(title: "t", description: "d")
        await store.updateStatus(id: task.id, status: .starting, cause: .startClaimed)
        #expect(await store.updateStatus(id: task.id, status: .running, cause: .workerStarted))
        await store.assignAgent(taskID: task.id, agentID: agentID)
        let recorder = IngestRecorder()
        let context = TestToolContext.make(
            agentID: agentID,
            taskStore: store,
            attachmentIngestor: { path in
                let url = URL(fileURLWithPath: path)
                await recorder.record(url.lastPathComponent)
                guard let data = try? Data(contentsOf: url) else { return (nil, "unreadable") }
                return (Attachment(filename: url.lastPathComponent, mimeType: "text/plain", byteCount: data.count, data: data), nil)
            }
        )
        // The same file, spelled two ways.
        let dotted = dir.appendingPathComponent(".").appendingPathComponent("report.md").path
        let result = try await TaskCompleteTool().execute(arguments: [
            "result": .string("done"),
            "attachment_paths": .array([.string(file.path)]),
            "deliverables": .array([.dictionary([
                "ref": .string("report"),
                "attachment_paths": .array([.string(dotted)])
            ])])
        ], context: context)
        #expect(result.succeeded)
        let stored = try #require(await store.task(id: task.id))
        #expect(stored.resultAttachments.count == 1)
        #expect(Set(stored.resultItems.flatMap(\.attachments).map(\.id)) == Set(stored.resultAttachments.map(\.id)))
        #expect(await recorder.count == 1, "ingested once")
    }

    @Test("a distinct evidence file sharing a name with another attachment is still ingested")
    func sameNameDifferentContentIngested() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sweep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "evidence".write(to: dir.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)

        let recorder = IngestRecorder()
        let context = makeContext(evidenceDir: dir, recorder: recorder)
        let other = Attachment(filename: "report.md", mimeType: "text/plain", byteCount: 5, data: Data("other".utf8))
        let ingested = await TaskCompleteTool.ingestEvidenceDirectory(context: context, existing: [other]).attachments
        #expect(ingested.map(\.filename) == ["report.md"])
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
        let ingested = await TaskCompleteTool.ingestEvidenceDirectory(context: context, existing: []).attachments
        #expect(ingested.isEmpty)
    }

    @Test("files a worker saved in subfolders are swept, named by their path under the evidence dir")
    func nestedFilesAreSwept() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sweep-nested-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("screenshots/deep", isDirectory: true), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "top".write(to: dir.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: dir.appendingPathComponent("screenshots/1.png"))
        try "deep".write(to: dir.appendingPathComponent("screenshots/deep/notes.txt"), atomically: true, encoding: .utf8)

        let context = makeContext(evidenceDir: dir, recorder: IngestRecorder())
        let ingested = await TaskCompleteTool.ingestEvidenceDirectory(context: context, existing: []).attachments

        #expect(Set(ingested.map(\.filename)) == ["report.md", "screenshots/1.png", "screenshots/deep/notes.txt"])
    }

    private func makeEvidenceDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sweep-edge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("hidden files and folders are skipped silently; a symbolic link is reported, not followed")
    func hiddenSkippedSymlinkReported() async throws {
        let dir = try makeEvidenceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".cache", isDirectory: true), withIntermediateDirectories: true)
        try "secret".write(to: dir.appendingPathComponent(".cache/blob"), atomically: true, encoding: .utf8)
        try "hidden".write(to: dir.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link.txt"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        try "real".write(to: dir.appendingPathComponent("real.txt"), atomically: true, encoding: .utf8)

        let sweep = await TaskCompleteTool.ingestEvidenceDirectory(context: makeContext(evidenceDir: dir, recorder: IngestRecorder()), existing: [])

        #expect(sweep.attachments.map(\.filename) == ["real.txt"])
        #expect(sweep.problems.count == 1)
        #expect(sweep.problems.first?.hasPrefix("link.txt") == true)
    }

    @Test("an evidence folder that is itself a symbolic link attaches nothing, and says so")
    func symlinkedEvidenceFolderRefused() async throws {
        let target = try makeEvidenceDir()
        defer { try? FileManager.default.removeItem(at: target) }
        try "private".write(to: target.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("sweep-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: link) }

        let sweep = await TaskCompleteTool.ingestEvidenceDirectory(context: makeContext(evidenceDir: link, recorder: IngestRecorder()), existing: [])

        #expect(sweep.attachments.isEmpty)
        #expect(sweep.problems.count == 1)
        #expect(sweep.problems.first?.contains("symbolic link") == true)
    }

    @Test("a long list of problems is cut to a count, so it can't flood the transcript")
    func problemListIsCapped() async throws {
        let dir = try makeEvidenceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let extra = 7
        for index in 0..<(TaskCompleteTool.maxListedEvidenceProblems + extra) {
            try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link\(index)"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        }

        let sweep = await TaskCompleteTool.ingestEvidenceDirectory(context: makeContext(evidenceDir: dir, recorder: IngestRecorder()), existing: [])

        #expect(sweep.problems.count == TaskCompleteTool.maxListedEvidenceProblems + 1)
        #expect(sweep.problems.last == "…and \(extra) more")
    }

    @Test("matching an attachment whose bytes aren't loaded by name and size is reported, not silent")
    func sizeOnlyMatchIsDistinguished() {
        let bytes = Data("same size".utf8)
        let unloaded = Attachment(filename: "a.txt", mimeType: "text/plain", byteCount: bytes.count, data: nil)
        let loaded = Attachment(filename: "a.txt", mimeType: "text/plain", byteCount: bytes.count, data: bytes)
        #expect(TaskCompleteTool.attachmentMatch(bytes, mimeType: "text/plain", amongNamesakes: [loaded]) == .sameBytes)
        #expect(TaskCompleteTool.attachmentMatch(bytes, mimeType: "text/plain", amongNamesakes: [unloaded]) == .sameNameAndSize)
        #expect(TaskCompleteTool.attachmentMatch(Data("other".utf8), mimeType: "text/plain", amongNamesakes: [unloaded]) == .none)
        #expect(TaskCompleteTool.attachmentMatch(bytes, mimeType: "text/plain", amongNamesakes: []) == .none)
    }

    @Test("files over the per-submission file limit are reported, not silently dropped")
    func fileLimitIsReported() async throws {
        let dir = try makeEvidenceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for index in 0..<(TaskCompleteTool.maxEvidenceFiles + 3) {
            try "x".write(to: dir.appendingPathComponent(String(format: "f%04d.txt", index)), atomically: true, encoding: .utf8)
        }

        let sweep = await TaskCompleteTool.ingestEvidenceDirectory(context: makeContext(evidenceDir: dir, recorder: IngestRecorder()), existing: [])

        #expect(sweep.attachments.count == TaskCompleteTool.maxEvidenceFiles)
        #expect(sweep.problems.count == 1)
        #expect(sweep.problems.first?.hasPrefix("3 file(s) over the") == true)
    }

    @Test("an unreadable file and a failed ingest are both reported")
    func unreadableAndFailedIngestReported() async throws {
        let dir = try makeEvidenceDir()
        defer {
            _ = try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dir.appendingPathComponent("locked.txt").path)
            try? FileManager.default.removeItem(at: dir)
        }
        try "locked".write(to: dir.appendingPathComponent("locked.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.appendingPathComponent("locked.txt").path)
        try "refused".write(to: dir.appendingPathComponent("refused.txt"), atomically: true, encoding: .utf8)
        let context = TestToolContext.make(
            attachmentDataIngestor: { _, filename, _ in (nil, "registry refused \(filename)") },
            taskEvidenceDirectory: dir
        )

        let sweep = await TaskCompleteTool.ingestEvidenceDirectory(context: context, existing: [])

        #expect(sweep.attachments.isEmpty)
        #expect(sweep.problems.contains { $0.hasPrefix("locked.txt:") })
        #expect(sweep.problems.contains { $0 == "refused.txt: registry refused refused.txt" })
    }

    @Test("a nested file the worker also attached explicitly (by its bare name) is not attached twice")
    func nestedExplicitAttachmentNotDoubled() async throws {
        let dir = try makeEvidenceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub", isDirectory: true), withIntermediateDirectories: true)
        try "report".write(to: dir.appendingPathComponent("sub/report.md"), atomically: true, encoding: .utf8)
        let explicit = Attachment(filename: "report.md", mimeType: "text/markdown", byteCount: 6, data: Data("report".utf8))

        let sweep = await TaskCompleteTool.ingestEvidenceDirectory(context: makeContext(evidenceDir: dir, recorder: IngestRecorder()), existing: [explicit])

        #expect(sweep.attachments.isEmpty)
        #expect(sweep.problems.isEmpty)
    }

    @Test("an evidence directory that was never created is an empty sweep, not a problem")
    func missingDirectoryIsEmpty() async {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("sweep-missing-\(UUID().uuidString)", isDirectory: true)
        let sweep = await TaskCompleteTool.ingestEvidenceDirectory(context: makeContext(evidenceDir: missing, recorder: IngestRecorder()), existing: [])
        #expect(sweep == TaskCompleteTool.EvidenceSweep())
    }

    @Test("evidence that would take the submission over the per-message byte cap is reported, unread")
    func byteCapIsReported() async throws {
        let dir = try makeEvidenceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try String(repeating: "a", count: 600).write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try String(repeating: "b", count: 600).write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let context = TestToolContext.make(
            attachmentDataIngestor: { data, filename, mimeType in
                (Attachment(filename: filename, mimeType: mimeType, byteCount: data.count, data: data), nil)
            },
            maxAttachmentBytesPerMessage: 1_000,
            taskEvidenceDirectory: dir
        )

        let sweep = await TaskCompleteTool.ingestEvidenceDirectory(context: context, existing: [])

        #expect(sweep.attachments.map(\.filename) == ["a.txt"])
        #expect(sweep.problems.count == 1)
        #expect(sweep.problems.first?.hasPrefix("b.txt: not attached") == true)
    }

    @Test("a package is reported, not silently skipped")
    func packageIsReported() async throws {
        let dir = try makeEvidenceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Run.xcresult/Data", isDirectory: true), withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent("Run.xcresult/Data/blob"), atomically: true, encoding: .utf8)

        let sweep = await TaskCompleteTool.ingestEvidenceDirectory(context: makeContext(evidenceDir: dir, recorder: IngestRecorder()), existing: [])

        #expect(sweep.attachments.isEmpty)
        #expect(sweep.problems == ["Run.xcresult: a package (bundle), not attached — zip it to include it"])
    }

    @Test("a screenshot the worker already attached is not attached again, though ingest re-encoded its bytes")
    func sanitizedImageNotDoubled() async throws {
        let dir = try makeEvidenceDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("screenshots", isDirectory: true), withIntermediateDirectories: true)
        let png = try Self.makePNG()
        try png.write(to: dir.appendingPathComponent("screenshots/1.png"))
        let stored = AttachmentSanitizer.sanitize(png, mimeType: "image/png")
        try #require(stored != png, "the stored bytes must differ from the file's, or this proves nothing")
        let explicit = Attachment(filename: "1.png", mimeType: "image/png", byteCount: stored.count, data: stored)

        let sweep = await TaskCompleteTool.ingestEvidenceDirectory(context: makeContext(evidenceDir: dir, recorder: IngestRecorder()), existing: [explicit])

        #expect(sweep.attachments.isEmpty)
        #expect(sweep.problems.isEmpty)
    }

    /// A real 4×4 PNG, so `AttachmentSanitizer` actually re-encodes it.
    private static func makePNG() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "metadata"]] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private actor IngestRecorder {
        private var names: [String] = []
        func record(_ name: String) { names.append(name) }
        func contains(_ name: String) -> Bool { names.contains(name) }
        var count: Int { names.count }
    }
}

