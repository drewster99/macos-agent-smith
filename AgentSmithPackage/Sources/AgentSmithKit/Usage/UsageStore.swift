import Foundation
import os

private let logger = Logger(subsystem: "com.agentsmith", category: "UsageStore")

/// Persistent store for LLM token usage records.
///
/// Persisted as the append-only `usage_records.jsonl`: every change — a new record or a task
/// backfill — is ONE `UsageLogEntry` appended through `logWriter`, in the order it was applied to
/// memory, so the log replays to exactly the in-memory state.
public actor UsageStore {
    private var records: [UsageRecord] = []
    private let logWriter: JSONLAppendWriter<UsageLogEntry>
    private let persistence: PersistenceManager
    /// Fired on every `append`. Subscribers maintain their own incremental
    /// aggregates without re-scanning `records`. Set via `setOnInsert(_:)`;
    /// multiple subscribers should compose into one closure. Delivery is
    /// serialized in append order through `pendingInserts`/`deliveryTask` (see
    /// `append`), so an `async` handler that suspends never observes records out
    /// of order or races a sibling delivery.
    private var onInsert: (@Sendable (UsageRecord) async -> Void)?
    /// Records appended but not yet delivered to `onInsert`, in append order.
    private var pendingInserts: [UsageRecord] = []
    /// The single in-flight drain of `pendingInserts`, or `nil` when idle.
    private var deliveryTask: Task<Void, Never>?

    public init(persistence: PersistenceManager) {
        self.persistence = persistence
        self.logWriter = JSONLAppendWriter(label: "usage_records.jsonl") { entries in
            try await persistence.appendUsageLogEntries(entries)
        }
    }

    /// Registers a fire-and-forget callback invoked after each `append`. Passing `nil`
    /// clears the previously-registered subscriber.
    public func setOnInsert(_ handler: (@Sendable (UsageRecord) async -> Void)?) {
        onInsert = handler
    }

    /// Loads records from disk. Call once at startup.
    ///
    /// A record appended before the load finished is already in the log (or queued for it), so it
    /// is not appended again — but it must not vanish from memory either, which the plain
    /// `records = loaded` this replaced allowed.
    public func load() async {
        do {
            let loaded = try await persistence.loadUsageRecords()
            let loadedIDs = Set(loaded.map(\.id))
            records = loaded + records.filter { !loadedIDs.contains($0.id) }
            logger.info("Loaded \(self.records.count) usage records")
        } catch {
            logger.error("Failed to load usage records: \(error.localizedDescription)")
        }
    }

    /// Appends a usage record and queues it for the log.
    public func append(_ record: UsageRecord) {
        records.append(record)
        logWriter.enqueue([.record(record)])
        // Deliver to `onInsert` in append order via a single drain task. The prior
        // per-append `Task { await handler(record) }` let concurrent deliveries
        // race — an `async` handler could observe records out of order. Buffer
        // here and start one drain if none is running.
        guard onInsert != nil else { return }
        pendingInserts.append(record)
        if deliveryTask == nil {
            deliveryTask = Task { [weak self] in
                await self?.drainInserts()
            }
        }
    }

    /// Delivers buffered inserts to `onInsert` one at a time, in append order.
    private func drainInserts() async {
        while true {
            // Re-read both on every iteration: this actor is reentrant, so the
            // handler and buffer can change across the `await handler(next)` below.
            guard let handler = onInsert, !pendingInserts.isEmpty else {
                // If `onInsert` is transiently nil, do NOT discard `pendingInserts`
                // — leave them buffered and stop. They resume when a handler is set
                // (a fresh `append` while a handler exists restarts the drain).
                deliveryTask = nil
                return
            }
            let next = pendingInserts.removeFirst()
            await handler(next)
        }
    }

    /// Returns once everything recorded so far has been appended to the log. Call on app quit.
    public func flush() async {
        if !(await logWriter.flush()) {
            logger.error("Usage log flush ended with appends still failing; the newest records are in memory only")
        }
    }

    /// All records, for one-shot, user-triggered reads.
    ///
    /// The returned array SHARES this store's buffer (copy-on-write). While any caller still holds
    /// it, the store's next `append` or `backfillTaskID` copies every record ever made (~150 MB at
    /// 65k records) — and an append can land on this actor's executor while the caller is still
    /// iterating. Recurring aggregation folds with `reduceRecords(into:_:)` instead, and nothing
    /// should keep this result in long-lived state.
    public func allRecords() -> [UsageRecord] {
        records
    }

    /// Folds every record, in store order, without exporting the array (see `allRecords()` for why
    /// exporting is expensive). The fold runs on this actor, so `append` and `backfillTaskID` wait
    /// for it to return: keep `update` cheap.
    public func reduceRecords<Result: Sendable>(
        into initial: Result,
        _ update: @Sendable (inout Result, UsageRecord) -> Void
    ) -> Result {
        var result = initial
        for record in records {
            update(&result, record)
        }
        return result
    }

    /// Records for a specific task.
    public func records(for taskID: UUID) -> [UsageRecord] {
        records.filter { $0.taskID == taskID }
    }

    /// Records within a date range.
    public func records(from start: Date, to end: Date) -> [UsageRecord] {
        records.filter { $0.timestamp >= start && $0.timestamp <= end }
    }

    /// Records for a specific agent role.
    public func records(for role: AgentRole) -> [UsageRecord] {
        records.filter { $0.agentRole == role }
    }

    /// Retroactively assigns a task ID to all records in the given session that
    /// currently have no task attribution. Used when Smith's pre-task planning
    /// calls should be charged to the task they ultimately produced.
    public func backfillTaskID(_ taskID: UUID, forSession sessionID: UUID) {
        let backfill = UsageTaskBackfill(taskID: taskID, sessionID: sessionID)
        guard backfill.apply(to: &records) else { return }
        logWriter.enqueue([.taskBackfill(backfill)])
        logger.info("Backfilled task \(taskID.uuidString.prefix(8)) onto unattributed session records")
    }
}
