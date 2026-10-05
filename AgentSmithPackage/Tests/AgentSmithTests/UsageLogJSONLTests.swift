import Testing
import Foundation
@testable import AgentSmithKit

/// The append-only `usage_records.jsonl` that replaced rewriting the whole `usage_records.json`
/// array on every coalesced save. A bug here loses or mis-attributes spend history, so:
///   1. The legacy array migrates once, losslessly, and the legacy file is left untouched.
///   2. Append + reload round-trips exactly.
///   3. A task backfill is a ROW, replayed only onto the records before it — the same records
///      the live call mutated — so reload equals what memory held.
///   4. A torn final line is skipped, and the next append can't fuse with it.
///   5. The wire shape is pinned: a record line has no `rowKind`, a backfill line names its kind.
///   6. A row kind from a newer build is skipped, not allowed to fail the whole history.
///   7. Records appended before `load()` finishes are kept, not dropped or duplicated.
@Suite("Usage log JSONL", .serialized)
struct UsageLogJSONLTests {

    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentsmith-usage-jsonl-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func usageDirectory(_ root: URL) -> URL {
        root.appendingPathComponent("AgentSmith", isDirectory: true)
    }

    private func record(taskID: UUID? = nil, sessionID: UUID? = nil, input: Int = 10) -> UsageRecord {
        UsageRecord(
            timestamp: Date(timeIntervalSinceReferenceDate: 812_000_000 + Double(input)),
            agentRole: .brown,
            taskID: taskID,
            modelID: "test-model",
            providerType: "test",
            providerID: "test-provider",
            configuration: nil,
            inputTokens: input,
            outputTokens: 5,
            latencyMs: 100,
            sessionID: sessionID
        )
    }

    @Test("legacy usage_records.json migrates losslessly and is left in place")
    func legacyMigration() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = usageDirectory(root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = [record(input: 1), record(taskID: UUID(), input: 2), record(sessionID: UUID(), input: 3)]
        let legacyURL = directory.appendingPathComponent("usage_records.json")
        let legacyBytes = try JSONEncoder().encode(legacy)
        try legacyBytes.write(to: legacyURL)

        let pm = PersistenceManager(testingRoot: root)
        #expect(try await pm.loadUsageRecords() == legacy)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("usage_records.jsonl").path))
        #expect(try Data(contentsOf: legacyURL) == legacyBytes, "the legacy array is a backup and must not change")

        // Migration runs once: a later append lands in the log, and the legacy file still doesn't move.
        let added = record(input: 4)
        try await pm.appendUsageLogEntries([.record(added)])
        #expect(try await pm.loadUsageRecords() == legacy + [added])
        #expect(try Data(contentsOf: legacyURL) == legacyBytes)
    }

