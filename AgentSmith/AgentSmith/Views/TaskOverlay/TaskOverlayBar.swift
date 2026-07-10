import SwiftUI
import AgentSmithKit

/// Top-of-window overlay bar: one live panel per in-flight task — the task's todo list
/// exactly as in Task Detail, switching to live acceptance criteria once every step has
/// been done for 5 seconds. Columns are append-only (positions never shift); up to
/// `shared.taskOverlayColumns` show side by side and the rest collect in the overflow
/// menu, which only ever opens tasks into their own floating window. Completed/failed
/// tasks stay until dismissed; a new arrival evicts the first terminal column when the
/// bar is full. The bottom grab handle drags the bar taller/shorter; the chevron
/// collapses it to a one-line strip; the toolbar button hides it entirely.
struct TaskOverlayBar: View {
    @Bindable var viewModel: AppViewModel
    @Bindable var shared: SharedAppState
    @Environment(\.openWindow) private var openWindow

    /// Height mid-drag; committed to `shared.taskOverlayHeight` on gesture end.
    @State private var dragHeight: Double?

    private static let minHeight: Double = 90
    private static let maxHeight: Double = 440

    private var barCapacity: Int { max(1, shared.taskOverlayColumns) }
    private var barEntries: [AppViewModel.TaskOverlayEntry] {
        Array(viewModel.taskOverlayEntries.prefix(barCapacity))
    }
    private var drawerEntries: [AppViewModel.TaskOverlayEntry] {
        Array(viewModel.taskOverlayEntries.dropFirst(barCapacity))
    }
    private var currentHeight: Double {
        min(max(dragHeight ?? shared.taskOverlayHeight, Self.minHeight), Self.maxHeight)
    }

