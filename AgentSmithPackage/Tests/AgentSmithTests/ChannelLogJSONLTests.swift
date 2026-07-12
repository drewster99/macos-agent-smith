import Testing
import Foundation
@testable import AgentSmithKit

/// Tests the append-only JSONL channel log that replaces the whole-array-rewrite model.
/// The guarantees that matter (a bug here loses transcript data):
///   1. Append + tail round-trips in order, with an accurate total count.
///   2. `loadChannelLogTail(limit:)` returns exactly the last `limit` messages.
///   3. Content with embedded newlines / unicode survives (the 0x0A line split is safe).
///   4. Legacy `channel_log.json` migrates to `.jsonl` once, strips `fileWrite*` metadata,
///      and LEAVES the legacy file in place as a backup.
///   5. An optional real-file validation (env `AGENTSMITH_REAL_CHANNEL_LOG`) migrates a COPY
///      of a real log and checks the count round-trips — never touches the original.
@Suite("Channel log JSONL", .serialized)
struct ChannelLogJSONLTests {

    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentsmith-jsonl-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func message(_ text: String, kind: String? = nil, requestID: String? = nil) -> ChannelMessage {
        var meta: [String: AnyCodable] = [:]
        if let kind { meta["messageKind"] = .string(kind) }
        if let requestID { meta["requestID"] = .string(requestID) }
        return ChannelMessage(sender: .system, content: text, metadata: meta.isEmpty ? nil : meta)
    }

    @Test("append + tail round-trips in order with an accurate total count")
    func appendTailRoundTrip() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pm = PersistenceManager(testingRoot: root)

        let batch1 = (0..<5).map { message("m\($0)") }
        let batch2 = (5..<10).map { message("m\($0)") }
        try await pm.appendChannelMessages(batch1)
        try await pm.appendChannelMessages(batch2)

