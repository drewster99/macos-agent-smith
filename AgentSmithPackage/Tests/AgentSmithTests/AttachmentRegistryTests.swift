import Testing
import Foundation
@testable import AgentSmithKit

/// Tests for `AttachmentRegistry`. Covers register/resolve, lazy-load via the loader
/// closure, ingestFile happy-path, file-size cap, missing-file rejection, and the
/// rejected-id path on `resolve(idStrings:)`.
@Suite("AttachmentRegistry")
struct AttachmentRegistryTests {

    /// Builds a registry with synchronous in-memory backing — the loader returns from a
    /// pre-populated dictionary, the saver writes to a temp dir on disk.
    private func makeRegistry(
        store: [UUID: Data] = [:],
        tempDir: TempDir
    ) -> AttachmentRegistry {
        let storeBox = StoreBox(map: store)
        return AttachmentRegistry(
            loader: { id, _ in storeBox.get(id) },
            saver: { attachment in
                guard let data = attachment.data else { return }
                storeBox.set(attachment.id, data)
                let target = tempDir.url.appendingPathComponent("\(attachment.id.uuidString)_\(attachment.filename)")
                try data.write(to: target, options: .atomic)
            }
        )
    }

    /// Sendable wrapper around a [UUID: Data] dictionary so the loader/saver closures
    /// can mutate it from inside the actor without crossing actor boundaries.
    final class StoreBox: @unchecked Sendable {
        private let lock = NSLock()
        private var map: [UUID: Data]
        init(map: [UUID: Data]) { self.map = map }
        func get(_ id: UUID) -> Data? {
            lock.lock(); defer { lock.unlock() }
            return map[id]
        }
        func set(_ id: UUID, _ data: Data) {
            lock.lock(); defer { lock.unlock() }
            map[id] = data
        }
    }

    @Test("register + resolve returns metadata-only when bytes aren't loaded")
    func registerResolveMetadataOnly() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let registry = makeRegistry(tempDir: dir)
        let id = UUID()
        let attachment = Attachment(id: id, filename: "foo.png", mimeType: "image/png", byteCount: 100, data: nil)
        await registry.register(attachment)

        // Without a loader hit, resolve returns metadata + nil data
        let resolved = await registry.resolve(id)
        #expect(resolved?.id == id)
        #expect(resolved?.data == nil)
    }

    @Test("resolve lazy-loads bytes via the loader closure")
    func lazyLoad() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let id = UUID()
        let bytes = Data([0xCA, 0xFE, 0xBA, 0xBE])
        let registry = makeRegistry(store: [id: bytes], tempDir: dir)
        await registry.register(Attachment(id: id, filename: "x", mimeType: "application/octet-stream", byteCount: bytes.count, data: nil))

        let resolved = await registry.resolve(id)
        #expect(resolved?.data == bytes)
    }

    @Test("resolve(idStrings:) splits known and unknown IDs")
    func resolveStringsRejection() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let registry = makeRegistry(tempDir: dir)
        let known = UUID()
        await registry.register(Attachment(id: known, filename: "ok", mimeType: "text/plain", byteCount: 1))
        let unknownString = "not-a-uuid"
        let validButUnregistered = UUID().uuidString

        let result = await registry.resolve(idStrings: [
            known.uuidString,
            unknownString,
            validButUnregistered
        ])
        #expect(result.resolved.count == 1)
        #expect(result.resolved.first?.id == known)
        #expect(result.rejected.count == 2)
        #expect(result.rejected.contains(unknownString))
        #expect(result.rejected.contains(validButUnregistered))
    }

    @Test("ingestFile happy path mints a new Attachment and persists bytes")
    func ingestFileSuccess() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let registry = makeRegistry(tempDir: dir)
        let path = try dir.write("hello world", to: "input.txt")

        let result = await registry.ingestFile(path: path)
        switch result {
        case .success(let attachment):
            #expect(attachment.filename == "input.txt")
            #expect(attachment.byteCount == "hello world".utf8.count)
            #expect(attachment.data == Data("hello world".utf8))
        case .failure(let err):
            Issue.record("expected success, got: \(err)")
        }
    }

    @Test("ingestFile rejects a missing path")
    func ingestFileMissing() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let registry = makeRegistry(tempDir: dir)

        let result = await registry.ingestFile(path: "/tmp/this-file-does-not-exist-\(UUID().uuidString)")
        switch result {
        case .success: Issue.record("expected failure on missing file")
        case .failure(let err):
            if case .fileNotFound = err {} else { Issue.record("expected .fileNotFound, got \(err)") }
        }
    }

    @Test("ingestFile rejects a directory")
    func ingestFileDirectory() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let registry = makeRegistry(tempDir: dir)

        let result = await registry.ingestFile(path: dir.path)
        switch result {
        case .success: Issue.record("expected failure on directory")
        case .failure(let err):
            if case .isDirectory = err {} else { Issue.record("expected .isDirectory, got \(err)") }
        }
    }

    @Test("ingestFile honors the per-file size cap")
    func ingestFileSizeCap() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let registry = makeRegistry(tempDir: dir)
        // 100KB file, cap 1KB → reject.
        let path = try dir.write(String(repeating: "x", count: 100_000), to: "big.txt")
        await registry.setMaxIngestBytes(1024)

        let result = await registry.ingestFile(path: path)
        switch result {
        case .success: Issue.record("expected size-cap failure")
        case .failure(let err):
            if case .tooLarge(_, let size, let max) = err {
                #expect(size == 100_000)
                #expect(max == 1024)
            } else {
                Issue.record("expected .tooLarge, got \(err)")
            }
        }
    }

    @Test("setMaxIngestBytes clamps at zero (no-op for negatives)")
    func sizeCapClamp() async throws {
        let dir = TempDir()
        defer { dir.cleanup() }
        let registry = makeRegistry(tempDir: dir)
        await registry.setMaxIngestBytes(-1)
        let cap = await registry.currentMaxIngestBytes()
        #expect(cap == 0)
    }
}
