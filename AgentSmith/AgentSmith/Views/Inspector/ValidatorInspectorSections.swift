import SwiftUI
import AgentSmithKit

/// The Validator inspector: the verdicts in the ledgers of this session's tasks — every task in its
/// active list (including ones restored here from another session), plus archived and deleted
/// tasks that originated here — grouped by task, then criterion and time.
///
/// Reads the task verdict ledgers directly through `ValidatorVerdictHistory` — there is no
/// separate validator history to drift from what Task Detail shows. The grouping is cached and
/// rebuilt only when some ledger actually changed, not on every task-store write.
struct ValidatorInspectorSections: View {
    let viewModel: AppViewModel

    @State private var groups: [ValidatorVerdictHistory.TaskGroup] = []
    /// What the cached `groups` were built from; a rebuild is skipped while it still matches.
    @State private var builtFrom: [LedgerFingerprint] = []

    /// Identifies a ledger's contents cheaply — its task, record count, newest record, and the
    /// contract it is labelled against — so an unrelated task write doesn't regroup everything.
    fileprivate struct LedgerFingerprint: Equatable {
        let taskID: UUID
        let recordCount: Int
        let newestRecordID: UUID?
        let contractVersion: Int
        let criteriaCount: Int
        let title: String
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ValidatorHistorySummary(groups: groups)
                ForEach(groups) { group in
                    ValidatorTaskGroupSection(group: group)
                }
            }
            .padding(16)
        }
        .task { scheduleRebuild() }
        .onChange(of: viewModel.tasks) { scheduleRebuild() }
        .onChange(of: viewModel.shared.archivedTasks) { scheduleRebuild() }
        .onChange(of: viewModel.shared.deletedTasks) { scheduleRebuild() }
    }

    private func scheduleRebuild() {
        let sessionID = viewModel.session.id
        // The active list is this session's by definition — a task restored here keeps its
        // original `sessionID`, so filtering it would hide verdicts for work running right here.
        // Only the global archived/deleted lists are narrowed to tasks that originated here.
        let inactiveHere = (viewModel.shared.archivedTasks + viewModel.shared.deletedTasks)
            .filter { $0.sessionID == sessionID }
        // A task can appear in more than one list during a move; keep its first occurrence.
        var seen: Set<UUID> = []
        let sessionTasks = (viewModel.tasks + inactiveHere).filter { seen.insert($0.id).inserted }
        let fingerprint = sessionTasks.compactMap(LedgerFingerprint.init)
        guard fingerprint != builtFrom else { return }
        let next = ValidatorVerdictHistory.groups(from: sessionTasks)
        // Project rule: defer @State mutations out of lifecycle / onChange closures.
        DispatchQueue.main.async {
            builtFrom = fingerprint
            groups = next
        }
    }
}

fileprivate extension ValidatorInspectorSections.LedgerFingerprint {
    /// Nil for a task with no verdicts — it contributes nothing to the view.
    init?(_ task: AgentTask) {
        guard let records = task.validation?.verdictRecords, !records.isEmpty else { return nil }
        self.init(taskID: task.id, recordCount: records.count, newestRecordID: records.last?.id,
                  contractVersion: task.validation?.contractVersion ?? 0,
                  criteriaCount: task.acceptanceCriteria.count, title: task.title)
    }
}

private struct ValidatorHistorySummary: View {
    let groups: [ValidatorVerdictHistory.TaskGroup]

    var body: some View {
        let verdictCount = groups.reduce(0) { $0 + $1.entries.count }
        Text(verdictCount == 0
             ? "No validator verdicts are recorded on tasks from this session."
             : "\(verdictCount) verdict\(verdictCount == 1 ? "" : "s") across \(groups.count) task\(groups.count == 1 ? "" : "s") in this session, read from each task's current verdict ledger (retry, reopen, and criteria edits clear or trim a ledger).")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ValidatorTaskGroupSection: View {
    let group: ValidatorVerdictHistory.TaskGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(group.taskTitle)
                .font(.headline)
                .textSelection(.enabled)
            Text(group.taskID.uuidString)
                .font(AppFonts.microMonoBadge)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
            ForEach(group.entries) { entry in
                ValidatorVerdictEntryRow(entry: entry)
            }
        }
    }
}

/// One verdict: criterion, round, outcome, validator identity, and — on demand — its transcripts.
private struct ValidatorVerdictEntryRow: View {
    let entry: ValidatorVerdictHistory.Entry
    @State private var showsTranscripts = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { showsTranscripts.toggle() }, label: {
                ValidatorVerdictEntryHeader(entry: entry, showsTranscripts: showsTranscripts)
                    .contentShape(Rectangle())
            })
            .buttonStyle(.plain)
            .help(showsTranscripts ? "Hide the validator transcripts" : "Show the validator transcripts")
            if let detail = entry.record.verdict.detailText {
                ValidatorVerdictDetailText(text: detail)
            }
            if showsTranscripts {
                VerdictTranscripts(record: entry.record,
                                   inputKind: VerdictInputKind(usesInputEnumerator: entry.usesInputEnumerator))
                    .padding(.leading, 18)
            }
        }
        .padding(6)
        .background(AppColors.subtleRowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// The verdict's reason or error message.
private struct ValidatorVerdictDetailText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .padding(.leading, 18)
    }
}

private struct ValidatorVerdictEntryHeader: View {
    let entry: ValidatorVerdictHistory.Entry
    let showsTranscripts: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: showsTranscripts ? "chevron.down" : "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(ValidatorVerdictLabels.criterion(entry))
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                Text(ValidatorVerdictLabels.meta(entry.record))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(entry.record.recordedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
    }
}

enum ValidatorVerdictLabels {
    static func criterion(_ entry: ValidatorVerdictHistory.Entry) -> String {
        guard let number = entry.criterionNumber, let name = entry.criterionName else {
            return "Removed criterion (\(entry.criterionID.uuidString.prefix(8))…)"
        }
        return "Criterion \(number): \(name)"
    }

    static func meta(_ record: CriterionVerdictRecord) -> String {
        "Round \(record.round) · \(record.verdict.displayLabel) · \(record.validatorName) · \(record.validatorHash.prefix(12))"
    }
}
