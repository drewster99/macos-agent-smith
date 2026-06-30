import Testing
import Foundation
@testable import AgentSmithKit

/// Verifies the one-time migration that moves per-session attachment files into the global
/// attachments store (so archived/deleted tasks — which are global — resolve their files from any
/// window). Uses `init(testingRoot:)` so it never touches real data.
@Suite("Attachment migration to global store")
struct AttachmentMigrationTests {

    @Test("moves per-session attachment files into the global dir, then resolves them globally")
    func movesToGlobalAndResolves() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let pm = PersistenceManager(testingRoot: root)

        // Seed a fake session attachment file at sessions/<id>/attachments/<uuid>_photo.png.
        let base = root.appendingPathComponent("AgentSmith")
        let sessionAttachments = base
            .appendingPathComponent("sessions")
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("attachments")
        try FileManager.default.createDirectory(at: sessionAttachments, withIntermediateDirectories: true)
        let id = UUID()
        let bytes = Data([0x1, 0x2, 0x3])
        let src = sessionAttachments.appendingPathComponent("\(id.uuidString)_photo.png")
        try bytes.write(to: src)

        let result = try await pm.migrateSessionAttachmentsToGlobalStore()
        #expect(result.moved == 1)
        #expect(result.failed == 0)

        // File physically moved (not copied) into the global attachments dir.
        let globalFile = base.appendingPathComponent("attachments").appendingPathComponent("\(id.uuidString)_photo.png")
        #expect(FileManager.default.fileExists(atPath: globalFile.path))
        #expect(!FileManager.default.fileExists(atPath: src.path))

        // And it now resolves through the normal global-attachment accessor.
        let loaded = await pm.loadAttachmentData(id: id, filename: "photo.png")
        #expect(loaded == bytes)

        // Idempotent: a second run moves nothing.
        let again = try await pm.migrateSessionAttachmentsToGlobalStore()
        #expect(again.moved == 0)
        #expect(again.failed == 0)
    }

    @Test("a file already present at the global destination is left as-is (no clobber)")
    func doesNotClobberExistingGlobalFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let pm = PersistenceManager(testingRoot: root)
        let base = root.appendingPathComponent("AgentSmith")

        let id = UUID()
        let name = "\(id.uuidString)_doc.txt"

        // Pre-existing global copy (the "good" one).
        let globalAttachments = base.appendingPathComponent("attachments")
        try FileManager.default.createDirectory(at: globalAttachments, withIntermediateDirectories: true)
        try Data("global".utf8).write(to: globalAttachments.appendingPathComponent(name))

        // A stale per-session copy with different bytes.
        let sessionAttachments = base
            .appendingPathComponent("sessions")
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("attachments")
        try FileManager.default.createDirectory(at: sessionAttachments, withIntermediateDirectories: true)
        try Data("session".utf8).write(to: sessionAttachments.appendingPathComponent(name))

        let result = try await pm.migrateSessionAttachmentsToGlobalStore()
        #expect(result.moved == 0)

        // The global copy is untouched.
        let loaded = await pm.loadAttachmentData(id: id, filename: "doc.txt")
        #expect(loaded == Data("global".utf8))
    }
}
