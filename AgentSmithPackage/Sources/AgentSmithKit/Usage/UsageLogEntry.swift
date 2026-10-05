import Foundation

/// One line of the append-only `usage_records.jsonl`.
///
/// The log is append-only so that recording a call costs O(one record) instead of re-encoding
/// and rewriting every record ever made (151 MB / 64,859 records when this replaced the
/// whole-array `usage_records.json`, rewritten every five seconds while agents were busy).
///
/// The one operation that CHANGES stored records — `UsageStore.backfillTaskID` — is therefore
/// written as a row of its own and replayed at load, never by editing earlier lines. A record
/// line carries no discriminator, so the file stays a plain list of `UsageRecord` objects to
/// any tool that reads it; every other row kind names itself in `rowKind`.
public enum UsageLogEntry: Sendable, Equatable {
    case record(UsageRecord)
    case taskBackfill(UsageTaskBackfill)
}

/// "Attribute every record of `sessionID` that has no task to `taskID`", as of `timestamp`.
///
/// Applies only to records that precede it in the log — exactly the records the live
/// `backfillTaskID` call could see, since the store appends this row in the same order it
/// mutated memory.
public struct UsageTaskBackfill: Codable, Sendable, Equatable {
    public let taskID: UUID
    public let sessionID: UUID
    public let timestamp: Date

    public init(taskID: UUID, sessionID: UUID, timestamp: Date = Date()) {
        self.taskID = taskID
        self.sessionID = sessionID
        self.timestamp = timestamp
    }
}

/// The `rowKind` discriminator of a non-record line. Closed on purpose: a kind this build does
/// not know was written by a newer build, and the loader counts and reports it rather than
/// guessing what it meant.
public enum UsageLogRowKind: String, Codable, Sendable, CaseIterable {
    case taskBackfill = "task_backfill"
}

extension UsageLogEntry: Codable {
    private enum CodingKeys: String, CodingKey {
        case rowKind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A record line has no `rowKind` at all — that, not a default, is what makes it a record.
        guard container.contains(.rowKind) else {
            self = .record(try UsageRecord(from: decoder))
            return
        }
        switch try container.decode(UsageLogRowKind.self, forKey: .rowKind) {
        case .taskBackfill:
            self = .taskBackfill(try UsageTaskBackfill(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .record(let record):
            try record.encode(to: encoder)
        case .taskBackfill(let backfill):
            try backfill.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(UsageLogRowKind.taskBackfill, forKey: .rowKind)
        }
    }
}

extension UsageLogEntry {
    /// Folds a log into the records it describes, in log order, applying each backfill to the
    /// records before it. The single definition of what the log MEANS — the store's live
    /// mutation and the load-time replay both go through `UsageTaskBackfill.apply(to:)`.
    static func replay(_ entries: [UsageLogEntry]) -> [UsageRecord] {
        var records: [UsageRecord] = []
        records.reserveCapacity(entries.count)
        for entry in entries {
            switch entry {
            case .record(let record):
                records.append(record)
            case .taskBackfill(let backfill):
                _ = backfill.apply(to: &records)
            }
        }
        return records
    }
}

extension UsageTaskBackfill {
    /// Attributes the session's unattributed records to the task. Returns whether anything changed.
    func apply(to records: inout [UsageRecord]) -> Bool {
        var changed = false
        for index in records.indices
        where records[index].sessionID == sessionID && records[index].taskID == nil {
            records[index] = records[index].withTaskID(taskID)
            changed = true
        }
        return changed
    }
}
