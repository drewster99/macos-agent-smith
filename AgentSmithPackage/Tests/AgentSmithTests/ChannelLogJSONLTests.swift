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

    // MARK: - Bounded reads (added when the whole-file reads were replaced)

    /// The prefilter's superset property, which is what makes it safe.
    ///
    /// `loadTaskTranscript` skips a line that does not contain the task's UUID rather than decoding
    /// it. That is only sound if the prefilter can never REJECT a line the typed check would have
    /// accepted — a false negative is a silently missing message, the worst failure available here.
    /// So the result must equal the read-everything-then-filter version exactly, including for a
    /// line that mentions the id somewhere other than `taskID`.
    @Test("loadTaskTranscript equals a full decode + filter, prefilter included")
    func taskTranscriptMatchesFullFilter() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pm = PersistenceManager(testingRoot: root)

        let target = UUID()
        let other = UUID()
        var messages: [ChannelMessage] = []
        messages.append(ChannelMessage(sender: .system, content: "mine 1", taskID: target))
        messages.append(ChannelMessage(sender: .system, content: "someone else", taskID: other))
        messages.append(ChannelMessage(sender: .system, content: "no task at all"))
        // Mentions the id in CONTENT but belongs to no task: a prefilter hit the typed check rejects.
        messages.append(ChannelMessage(sender: .system, content: "log line about \(target.uuidString)"))
        // Carries the id in METADATA with no top-level taskID — the real corpus has 63 of these.
        messages.append(ChannelMessage(sender: .system, content: "meta only",
                                       metadata: ["taskID": .string(target.uuidString)]))
        messages.append(ChannelMessage(sender: .system, content: "mine 2", taskID: target))
        try await pm.appendChannelMessages(messages)

        let viaPrefilter = try await pm.loadTaskTranscript(taskID: target)
        let viaFullDecode = try await pm.loadFullChannelLog().filter { $0.taskID == target }
        #expect(viaPrefilter.map(\.content) == viaFullDecode.map(\.content))
        #expect(viaPrefilter.map(\.content) == ["mine 1", "mine 2"])
    }

    /// `UUID.uuidString` is uppercase and `JSONEncoder` writes it that way, but
    /// `UUID(uuidString:)` accepts lowercase — so a single-case needle would drop a hand-written or
    /// future-producer line that the typed check would have accepted.
    @Test("A lowercase-UUID line is still found")
    func lowercaseUUIDLineIsFound() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pm = PersistenceManager(testingRoot: root)
        let target = UUID()

        try await pm.appendChannelMessages([ChannelMessage(sender: .system, content: "placeholder")])
        // Hand-write a record whose taskID is lowercase, as a non-JSONEncoder producer might.
        let url = root.appendingPathComponent("AgentSmith", isDirectory: true)
            .appendingPathComponent("channel_log.jsonl")
        let handWritten = """
            {"id":"\(UUID().uuidString)","sender":{"system":{}},"content":"lowercase","timestamp":123,\
            "taskID":"\(target.uuidString.lowercased())"}
            """
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((handWritten + "\n").utf8))
        try handle.close()

        let found = try await pm.loadTaskTranscript(taskID: target)
        #expect(found.map(\.content) == ["lowercase"])
    }

    /// The bounded backward read used by the lost-message recovery path, which discards the total.
    @Test("loadRecentChannelMessages returns the same tail as loadChannelLogTail")
    func recentMessagesMatchTail() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pm = PersistenceManager(testingRoot: root)
        try await pm.appendChannelMessages((0..<200).map { message("m\($0)") })

        for limit in [1, 32, 199, 200, 201] {
            let recent = try await pm.loadRecentChannelMessages(limit: limit)
            let tail = try await pm.loadChannelLogTail(limit: limit).messages
            #expect(recent.map(\.content) == tail.map(\.content), "limit=\(limit)")
        }
    }

    /// `totalCount` gates `hasRestoredHistory`, which gates transcript trimming and the Restore
    /// button — so the scan-based tail must report exactly what a full decode would.
    @Test("totalCount is unchanged by the bounded scan, at and around the limit")
    func totalCountSurvivesTheBoundedScan() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pm = PersistenceManager(testingRoot: root)
        try await pm.appendChannelMessages((0..<75).map { message("m\($0)") })

        for limit in [1, 74, 75, 76, 1000] {
            let result = try await pm.loadChannelLogTail(limit: limit)
            #expect(result.totalCount == 75, "limit=\(limit) reported \(result.totalCount)")
            #expect(result.messages.count == min(limit, 75), "limit=\(limit)")
        }
    }

    /// The recovery caller asks for a fixed number of recent messages and uses them to hunt for a
    /// trailing user message. A fixed byte window would silently return fewer than asked for when
    /// the tail happens to hold large records — the real corpus averages ~3.6 KB per line but its
    /// largest is 399 KB — and the caller would then miss the message it exists to find.
    @Test("loadRecentChannelMessages returns the full count even when the tail records are huge")
    func recentMessagesWidenTheWindowForLargeRecords() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pm = PersistenceManager(testingRoot: root)

        let big = String(repeating: "x", count: 200_000)
        try await pm.appendChannelMessages((0..<40).map { message("\(big)-\($0)") })

        let recent = try await pm.loadRecentChannelMessages(limit: 32)
        #expect(recent.count == 32, "window did not widen; got \(recent.count)")
        #expect(recent.last?.content.hasSuffix("-39") == true, "must be the LAST 32, in order")
    }

    /// `limit <= 0` must still report the real total without decoding the whole file for it.
    @Test("A zero limit reports the true total and decodes nothing")
    func zeroLimitReportsTotalWithoutDecoding() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pm = PersistenceManager(testingRoot: root)
        try await pm.appendChannelMessages((0..<30).map { message("m\($0)") })

        let result = try await pm.loadChannelLogTail(limit: 0)
        #expect(result.messages.isEmpty)
        #expect(result.totalCount == 30)
    }

    /// A file holding FEWER messages than the caller asked for must return promptly.
    ///
    /// The widening loop's only exit for this case used to be a `stat` comparison, and `try?` plus
    /// `as? Int` collapses a failed stat to nil — making that condition permanently false and the
    /// loop unbounded, on what is simply "a fresh session". It now terminates on read progress,
    /// which cannot fail. The timeout is the assertion: a regression hangs rather than fails.
    @Test("Asking for more messages than exist returns what exists, promptly", .timeLimit(.minutes(1)))
    func fewerMessagesThanRequestedTerminates() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pm = PersistenceManager(testingRoot: root)
        try await pm.appendChannelMessages((0..<3).map { message("m\($0)") })

        let recent = try await pm.loadRecentChannelMessages(limit: 32)
        #expect(recent.map(\.content) == ["m0", "m1", "m2"])

        // And the degenerate case: an empty log.
        let empty = try await PersistenceManager(testingRoot: try makeTempRoot()).loadRecentChannelMessages(limit: 32)
        #expect(empty.isEmpty)
    }
}
