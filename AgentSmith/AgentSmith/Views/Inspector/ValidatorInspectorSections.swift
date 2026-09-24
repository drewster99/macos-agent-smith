import SwiftUI
import AgentSmithKit

/// The Validator inspector: every verdict recorded on tasks that originated in this session,
/// grouped by task, then criterion, round, and time.
///
/// Reads the task verdict ledgers directly through `ValidatorVerdictHistory` — there is no
/// separate validator history to drift from what Task Detail shows. The grouping is cached and
/// rebuilt only when the task lists change, not on every render.
struct ValidatorInspectorSections: View {
    let viewModel: AppViewModel

    @State private var groups: [ValidatorVerdictHistory.TaskGroup] = []

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
        let candidates = viewModel.tasks + viewModel.shared.archivedTasks + viewModel.shared.deletedTasks
        // A task can appear in more than one list during a move; keep its first occurrence.
        var seen: Set<UUID> = []
        let sessionTasks = candidates.filter { task in
            task.sessionID == sessionID && seen.insert(task.id).inserted
        }
        let next = ValidatorVerdictHistory.groups(from: sessionTasks)
        // Project rule: defer @State mutations out of lifecycle / onChange closures.
        DispatchQueue.main.async {
            if groups != next { groups = next }
        }
    }
}

private struct ValidatorHistorySummary: View {
    let groups: [ValidatorVerdictHistory.TaskGroup]

    var body: some View {
        let verdictCount = groups.reduce(0) { $0 + $1.entries.count }
        Text(verdictCount == 0
             ? "No validator verdicts are recorded on tasks from this session."
             : "\(verdictCount) verdict\(verdictCount == 1 ? "" : "s") across \(groups.count) task\(groups.count == 1 ? "" : "s") from this session, read from each task's verdict ledger.")
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
                VerdictTranscripts(record: entry.record)
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
            Text(entry.record.recordedAt, style: .time)
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
