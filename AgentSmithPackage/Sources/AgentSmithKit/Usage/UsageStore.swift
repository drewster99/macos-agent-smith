import Foundation
import os

private let logger = Logger(subsystem: "com.agentsmith", category: "UsageStore")

/// Persistent store for LLM token usage records.
///
/// Append-only: records are immutable once stored. Coalesces disk writes
/// to avoid I/O on every LLM call — flushes at most every 5 seconds.
public actor UsageStore {
    private var records: [UsageRecord] = []
    private let persistence: PersistenceManager
    private var isDirty = false
    private var flushTask: Task<Void, Never>?
    /// Fired (fire-and-forget) on every `append`. Subscribers maintain their own
    /// incremental aggregates without re-scanning `records`. Set via
    /// `setOnInsert(_:)`; multiple subscribers should compose into one closure.
    private var onInsert: (@Sendable (UsageRecord) async -> Void)?

    public init(persistence: PersistenceManager) {
        self.persistence = persistence
    }

    /// Registers a fire-and-forget callback invoked after each `append`. Passing `nil`
    /// clears the previously-registered subscriber.
    public func setOnInsert(_ handler: (@Sendable (UsageRecord) async -> Void)?) {
        onInsert = handler
    }

    /// Loads records from disk. Call once at startup.
    public func load() async {
        do {
            records = try await persistence.loadUsageRecords()
            logger.info("Loaded \(self.records.count) usage records")
        } catch {
            logger.error("Failed to load usage records: \(error.localizedDescription)")
        }
    }

    /// Appends a usage record and schedules a coalesced save.
    public func append(_ record: UsageRecord) {
        records.append(record)
        scheduleFlush()
        if let handler = onInsert {
            Task { await handler(record) }
        }
    }

    /// Forces an immediate save. Call on app quit.
    public func flush() async {
        flushTask?.cancel()
        flushTask = nil
        guard isDirty else { return }
        await performSave()
    }

    /// All records, for aggregation queries.
    public func allRecords() -> [UsageRecord] {
        records
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
        var changed = false
        records = records.map { record in
            guard record.sessionID == sessionID, record.taskID == nil else { return record }
            changed = true
            return record.withTaskID(taskID)
        }
        if changed {
            scheduleFlush()
            logger.info("Backfilled task \(taskID.uuidString.prefix(8)) onto unattributed session records")
        }
    }

    // MARK: - Private

    private func scheduleFlush() {
        isDirty = true
        guard flushTask == nil else { return }
        flushTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await self.performSave()
        }
    }

    private func performSave() async {
        isDirty = false
        flushTask = nil
        do {
            try await persistence.saveUsageRecords(records)
        } catch {
            logger.error("Failed to save usage records: \(error.localizedDescription)")
        }
    }
}