        let (all, total) = try await pm.loadChannelLogTail(limit: 100)
        #expect(total == 10)
        #expect(all.count == 10)
        #expect(all.map(\.content) == (0..<10).map { "m\($0)" })
    }

    @Test("loadChannelLogTail returns exactly the last N messages")
    func tailLimit() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pm = PersistenceManager(testingRoot: root)

        try await pm.appendChannelMessages((0..<50).map { message("m\($0)") })
        let (tail, total) = try await pm.loadChannelLogTail(limit: 10)
        #expect(total == 50)
        #expect(tail.count == 10)
        #expect(tail.first?.content == "m40")
        #expect(tail.last?.content == "m49")
    }

    @Test("content with embedded newlines and unicode survives the line split")
    func newlineAndUnicodeSafe() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pm = PersistenceManager(testingRoot: root)

        let tricky = "line one\nline two\r\n\ttabbed 🧪 café — \"quoted\" \\backslash\n"
        try await pm.appendChannelMessages([message("before"), message(tricky), message("after")])

        let (all, total) = try await pm.loadChannelLogTail(limit: 100)
        #expect(total == 3)
        #expect(all[1].content == tricky)
    }

    @Test("empty append is a no-op and creates no file")
    func emptyAppendNoOp() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pm = PersistenceManager(testingRoot: root)

        try await pm.appendChannelMessages([])
        let (all, total) = try await pm.loadChannelLogTail(limit: 100)
        #expect(total == 0)
        #expect(all.isEmpty)
    }

    @Test("legacy channel_log.json migrates once, strips fileWrite metadata, preserves the backup")
    func legacyMigration() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("AgentSmith", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        // Author a legacy array file directly, including a message carrying the stale metadata.
        let legacy: [ChannelMessage] = [
            message("old-0"),
            ChannelMessage(sender: .system, content: "old-1", metadata: [
                "messageKind": .string("tool_output"),
                "fileWriteOldContent": .string("SHOULD BE STRIPPED"),
                "fileWriteContent": .string("SHOULD BE STRIPPED"),
                "requestID": .string("req-1")
            ]),
            message("old-2")
        ]
        let legacyURL = sessionDir.appendingPathComponent("channel_log.json")
        try JSONEncoder().encode(legacy).write(to: legacyURL, options: .atomic)

        let pm = PersistenceManager(testingRoot: root)
        // Reading the tail triggers the one-time migration.
        let (all, total) = try await pm.loadChannelLogTail(limit: 100)
        #expect(total == 3)
        #expect(all.map(\.content) == ["old-0", "old-1", "old-2"])
        // Stale diff metadata stripped, but other metadata kept.
        #expect(all[1].metadata?["fileWriteOldContent"] == nil)
        #expect(all[1].metadata?["fileWriteContent"] == nil)
        #expect(all[1].metadata?["requestID"] != nil)

        // Legacy file preserved as a backup; .jsonl now exists.
        #expect(FileManager.default.fileExists(atPath: legacyURL.path))
        #expect(FileManager.default.fileExists(atPath: sessionDir.appendingPathComponent("channel_log.jsonl").path))

        // Migration is idempotent: a subsequent append does not re-migrate or duplicate.
        try await pm.appendChannelMessages([message("live-0")])
        let (all2, total2) = try await pm.loadChannelLogTail(limit: 100)
        #expect(total2 == 4)
        #expect(all2.last?.content == "live-0")
    }

    @Test("a partial final record is skipped (not fatal), and a later append isolates it")
    func partialRecordTolerance() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("AgentSmith", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let jsonl = dir.appendingPathComponent("channel_log.jsonl")

        let pm = PersistenceManager(testingRoot: root)
        try await pm.appendChannelMessages([message("a"), message("b")])

        // Simulate a crash mid-append: a truncated final record with no trailing newline.
        var poisoned = try Data(contentsOf: jsonl)
        poisoned.append(Data(#"{"id":"broken","content": trunc"#.utf8))
        try poisoned.write(to: jsonl)

        // Tolerant load: the two clean records survive; the partial is skipped, not fatal.
        let afterCrash = try await pm.loadChannelLogTail(limit: 100)
        #expect(afterCrash.messages.map(\.content) == ["a", "b"])
        #expect(try await pm.loadFullChannelLog().map(\.content) == ["a", "b"])

        // A later append must not fuse with the partial record and corrupt the new one.
        try await pm.appendChannelMessages([message("c")])
        #expect(try await pm.loadFullChannelLog().map(\.content) == ["a", "b", "c"])
    }

    @Test("append writer preserves order across batches and flush waits for the write")
    func appendWriterOrderAndFlush() async throws {
        let recorder = Recorder()
        let writer = ChannelLogAppendWriter { messages in recorder.add(messages.map(\.content)) }
        await writer.enqueue([message("1"), message("2")])
        await writer.enqueue([message("3")])
        await writer.flush()
        #expect(recorder.all() == ["1", "2", "3"])
    }

    @Test("append writer retries a transient failure and the message still lands")
    func appendWriterRetriesTransient() async throws {
        let recorder = Recorder(failuresLeft: 2)
        let writer = ChannelLogAppendWriter { messages in try recorder.addThrowing(messages.map(\.content)) }
        await writer.enqueue([message("x")])
        await writer.flush()
        #expect(recorder.all() == ["x"], "the message should land after transient failures are retried")
    }

    /// Thread-safe sink for the append-writer tests; can be told to fail its first N appends.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var got: [String] = []
        private var failuresLeft: Int
        init(failuresLeft: Int = 0) { self.failuresLeft = failuresLeft }
        func add(_ items: [String]) { lock.withLock { got += items } }
        func addThrowing(_ items: [String]) throws {
            try lock.withLock {
                if failuresLeft > 0 { failuresLeft -= 1; throw NSError(domain: "test", code: 1) }
                got += items
            }
        }
        func all() -> [String] { lock.withLock { got } }
    }

    /// Opt-in validation against a copy of a REAL channel log. Set
    /// `AGENTSMITH_REAL_CHANNEL_LOG` to a path (ideally a copy of a live
    /// `channel_log.json`); the test copies it under a temp root and exercises the
    /// migration + tail there. Skipped when the env var is unset. Never touches the original.
    @Test("real-file migration validation (opt-in via AGENTSMITH_REAL_CHANNEL_LOG)")
    func realFileValidation() async throws {
        guard let path = ProcessInfo.processInfo.environment["AGENTSMITH_REAL_CHANNEL_LOG"],
              !path.isEmpty else {
            return  // not configured — skip
        }
        let source = URL(fileURLWithPath: path)
        try #require(FileManager.default.fileExists(atPath: source.path))

        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = root.appendingPathComponent("AgentSmith", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: sessionDir.appendingPathComponent("channel_log.json"))

        let pm = PersistenceManager(testingRoot: root)
        let (tail, total) = try await pm.loadChannelLogTail(limit: 400)
        #expect(total > 0)
        #expect(tail.count == min(400, total))
        // Full load must agree with the tail on count and on the last message's identity.
        let full = try await pm.loadFullChannelLog()
        #expect(full.count == total)
        #expect(full.last?.id == tail.last?.id)
    }
}
