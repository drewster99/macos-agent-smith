import Foundation

/// A read-only projection of task verdict ledgers for the Validator inspector.
///
/// The ledgers (`TaskValidationState.verdictRecords`) are the ONE source of validator truth; this
/// type only groups and labels them. It never copies a record into a second store, so the
/// inspector and Task Detail can never disagree about what a validator said. A ledger holds what
/// the task currently carries: retry and reopen clear it and a criteria edit retires the edited
/// criteria's verdicts — the full history is `ValidationMetricsLedger`'s job, not this one's.
public enum ValidatorVerdictHistory {

    /// One task's verdicts, ordered by criterion, then time.
    public struct TaskGroup: Identifiable, Sendable, Equatable {
        public var id: UUID { taskID }
        public let taskID: UUID
        public let taskTitle: String
        public let entries: [Entry]
        /// The newest verdict's timestamp — groups are listed most-recently-judged first.
        public let latestRecordedAt: Date
    }

    /// One verdict record with the labels needed to place it.
    public struct Entry: Identifiable, Sendable, Equatable {
        public var id: UUID { record.id }
        public let criterionID: UUID
        /// 1-based position in the task's CURRENT contract; nil when the record names a criterion
        /// the contract no longer has. Criteria edits normally retire such records, so this is a
        /// defensive case (older ledgers), not a history the store keeps.
        public let criterionNumber: Int?
        /// The criterion's current name; nil when it is no longer on the task.
        public let criterionName: String?
        /// Whether the criterion enumerates its inputs — its record's stored input is then the
        /// enumerator's, not the judged evidence. Nil when the criterion is no longer on the task.
        public let usesInputEnumerator: Bool?
        public let record: CriterionVerdictRecord
    }

    /// Groups every verdict record on `tasks` by task. Tasks with no verdicts are omitted.
    public static func groups(from tasks: [AgentTask]) -> [TaskGroup] {
        var groups: [TaskGroup] = []
        for task in tasks {
            guard let records = task.validation?.verdictRecords, !records.isEmpty else { continue }
            var positions: [UUID: (number: Int, criterion: AcceptanceCriterion)] = [:]
            for (index, criterion) in task.acceptanceCriteria.enumerated() {
                positions[criterion.id] = (index + 1, criterion)
            }
            let entries = records.map { record in
                let current = positions[record.criterionID]
                return Entry(
                    criterionID: record.criterionID,
                    criterionNumber: current?.number,
                    criterionName: current?.criterion.name,
                    usesInputEnumerator: current.map { $0.criterion.effectiveInputEnumeratorPrompt != nil },
                    record: record
                )
            }
            .sorted(by: entryOrder)
            let latest = records.map(\.recordedAt).max() ?? .distantPast
            groups.append(TaskGroup(taskID: task.id, taskTitle: task.title, entries: entries, latestRecordedAt: latest))
        }
        return groups.sorted { lhs, rhs in
            if lhs.latestRecordedAt != rhs.latestRecordedAt { return lhs.latestRecordedAt > rhs.latestRecordedAt }
            return lhs.taskID.uuidString < rhs.taskID.uuidString
        }
    }

    /// Criterion (current contract order; removed criteria last, by id), then time. Not round: a
    /// Re-validate or Send-back restarts round numbering while keeping the ledger, so ordering by
    /// round would interleave separate validation runs.
    private static func entryOrder(_ lhs: Entry, _ rhs: Entry) -> Bool {
        switch (lhs.criterionNumber, rhs.criterionNumber) {
        case let (left?, right?) where left != right: return left < right
        case (.some, nil): return true
        case (nil, .some): return false
        case (nil, nil) where lhs.criterionID != rhs.criterionID:
            return lhs.criterionID.uuidString < rhs.criterionID.uuidString
        default: break
        }
        if lhs.record.recordedAt != rhs.record.recordedAt { return lhs.record.recordedAt < rhs.record.recordedAt }
        if lhs.record.round != rhs.record.round { return lhs.record.round < rhs.record.round }
        return lhs.record.id.uuidString < rhs.record.id.uuidString
    }
}