    @Test("a concurrent load and append share one migration")
    func concurrentMigration() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = usageDirectory(root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = (1...200).map { record(input: $0) }
        try JSONEncoder().encode(legacy).write(to: directory.appendingPathComponent("usage_records.json"))

        let pm = PersistenceManager(testingRoot: root)
        let added = record(input: 999)
        async let loaded = pm.loadUsageRecords()
        async let appended: Void = pm.appendUsageLogEntries([.record(added)])
        _ = try await (loaded, appended)
        #expect(try await pm.loadUsageRecords() == legacy + [added])
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("usage_records.jsonl.tmp").path))
    }

    @Test("store append + flush reloads exactly")
    func storeRoundTrip() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = UsageStore(persistence: PersistenceManager(testingRoot: root))
        let appended = (1...25).map { record(input: $0) }
        for item in appended { await first.append(item) }
        await first.flush()

        let second = UsageStore(persistence: PersistenceManager(testingRoot: root))
        await second.load()
        #expect(await second.allRecords() == appended)
    }

    @Test("a backfill row replays only onto the records before it")
    func backfillReplay() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = UUID()
        let otherSession = UUID()
        let existingTask = UUID()
        let backfilledTask = UUID()

        let store = UsageStore(persistence: PersistenceManager(testingRoot: root))
        let unattributed = record(sessionID: session, input: 1)
        let alreadyAttributed = record(taskID: existingTask, sessionID: session, input: 2)
        let otherSessions = record(sessionID: otherSession, input: 3)
        await store.append(unattributed)
        await store.append(alreadyAttributed)
        await store.append(otherSessions)
        await store.backfillTaskID(backfilledTask, forSession: session)
        let afterBackfill = record(sessionID: session, input: 4)
        await store.append(afterBackfill)
        await store.flush()

        let expected = [
            unattributed.withTaskID(backfilledTask),
            alreadyAttributed,
            otherSessions,
            afterBackfill
        ]
        #expect(await store.allRecords() == expected)

        let reloaded = UsageStore(persistence: PersistenceManager(testingRoot: root))
        await reloaded.load()
        #expect(await reloaded.allRecords() == expected, "reload must equal what memory held")
    }

    @Test("a backfill that changes nothing writes no row")
    func noOpBackfillWritesNothing() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UsageStore(persistence: PersistenceManager(testingRoot: root))
        await store.append(record(taskID: UUID(), sessionID: UUID(), input: 1))
        await store.backfillTaskID(UUID(), forSession: UUID())
        await store.flush()
        let lines = try String(contentsOf: usageDirectory(root).appendingPathComponent("usage_records.jsonl"), encoding: .utf8)
            .split(separator: "\n")
        #expect(lines.count == 1)
    }

    @Test("a torn final line is skipped and the next append does not fuse with it")
    func tornFinalLine() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pm = PersistenceManager(testingRoot: root)
        let kept = record(input: 1)
        try await pm.appendUsageLogEntries([.record(kept)])
        let logURL = usageDirectory(root).appendingPathComponent("usage_records.jsonl")
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"id":"half-writ"#.utf8))
        try handle.close()

        #expect(try await pm.loadUsageRecords() == [kept])
        let next = record(input: 2)
        try await pm.appendUsageLogEntries([.record(next)])
        #expect(try await pm.loadUsageRecords() == [kept, next])
    }

    @Test("wire shape: a record line has no rowKind; a backfill line is task_backfill")
    func wireShape() throws {
        let encoder = JSONEncoder()
        let recordObject = try JSONSerialization.jsonObject(
            with: encoder.encode(UsageLogEntry.record(record(input: 1)))) as? [String: Any]
        #expect(recordObject?["rowKind"] == nil)
        #expect(recordObject?["inputTokens"] as? Int == 1)

        let backfill = UsageTaskBackfill(taskID: UUID(), sessionID: UUID())
        let backfillObject = try JSONSerialization.jsonObject(
            with: encoder.encode(UsageLogEntry.taskBackfill(backfill))) as? [String: Any]
        #expect(backfillObject?["rowKind"] as? String == "task_backfill")
        #expect(backfillObject?["taskID"] as? String == backfill.taskID.uuidString)

        #expect(UsageLogRowKind.allCases.map(\.rawValue) == ["task_backfill"])
        let decoded = try JSONDecoder().decode(UsageLogEntry.self, from: encoder.encode(UsageLogEntry.taskBackfill(backfill)))
        #expect(decoded == .taskBackfill(backfill))
    }

    @Test("an unknown rowKind is skipped, not fatal to the history")
    func unknownRowKindSkipped() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pm = PersistenceManager(testingRoot: root)
        let before = record(input: 1)
        try await pm.appendUsageLogEntries([.record(before)])
        let logURL = usageDirectory(root).appendingPathComponent("usage_records.jsonl")
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"rowKind":"from_the_future","x":1}"#.utf8 + [0x0A]))
        try handle.close()
        let after = record(input: 2)
        try await pm.appendUsageLogEntries([.record(after)])
        #expect(try await pm.loadUsageRecords() == [before, after])
    }

    @Test("records appended before load finishes are kept exactly once")
    func appendBeforeLoad() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let seeded = record(input: 1)
        try await PersistenceManager(testingRoot: root).appendUsageLogEntries([.record(seeded)])

        let store = UsageStore(persistence: PersistenceManager(testingRoot: root))
        let early = record(input: 2)
        await store.append(early)
        await store.flush()
        await store.load()
        #expect(await store.allRecords() == [seeded, early])
    }

    /// Opt-in validation against a COPY of a real `usage_records.json`. Set
    /// `AGENTSMITH_REAL_USAGE_RECORDS` to its path; the test copies it under a temp root, migrates
    /// the copy, and checks every record survives. Skipped when unset. Never touches the original.
    @Test("real-file migration validation (opt-in via AGENTSMITH_REAL_USAGE_RECORDS)")
    func realFileValidation() async throws {
        guard let path = ProcessInfo.processInfo.environment["AGENTSMITH_REAL_USAGE_RECORDS"],
              !path.isEmpty else {
            return  // not configured — skip
        }
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = usageDirectory(root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copyURL = directory.appendingPathComponent("usage_records.json")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: copyURL)
        let original = try JSONDecoder().decode([UsageRecord].self, from: Data(contentsOf: copyURL))

        let started = Date()
        let migrated = try await PersistenceManager(testingRoot: root).loadUsageRecords()
        let migrateSeconds = Date().timeIntervalSince(started)
        #expect(migrated == original)

        let reloadStarted = Date()
        let reloaded = try await PersistenceManager(testingRoot: root).loadUsageRecords()
        let reloadSeconds = Date().timeIntervalSince(reloadStarted)
        #expect(reloaded == original)
        print("real usage log: \(original.count) records; migrate+load \(migrateSeconds)s; reload \(reloadSeconds)s")
    }

    @Test("reduceRecords visits every record once, in store order, after backfills")
    func reduceRecordsVisitsStoreOrder() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = UUID()
        let task = UUID()
        let store = UsageStore(persistence: PersistenceManager(testingRoot: root))
        for input in 1...5 { await store.append(record(sessionID: session, input: input)) }
        await store.backfillTaskID(task, forSession: session)
        await store.append(record(input: 6))
        // Flushed before the deferred cleanup, so a late append can't recreate the temp root.
        await store.flush()

        let visited = await store.reduceRecords(into: [UsageRecord]()) { visited, record in
            visited.append(record)
        }
        #expect(visited == (await store.allRecords()))
        #expect(visited.map(\.inputTokens) == Array(1...6))
        #expect(visited.prefix(5).allSatisfy { $0.taskID == task })
        #expect(visited.last?.taskID == nil)
    }

    @Test("writer lines land in call order across many synchronous enqueues")
    func writerOrder() async throws {
        let sink = OrderSink()
        let writer = JSONLAppendWriter<Int>(label: "test") { batch in
            try await Task.sleep(for: .milliseconds(1))
            sink.add(batch)
        }
        for value in 0..<500 { writer.enqueue([value]) }
        #expect(await writer.flush())
        #expect(sink.all() == Array(0..<500))
    }

    private final class OrderSink: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int] = []
        func add(_ batch: [Int]) { lock.withLock { values += batch } }
        func all() -> [Int] { lock.withLock { values } }
    }
}