    var body: some View {
        if !viewModel.taskOverlayEntries.isEmpty {
            VStack(spacing: 0) {
                if shared.taskOverlayCollapsed {
                    collapsedStrip
                } else {
                    expandedColumns
                        .frame(height: currentHeight)
                    grabHandle
                }
            }
            .background(AppColors.secondaryBackground)
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    // MARK: - Expanded

    private var expandedColumns: some View {
        HStack(spacing: 0) {
            ForEach(barEntries) { entry in
                if let task = viewModel.tasks.first(where: { $0.id == entry.id }) {
                    TaskOverlayColumn(
                        task: task,
                        entry: entry,
                        onDismiss: { viewModel.dismissTaskOverlayEntry(taskID: task.id) },
                        onTearOff: {
                            openWindow(value: TaskOverlayPanelTarget(sessionID: viewModel.session.id, taskID: task.id))
                            viewModel.tearOffTaskOverlayEntry(taskID: task.id)
                        }
                    )
                    Divider()
                }
            }
            Spacer(minLength: 0)
            trailingControls
        }
    }

    private var trailingControls: some View {
        VStack(spacing: 6) {
            collapseButton(collapsed: false)
            if !drawerEntries.isEmpty {
                drawerMenu
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }

    private var drawerMenu: some View {
        Menu {
            Text("More tasks")
            ForEach(drawerEntries) { entry in
                if let task = viewModel.tasks.first(where: { $0.id == entry.id }) {
                    Button {
                        openWindow(value: TaskOverlayPanelTarget(sessionID: viewModel.session.id, taskID: task.id))
                    } label: {
                        Label(task.title, systemImage: task.status.overlaySymbolName)
                    }
                }
            }
        } label: {
            Text("+\(drawerEntries.count)")
                .font(.caption2.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(AppColors.background))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Tasks beyond the visible columns — opens in a separate window")
    }

    private func collapseButton(collapsed: Bool) -> some View {
        Button {
            shared.taskOverlayCollapsed = !collapsed
        } label: {
            Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Expand task overlay" : "Collapse to strip")
    }

    private var grabHandle: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.secondary.opacity(0.45))
            .frame(width: 44, height: 4)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        dragHeight = min(max(shared.taskOverlayHeight + value.translation.height, Self.minHeight), Self.maxHeight)
                    }
                    .onEnded { _ in
                        if let dragHeight {
                            shared.taskOverlayHeight = dragHeight
                        }
                        dragHeight = nil
                    }
            )
            .onHover { hovering in
                if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
    }

    // MARK: - Collapsed strip

    private var collapsedStrip: some View {
        HStack(spacing: 14) {
            ForEach(barEntries) { entry in
                if let task = viewModel.tasks.first(where: { $0.id == entry.id }) {
                    HStack(spacing: 5) {
                        Image(systemName: task.status.overlaySymbolName)
                            .font(.caption2)
                            .foregroundStyle(task.status.overlayColor)
                        Text(task.title)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                        Text(Self.stripProgress(task))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 0)
            if !drawerEntries.isEmpty {
                Text("+\(drawerEntries.count)")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
            }
            collapseButton(collapsed: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private static func stripProgress(_ task: AgentTask) -> String {
        let active = task.steps.filter(\.isActive)
        if !active.isEmpty {
            let done = active.filter { $0.status == .completed || $0.status == .skipped }.count
            return "\(done)/\(active.count)"
        }
        return task.status.rawValue
    }
}

// MARK: - One task column

/// One task's live panel — shared by the bar column and the torn-off window.
struct TaskOverlayColumn: View {
    let task: AgentTask
    let entry: AppViewModel.TaskOverlayEntry
    var onDismiss: (() -> Void)?
    var onTearOff: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            header
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 3) {
                    if entry.showsCriteria && !task.acceptanceCriteria.isEmpty {
                        criteriaRows
                    } else if !task.steps.filter(\.isActive).isEmpty {
                        stepRows
                        if entry.allStepsDoneAt != nil && !entry.showsCriteria {
                            DwellCountdown(since: entry.allStepsDoneAt ?? Date())
                        }
                    } else {
                        Text("No steps recorded yet.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(task.status.displayName.uppercased())
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(task.status.overlayColor.opacity(0.18)))
                .foregroundStyle(task.status.overlayColor)
            Text(task.title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if let onTearOff {
                Button(action: onTearOff) {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Open in its own window")
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Remove from the bar (task is unaffected)")
            }
        }
    }

    private var stepRows: some View {
        ForEach(task.steps.filter(\.isActive)) { step in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: Self.stepSymbol(step.status))
                    .font(.system(size: 10))
                    .foregroundStyle(Self.stepColor(step.status))
                VStack(alignment: .leading, spacing: 0) {
                    Text(step.text)
                        .font(.caption)
                        .foregroundStyle(step.status == .completed ? .secondary : .primary)
                        .lineLimit(2)
                    if let note = step.note, !note.isEmpty {
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private var criteriaRows: some View {
        ForEach(task.acceptanceCriteria) { criterion in
            let latest = task.validation?.latestVerdict(for: criterion.id)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: Self.verdictSymbol(latest?.verdict))
                    .font(.system(size: 10))
                    .foregroundStyle(Self.verdictColor(latest?.verdict, taskStatus: task.status))
                Text(criterion.text)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if entry.showsCriteria && !task.acceptanceCriteria.isEmpty {
            let settledIDs = task.validation?.settledCriterionIDs() ?? []
            let settled = task.acceptanceCriteria.filter { settledIDs.contains($0.id) }.count
            let round = task.validation?.round ?? 0
            Text("acceptance · \(settled) of \(task.acceptanceCriteria.count) settled\(round > 0 ? " · round \(round)" : "")")
                .font(.caption2)
                .foregroundStyle(task.status == .failed ? AppColors.verdictRejected : Color.secondary.opacity(0.6))
        }
    }

    private static func stepSymbol(_ status: TaskStep.Status) -> String {
        switch status {
        case .pending: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .completed: return "checkmark.circle.fill"
        case .skipped: return "arrow.uturn.right.circle"
        case .removed: return "trash.circle"
        }
    }

    private static func stepColor(_ status: TaskStep.Status) -> Color {
        switch status {
        case .pending: return .secondary
        case .inProgress: return AppColors.stepInProgress
        case .completed: return AppColors.stepCompleted
        case .skipped: return AppColors.stepSkipped
        case .removed: return AppColors.stepRemoved
        }
    }

    private static func verdictSymbol(_ verdict: CriterionVerdictRecord.Verdict?) -> String {
        switch verdict {
        case .accepted: return "checkmark.circle.fill"
        case .rejected: return "xmark.circle.fill"
        case .waived: return "minus.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case nil: return "circle.dotted"
        }
    }

    private static func verdictColor(_ verdict: CriterionVerdictRecord.Verdict?, taskStatus: AgentTask.Status) -> Color {
        switch verdict {
        case .accepted: return AppColors.verdictAccepted
        case .rejected: return AppColors.verdictRejected
        case .waived: return AppColors.verdictWaived
        case .error: return AppColors.verdictError
        case nil: return taskStatus == .validating ? Color.teal : AppColors.verdictPending
        }
    }
}

/// "all steps done — criteria in Ns…" countdown line during the 5-second dwell.
private struct DwellCountdown: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { timeline in
            let remaining = max(0, 5 - Int(timeline.date.timeIntervalSince(since)))
            Text("all steps done — criteria in \(remaining)s…")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Torn-off window

/// Routing target for a torn-off (or junk-drawer-opened) task panel window.
struct TaskOverlayPanelTarget: Codable, Hashable, Sendable {
    let sessionID: UUID
    let taskID: UUID
}

/// The floating window wrapping one task's live panel.
struct TaskOverlayPanelWindow: View {
    let taskID: UUID
    @Bindable var viewModel: AppViewModel

    var body: some View {
        if let task = viewModel.tasks.first(where: { $0.id == taskID }) {
            // Dwell/criteria state follows the bar's entry when present; a torn-off or
            // drawer-opened panel synthesizes it from the task alone.
            let entry = viewModel.taskOverlayEntries.first { $0.id == taskID }
                ?? AppViewModel.TaskOverlayEntry(
                    id: taskID,
                    allStepsDoneAt: nil,
                    showsCriteria: task.status.isTerminal || task.steps.filter(\.isActive).allSatisfy { $0.status == .completed || $0.status == .skipped }
                )
            TaskOverlayColumn(task: task, entry: entry)
                .frame(minWidth: 300, minHeight: 180)
                .navigationTitle(task.title)
        } else {
            ContentUnavailableView(
                "Task Not Found",
                systemImage: "questionmark.circle",
                description: Text("This task's session may have been closed.")
            )
        }
    }
}

// MARK: - Status presentation helpers

private extension AgentTask.Status {
    var overlaySymbolName: String {
        switch self {
        case .running: return "circle.lefthalf.filled"
        case .validating: return "checklist"
        case .awaitingReview: return "person.crop.circle.badge.questionmark"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        default: return "circle"
        }
    }

    var overlayColor: Color {
        switch self {
        case .running: return AppColors.stepInProgress
        case .validating: return .teal
        case .awaitingReview: return .purple
        case .completed: return AppColors.verdictAccepted
        case .failed: return AppColors.verdictRejected
        default: return .secondary
        }
    }

    var displayName: String { rawValue }
}
