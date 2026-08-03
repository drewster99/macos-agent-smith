import SwiftUI
import AppKit
import AgentSmithKit
import os

nonisolated private let stopLogger = Logger(subsystem: "com.agentsmith", category: "Stop")

/// Writes the task's UUID string to the system pasteboard so the user can paste it into
/// a tool call, log search, or external note. Used by every task-row context menu.
private func copyTaskIDToPasteboard(_ id: UUID) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(id.uuidString, forType: .string)
}

/// Sidebar task list with active tasks, an optional archived section, and a recently-deleted section.
struct TaskListView: View {
    @Bindable var viewModel: AppViewModel

    @State private var showArchived = false
    @State private var showDeleted = false

    var body: some View {
        let activeTasks = viewModel.activeTaskList
        let archivedTasks = viewModel.archivedTaskList
        let deletedTasks = viewModel.recentlyDeletedTaskList

        Group {
            if activeTasks.isEmpty && archivedTasks.isEmpty && deletedTasks.isEmpty {
                ContentUnavailableView(
                    "No Tasks",
                    systemImage: "checklist",
                    description: Text("Tasks will appear here when Smith creates them.")
                )
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(taskFamilies(for: activeTasks)) { family in
                        TaskFamilyRows(family: family, style: .active, viewModel: viewModel)
                    }

                    if !archivedTasks.isEmpty || !deletedTasks.isEmpty {
                        bucketToggles(archivedCount: archivedTasks.count, deletedCount: deletedTasks.count)
                    }

                    // Group the archived/deleted buckets only when their section is actually shown —
                    // no point building families for a collapsed section on every render.
                    if showArchived && !archivedTasks.isEmpty {
                        TaskSectionHeader(title: "Archived")
                        ForEach(taskFamilies(for: archivedTasks)) { family in
                            TaskFamilyRows(family: family, style: .archived, viewModel: viewModel)
                        }
                    }

                    if showDeleted && !deletedTasks.isEmpty {
                        TaskSectionHeader(title: "Deleted")
                        ForEach(taskFamilies(for: deletedTasks)) { family in
                            TaskFamilyRows(family: family, style: .recentlyDeleted, viewModel: viewModel)
                        }
                    }
                }
            }
        }
        .alert(
            "Cannot Complete Action",
            isPresented: $viewModel.hasTaskActionError,
            actions: { Button("OK") { viewModel.taskActionError = nil } },
            message: { Text(viewModel.taskActionError ?? "") }
        )
    }

    private func taskFamilies(for tasks: [AgentTask]) -> [TaskFamily] {
        let tasksByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        var childrenByParentID: [UUID: [AgentTask]] = [:]
        var parents: [AgentTask] = []

        for task in tasks {
            if let parentTaskID = task.parentTaskID, tasksByID[parentTaskID] != nil {
                childrenByParentID[parentTaskID, default: []].append(task)
            } else {
                parents.append(task)
            }
        }

        return parents.map { parent in
            TaskFamily(parent: parent, children: childrenByParentID[parent.id] ?? [])
        }
    }

    @ViewBuilder
    private func bucketToggles(archivedCount: Int, deletedCount: Int) -> some View {
        HStack(spacing: 16) {
            if archivedCount > 0 {
                Button(action: { showArchived.toggle() }, label: {
                    Label(
                        "Archived (\(archivedCount))",
                        systemImage: showArchived ? "archivebox.fill" : "archivebox"
                    )
                    .font(.caption)
                    .foregroundStyle(showArchived ? .primary : .secondary)
                })
                .buttonStyle(.plain)
            }

            if deletedCount > 0 {
                Button(action: { showDeleted.toggle() }, label: {
                    Label(
                        "Deleted (\(deletedCount))",
                        systemImage: showDeleted ? "trash.fill" : "trash"
                    )
                    .font(.caption)
                    .foregroundStyle(showDeleted ? .red : .secondary)
                })
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct TaskFamily: Identifiable {
    let parent: AgentTask
    let children: [AgentTask]

    var id: UUID { parent.id }
}

private struct TaskFamilyRows: View {
    let family: TaskFamily
    let style: TaskRowStyle
    let viewModel: AppViewModel

    /// Collapse is per-family LOCAL state, not a set owned by the list: toggling one family's run
    /// history re-renders only that family, never the whole sidebar (and never re-groups the other
    /// buckets). Finished-run history starts expanded. Persists across live task updates because the
    /// family view keeps a stable identity (`family.id`).
    @State private var isCollapsed = false

    var body: some View {
        // Partition the children ONCE per body pass. `filter` isn't cached across property accesses,
        // so pulling live/finished out as locals avoids re-filtering the (possibly large, for a
        // template with many runs) child list several times per render.
        let children = family.children
        // Live runs — pending, starting, running, validating, paused, interrupted, scheduled,
        // awaiting review. Pinned above the history and NEVER hidden by collapsing: a run you can no
        // longer see is exactly the one you'd want to have noticed.
        let liveChildren = children.filter { !$0.status.isTerminal }
        // Finished runs (`.completed` / `.failed`) — the history the disclosure toggles.
        let finishedChildren = children.filter { $0.status.isTerminal }
        let hasChildren = !children.isEmpty

        let disclosure: TaskRunListDisclosure? = finishedChildren.isEmpty ? nil : TaskRunListDisclosure(
            isCollapsed: isCollapsed,
            hiddenRunCount: finishedChildren.count,
            toggle: { isCollapsed.toggle() }
        )

        // A row heading its own runs must be a standard card regardless of parentage: the summary
        // line and its expand/collapse control only exist in that layout, so a compact row here
        // would render children with no way to collapse them. A childless template run stays compact
        // unless it's a true top-level task — keying on `parentTaskID`, not nesting, keeps a run's
        // presentation stable no matter which bucket it lands in.
        let density: TaskRowDensity = hasChildren
            ? .standard
            : (family.parent.parentTaskID == nil ? .standard : .compact)

        VStack(alignment: .leading, spacing: 0) {
            TaskListRow(
                task: family.parent,
                style: style,
                density: density,
                disclosure: disclosure,
                viewModel: viewModel
            )

            if hasChildren {
                // Live runs first and unconditionally; history below, only when expanded.
                ForEach(liveChildren) { child in
                    childRow(child)
                }
                if !isCollapsed {
                    ForEach(finishedChildren) { child in
                        childRow(child)
                    }
                }
                // The child block carries no internal rules, so this is what closes it off
                // from the next top-level task.
                if !liveChildren.isEmpty || !isCollapsed {
                    Divider()
                }
            }
        }
    }

    /// Child runs are indented and tinted as a block. There's deliberately no connector rail:
    /// drawn per row it broke into dashes at every row's vertical padding, and the indent plus
    /// the shared background already say "these belong to the task above".
    ///
    /// The indent is handed to the row rather than applied here as padding: padding outside
    /// `TaskListRow` sits outside the row's own Button and `.contextMenu`, which made the
    /// indent strip a dead zone that swallowed both left- and right-clicks even though it
    /// looks like part of the row.
    private func childRow(_ task: AgentTask) -> some View {
        TaskListRow(task: task, style: style, density: .compact, indent: 16, viewModel: viewModel)
            .frame(maxWidth: .infinity)
            .background(AppColors.subtleRowBackground.opacity(0.35))
    }
}

// MARK: - Section header

private struct TaskSectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(.caption2, design: .monospaced, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.subtleRowBackground)
    }
}

/// Verb for the "run this task now" affordance — "Resume" reads better for a task that
/// already started once (`paused` / `interrupted`); "Run" for one that never has.
func runActionTitle(for status: AgentTask.Status) -> String {
    switch status {
    case .paused, .interrupted: return "Resume"
    default: return "Run"
    }
}

// MARK: - Timestamp helpers

private func taskTimestamp(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) {
        return date.formatted(date: .omitted, time: .shortened)
    } else if calendar.isDateInYesterday(date) {
        return "Yesterday"
    } else {
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// Timestamp for a compact row. Unlike `taskTimestamp` this ALWAYS carries the time of day:
/// compact rows are template runs, and a column of identical "Yesterday" labels can't tell
/// the 7:42 PM run from the 11:37 PM one — which is the whole reason the timestamp is on
/// the row.
private func compactTaskTimestamp(_ date: Date) -> String {
    let time = date.formatted(date: .omitted, time: .shortened)
    if Calendar.current.isDateInToday(date) {
        return time
    }
    // Assembled rather than asking one format for both parts, so the day and time sit side
    // by side without the locale's connective ("Jul 22 at 10:41 PM") eating row width.
    return "\(date.formatted(.dateTime.month(.abbreviated).day())) \(time)"
}

/// Future-fire-time label for a scheduled task. Today → bare time ("9:00 PM");
/// tomorrow → "Tomorrow 9:00 AM"; within a week → weekday + time; further out →
/// month/day + time. Shared by the task list rows and the channel log's New Task
/// banner so the formatting stays consistent.
func formatScheduledTime(_ date: Date) -> String {
    let calendar = Calendar.current
    let time = date.formatted(date: .omitted, time: .shortened)
    if calendar.isDateInToday(date) {
        return time
    }
    if calendar.isDateInTomorrow(date) {
        return "Tomorrow \(time)"
    }
    let now = Date()
    if let weekFromNow = calendar.date(byAdding: .day, value: 7, to: now), date < weekFromNow {
        let weekday = date.formatted(.dateTime.weekday(.abbreviated))
        return "\(weekday) \(time)"
    }
    let day = date.formatted(.dateTime.month(.abbreviated).day())
    return "\(day) \(time)"
}

// MARK: - Unified task row

/// Visual variant for `TaskRow`. Drives icon opacity, foreground styling, line limits,
/// and whether the row shows running controls or a strikethrough title.
enum TaskRowStyle {
    case active
    case archived
    case recentlyDeleted
}

/// How much room a row is allowed to occupy. `.standard` is the full card — title,
/// description, and a metadata strip. `.compact` is the single-line variant used for a
/// template's child runs: every run inherits the parent's description verbatim, so
/// repeating it costs four lines of sidebar per run and says nothing. Compact keeps only
/// what actually varies between runs — cost, elapsed, grade, and time — and folds the
/// graded outcome into the leading icon.
enum TaskRowDensity {
    case standard
    case compact
}

/// Expand/collapse control for the run list beneath a parent task row, surfaced on the
/// parent's summary line. `nil` when there is nothing to toggle — the row heads no runs, or
/// every run it heads is still in flight, and those never collapse.
struct TaskRunListDisclosure {
    let isCollapsed: Bool
    /// How many finished runs collapsing would hide. Drives the control's tooltip.
    let hiddenRunCount: Int
    let toggle: () -> Void
}

/// Wraps a `TaskRow` in the click-to-open Button + the role-appropriate context menu.
/// Kept separate from `TaskRow` so the row body itself is purely presentational and
/// can be Equatable-shortcut on its inputs.
struct TaskRowButton: View {
    let task: AgentTask
    let style: TaskRowStyle
    let density: TaskRowDensity
    var disclosure: TaskRunListDisclosure?
    var indent: CGFloat = 0
    let viewModel: AppViewModel

    @Environment(\.openWindow) private var openWindow
    @State private var templateRunInputTask: AgentTask?
    @State private var taskEditorTask: AgentTask?
    @State private var sendBackTask: AgentTask?

    var body: some View {
        TaskRow(
            task: task,
            style: style,
            density: density,
            disclosure: disclosure,
            indent: indent,
            viewModel: viewModel,
            onStartRunnableTask: startRunnableTask
        )
        .contentShape(Rectangle())
        .background(task.id == viewModel.selectedTaskID
            ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.25)
            : Color.clear)
        // Single-click SELECTS (drives the top transcript pane); double-click opens the detail
        // window. Nested buttons (cost chip, play/pause) still consume their own taps first.
        .onTapGesture(count: 2) { openTaskDetail() }
        .onTapGesture { viewModel.selectedTaskID = task.id }
        .contextMenu { contextMenu(task: task, style: style, viewModel: viewModel) }
        .sheet(item: $templateRunInputTask) { task in
            TemplateRunInputSheet(
                task: task,
                onRun: { values in
                    templateRunInputTask = nil
                    Task { await viewModel.startTask(task, templateInputValues: values) }
                },
                onCancel: { templateRunInputTask = nil }
            )
        }
        .sheet(item: $taskEditorTask) { task in
            TaskEditorSheet(mode: .edit(task), viewModel: viewModel) {
                taskEditorTask = nil
            }
        }
        .sheet(item: $sendBackTask) { task in
            SendBackToBrownSheet(
                task: task,
                onSend: { feedback in
                    sendBackTask = nil
                    Task { await viewModel.sendEscalatedTaskBackToBrown(id: task.id, feedback: feedback) }
                },
                onCancel: { sendBackTask = nil }
            )
        }
    }

    /// Opens the standalone Task Detail window for this row's task (single-click now selects instead).
    private func openTaskDetail() {
        AgentSmithApp.showOrOpenTaskDetail(
            target: TaskDetailTarget(sessionID: viewModel.session.id, taskID: task.id),
            openWindow: openWindow
        )
    }

    @ViewBuilder
    private func contextMenu(task: AgentTask, style: TaskRowStyle, viewModel: AppViewModel) -> some View {
        Button(action: { openTaskDetail() }, label: {
            Label("Open Details", systemImage: "info.circle")
        })
        Button(action: { copyTaskIDToPasteboard(task.id) }, label: {
            Label("Copy Task ID", systemImage: "doc.on.doc")
        })
        if task.status.isDescriptionEditable {
            Button(action: { taskEditorTask = task }, label: {
                Label("Edit", systemImage: "pencil")
            })
        }
        Divider()
        switch style {
        case .active:
            activeMenu(task: task, viewModel: viewModel)
        case .archived:
            Button(action: { Task { await viewModel.unarchiveTask(id: task.id) } }, label: {
                Label("Unarchive", systemImage: "arrow.uturn.backward")
            })
            Divider()
            Button(role: .destructive, action: { Task { await viewModel.deleteTask(id: task.id) } }, label: {
                Label("Delete", systemImage: "trash")
            })
        case .recentlyDeleted:
            Button(action: { Task { await viewModel.undeleteTask(id: task.id) } }, label: {
                Label("Undelete", systemImage: "arrow.uturn.backward")
            })
            Divider()
            Button(role: .destructive, action: { Task { await viewModel.permanentlyDeleteTask(id: task.id) } }, label: {
                Label("Delete Permanently", systemImage: "trash.fill")
            })
        }
    }

    @ViewBuilder
    private func activeMenu(task: AgentTask, viewModel: AppViewModel) -> some View {
        switch task.status {
        case .completed:
            Button(action: { Task { await viewModel.runTaskAgain(task) } }, label: {
                Label("Run Again", systemImage: "arrow.clockwise")
            })
            Button(action: { Task { await viewModel.exportTaskPDFAndOpen(task, options: .full) } }, label: {
                Label("PDF", systemImage: "doc.richtext")
            })
            Button(action: { Task { await viewModel.archiveTask(id: task.id) } }, label: {
                Label("Archive", systemImage: "archivebox")
            })
            Divider()
            Button(role: .destructive, action: { Task { await viewModel.deleteTask(id: task.id) } }, label: {
                Label("Delete", systemImage: "trash")
            })

        case .failed:
            Button(action: { Task { await viewModel.retryTask(task) } }, label: {
                Label("Retry", systemImage: "arrow.clockwise")
            })
            Button(action: { Task { await viewModel.archiveTask(id: task.id) } }, label: {
                Label("Archive", systemImage: "archivebox")
            })
            Divider()
            Button(role: .destructive, action: { Task { await viewModel.deleteTask(id: task.id) } }, label: {
                Label("Delete", systemImage: "trash")
            })

        case .starting, .running, .validating:
            Button(action: {
                let slug = task.id.uuidString.prefix(8)
                stopLogger.notice("UI.taskCard contextMenu Pause clicked task=\(slug, privacy: .public)")
                Task {
                    stopLogger.notice("UI.taskCard contextMenu Pause Task body running task=\(slug, privacy: .public)")
                    await viewModel.pauseTask(id: task.id)
                    stopLogger.notice("UI.taskCard contextMenu Pause Task body returned task=\(slug, privacy: .public)")
                }
            }, label: {
                Label("Pause", systemImage: "pause.fill")
            })
            Button(action: {
                let slug = task.id.uuidString.prefix(8)
                stopLogger.notice("UI.taskCard contextMenu Stop clicked task=\(slug, privacy: .public)")
                Task {
                    stopLogger.notice("UI.taskCard contextMenu Stop Task body running task=\(slug, privacy: .public)")
                    await viewModel.stopTask(id: task.id)
                    stopLogger.notice("UI.taskCard contextMenu Stop Task body returned task=\(slug, privacy: .public)")
                }
            }, label: {
                Label("Stop", systemImage: "stop.fill")
            })
            Divider()
            Button(action: { Task { await viewModel.archiveTask(id: task.id) } }, label: {
                Label("Archive", systemImage: "archivebox")
            })
            Button(role: .destructive, action: { Task { await viewModel.deleteTask(id: task.id) } }, label: {
                Label("Delete", systemImage: "trash")
            })

        case .awaitingReview:
            escalationMenu(task: task, viewModel: viewModel)
        case .awaitingHelp:
            EmptyView()

        case .pending, .paused, .interrupted:
            Button(action: { startRunnableTask(task) }, label: {
                Label(runActionTitle(for: task.status), systemImage: "play.fill")
            })
            Divider()
            Button(action: { Task { await viewModel.archiveTask(id: task.id) } }, label: {
                Label("Archive", systemImage: "archivebox")
            })
            Divider()
            Button(role: .destructive, action: { Task { await viewModel.deleteTask(id: task.id) } }, label: {
                Label("Delete", systemImage: "trash")
            })

        case .scheduled:
            Button(action: { Task { await viewModel.archiveTask(id: task.id) } }, label: {
                Label("Archive", systemImage: "archivebox")
            })
            Divider()
            Button(role: .destructive, action: { Task { await viewModel.deleteTask(id: task.id) } }, label: {
                Label("Delete", systemImage: "trash")
            })
        }
    }

    /// Actions for a task parked in `.awaitingReview` by a validation escalation — the user's
    /// resolutions now that Smith no longer reviews. A missing-validator config park
    /// (`validationBlockedReason` set) auto-releases when a Validator model is assigned, so it offers
    /// nothing here.
    @ViewBuilder
    private func escalationMenu(task: AgentTask, viewModel: AppViewModel) -> some View {
        if task.validationBlockedReason == nil {
            Button(action: { Task { await viewModel.revalidateEscalatedTask(id: task.id) } }, label: {
                Label("Re-validate", systemImage: "arrow.clockwise")
            })
            Button(action: { sendBackTask = task }, label: {
                Label("Send Back to Brown…", systemImage: "arrowshape.turn.up.left")
            })
            Divider()
            Button(action: { Task { await viewModel.acceptEscalatedTask(id: task.id) } }, label: {
                Label("Accept As-Is", systemImage: "checkmark.circle")
            })
            Button(role: .destructive, action: { Task { await viewModel.failEscalatedTask(id: task.id) } }, label: {
                Label("Fail", systemImage: "xmark.circle")
            })
        }
    }

    private func startRunnableTask(_ task: AgentTask) {
        if task.shouldPromptForTemplateRunInputs {
            templateRunInputTask = task
            return
        }
        Task { await viewModel.startTask(task) }
    }
}

/// Roll-up of every run a parent task has spawned, for the parent's summary line.
/// `nil` when the task has no runs — an ordinary task shows no summary.
private struct TaskFamilySummary {
    let runCount: Int
    let buckets: [Bucket]
    let totalCost: Double
    let totalElapsed: TimeInterval

    /// One "10 Success" group. Runs are bucketed by the same verdict the row itself shows —
    /// graded result where there is one, lifecycle status otherwise — so the summary and the
    /// rows beneath it can never disagree about how a run turned out.
    struct Bucket: Identifiable {
        let label: String
        let count: Int
        let color: Color

        var id: String { label }
    }

    /// `runs` is the parent's already-fetched run list (see `TaskRow.childRuns`), threaded in so
    /// one `childTasks(of:)` scan per row render feeds both the cost loader and this roll-up
    /// rather than each re-deriving it.
    init?(runs: [AgentTask], viewModel: AppViewModel) {
        guard !runs.isEmpty else { return nil }

        var countsByLabel: [String: Int] = [:]
        var colorsByLabel: [String: Color] = [:]
        var cost: Double = 0
        var elapsed: TimeInterval = 0

        for run in runs {
            let label: String
            let color: Color
            if let outcome = run.outcome {
                label = outcome.label
                color = TaskOutcomeBadge.color(for: outcome)
            } else {
                label = run.status.displayName
                color = TaskStatusBadge.color(for: run.status)
            }
            countsByLabel[label, default: 0] += 1
            colorsByLabel[label] = color

            cost += viewModel.cachedTaskCost(run.id) ?? 0
            // Only finished runs contribute time — an in-flight run's elapsed would be frozen
            // at the last redraw rather than ticking, quietly understating the total.
            if run.completedAt != nil, let seconds = run.elapsedSeconds {
                elapsed += seconds
            }
        }

        runCount = runs.count
        totalCost = cost
        totalElapsed = elapsed
        buckets = countsByLabel
            .map { Bucket(label: $0.key, count: $0.value, color: colorsByLabel[$0.key] ?? .secondary) }
            // Count first, then label, so the order is stable across redraws rather than
            // inheriting the dictionary's.
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.label < $1.label }
    }
}

/// Single row layout shared by all three buckets. The `style` argument drives the small
/// presentational deltas (icon opacity, line limits, strikethrough, etc.) so we don't
/// duplicate the layout three times. With `AgentTask: Equatable`, SwiftUI's per-input
/// diff at the ForEach boundary skips unchanged rows when only one task in the array
/// mutates.
private struct TaskRow: View {
    let task: AgentTask
    let style: TaskRowStyle
    let density: TaskRowDensity
    let disclosure: TaskRunListDisclosure?
    let indent: CGFloat
    let viewModel: AppViewModel
    let onStartRunnableTask: (AgentTask) -> Void

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Resolve the run list ONCE per body pass and thread it into both the layout and the
        // summary. `childTasks(of:)` scans the active + archived lists, so the earlier
        // per-piece re-derivation cost a standard row a few full scans on every redraw.
        let runs = childRuns
        Group {
            switch density {
            case .standard: standardLayout(runs: runs)
            case .compact: compactLayout()
            }
        }
        .contentShape(Rectangle())
    }

    /// Runs spawned by this task, across active and archived. Empty by construction for
    /// compact rows, which show no summary.
    private var childRuns: [AgentTask] {
        density == .standard ? viewModel.childTasks(of: task.id) : []
    }

    // MARK: Layouts

    @ViewBuilder
    private func standardLayout(runs: [AgentTask]) -> some View {
        HStack(alignment: .top, spacing: 8) {
            leadingStatusOrOutcome()

            VStack(alignment: .leading, spacing: 3) {
                titleRow()

                if style != .recentlyDeleted {
                    descriptionText()
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    metadataLine()
                    // Last line of the card: it summarizes the block of runs printed directly
                    // beneath it and carries that block's expand/collapse control, so the
                    // control sits against the thing it opens.
                    familySummaryLine(runs: runs)
                } else {
                    descriptionText()
                        .lineLimit(1)
                }
            }

            if style == .recentlyDeleted {
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// One line: icon, title, then the run-specific numbers right-aligned. The trailing
    /// group is `fixedSize` + higher layout priority so the title — the only part that can
    /// be truncated without losing information the row exists to convey — absorbs the
    /// squeeze in a narrow sidebar.
    @ViewBuilder
    private func compactLayout() -> some View {
        HStack(spacing: 6) {
            leadingStatusOrOutcome()

            titleText()
                .frame(maxWidth: .infinity, alignment: .leading)

            compactMetadata()
                .fixedSize()
                .layoutPriority(1)
        }
        .padding(.leading, 10 + indent)
        .padding(.trailing, 10)
        .padding(.vertical, 3)
        .opacity(finishedRunOpacity)
    }

    /// Finished runs step back so the ones still in flight read first in a stack of them.
    /// Active bucket only — `.archived` and `.recentlyDeleted` already dim wholesale via
    /// `style`, and a second reduction stacked on top makes them unreadable.
    private var finishedRunOpacity: Double {
        style == .active && task.status.isTerminal ? 0.6 : 1
    }

    /// Cost, elapsed, and time — the fields that differ between two runs of the same template,
    /// each in a right-aligned column of fixed minimum width so the numbers line up down a
    /// stack of runs and can be compared by eye. `minWidth` rather than a hard width: an
    /// unusually long value (a multi-hour run, a "Next: …" schedule pill) pushes its
    /// neighbours left on that one row instead of being clipped.
    ///
    /// Anything variable-width — the attachment pip, the running controls — sits ahead of the
    /// columns, where it can't knock them out of alignment.
    @ViewBuilder
    private func compactMetadata() -> some View {
        HStack(spacing: 6) {
            if attachmentCount > 0 {
                attachmentPip()
            }

            if style == .active && (task.status == .running || task.status == .validating) {
                runningInlineControls()
            } else if style == .active && task.status.isRunnable {
                runInlineControl()
            }

            costChip()
                .frame(minWidth: 40, alignment: .trailing)
            compactElapsedText()
                .frame(minWidth: 54, alignment: .trailing)
            compactTimeLabel()
                .frame(minWidth: 88, alignment: .trailing)
        }
    }

    /// Roll-up of every run this task has spawned — count, how they turned out, total spend,
    /// total time. A recurring template's own row otherwise says nothing about the thing the
    /// user actually wants to know, which is how the schedule has been going; its individual
    /// runs are scattered across the active and archived buckets.
    @ViewBuilder
    private func familySummaryLine(runs: [AgentTask]) -> some View {
        if let summary = TaskFamilySummary(runs: runs, viewModel: viewModel) {
            HStack(spacing: 8) {
                runListToggle(runCount: summary.runCount)

                ForEach(summary.buckets) { bucket in
                    Text("\(bucket.count) \(bucket.label)")
                        .foregroundStyle(bucket.color)
                }

                Spacer(minLength: 4)

                if summary.totalCost > 0 {
                    Text(String(format: "$%.2f", summary.totalCost))
                        .foregroundStyle(.orange)
                }
                if summary.totalElapsed > 0 {
                    Text(durationDisplayString(summary.totalElapsed))
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption2.monospacedDigit())
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(style == .active ? 1 : 0.6)
        }
    }

    /// The run count doubles as the expand/collapse control for the run list below. Plain text
    /// when there's no history to hide — a chevron that toggles nothing is worse than none.
    @ViewBuilder
    private func runListToggle(runCount: Int) -> some View {
        let label = "\(runCount) run\(runCount == 1 ? "" : "s")"
        if let disclosure {
            Button(action: disclosure.toggle, label: {
                HStack(spacing: 3) {
                    Image(systemName: disclosure.isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                    Text(label)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            })
            .buttonStyle(.plain)
            .help(
                disclosure.isCollapsed
                    ? "Show \(disclosure.hiddenRunCount) finished run\(disclosure.hiddenRunCount == 1 ? "" : "s")"
                    : "Hide finished runs"
            )
        } else {
            Text(label)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func compactElapsedText() -> some View {
        if task.completedAt != nil, let elapsed = task.elapsedDisplayString {
            Text(elapsed)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func compactTimeLabel() -> some View {
        switch style {
        case .active:
            ScheduledRunsIndicator(task: task, density: density, viewModel: viewModel)
        case .archived, .recentlyDeleted:
            // START of the run (when it began), not last-modified — matches the spending
            // dashboard's Started column. Falls back to creation for a task that never ran.
            Text(compactTaskTimestamp(task.startedAt ?? task.createdAt))
                .font(.caption2)
                .foregroundStyle(.quaternary)
        }
    }

    // MARK: Pieces

    /// The row's single verdict slot: a task's RESULT when it has one, its lifecycle STATUS
    /// otherwise. The two never appear together — a graded result only exists for a task that
    /// already reached a judged endpoint, so pairing it with a status icon states the same
    /// fact twice and costs a row the width to say something new. Same chip the task detail
    /// window uses for its Result line, so the two surfaces read identically.
    @ViewBuilder
    private func leadingStatusOrOutcome() -> some View {
        if let outcome = task.outcome {
            TaskOutcomeChip(outcome: outcome)
                .opacity(style == .active ? 1 : 0.55)
                .layoutPriority(1)
                .padding(.top, density == .standard ? 1 : 0)
        } else {
            statusIcon()
        }
    }

    @ViewBuilder
    private func statusIcon() -> some View {
        Image(systemName: statusIconName)
            .foregroundStyle(iconForeground)
            .font(density == .compact ? .caption : nil)
            .imageScale(.medium)
            .frame(width: density == .compact ? 13 : 18)
            .padding(.top, standardStatusIconTopPadding)
            .symbolEffect(
                .rotate,
                options: .repeat(.continuous),
                isActive: style == .active && task.status == .running
            )
            // With the status word gone from the row, hover is where the exact lifecycle
            // state (paused vs interrupted vs scheduled — all circle-ish glyphs) still lives.
            .help(task.status.displayName)
    }

    private var standardStatusIconTopPadding: CGFloat {
        guard density == .standard else { return 0 }
        return style == .recentlyDeleted ? 0 : 2
    }

    private var statusIconName: String {
        if style == .active, hasScheduledWakes, task.status != .starting, task.status != .running, task.status != .validating {
            return "clock"
        }
        return TaskStatusBadge.icon(for: task.status)
    }

    private var iconForeground: AnyShapeStyle {
        switch style {
        case .active:
            if hasScheduledWakes, task.status != .starting, task.status != .running, task.status != .validating {
                return AnyShapeStyle(TaskStatusBadge.color(for: .scheduled))
            }
            return AnyShapeStyle(TaskStatusBadge.color(for: task.status))
        case .archived:
            return AnyShapeStyle(TaskStatusBadge.color(for: task.status).opacity(0.5))
        case .recentlyDeleted:
            return AnyShapeStyle(AppColors.dimSecondary35)
        }
    }

    @ViewBuilder
    private func titleRow() -> some View {
        HStack(spacing: 6) {
            titleText()
                .frame(maxWidth: .infinity, alignment: .leading)

            if task.isTemplate {
                templatePip()
            }

            if attachmentCount > 0 {
                attachmentPip()
            }

            if style == .active && (task.status == .running || task.status == .validating) {
                runningInlineControls()
            } else if style == .active && task.status.isRunnable {
                runInlineControl()
            }
        }
    }

    @ViewBuilder
    private func runInlineControl() -> some View {
        Button(action: { onStartRunnableTask(task) }, label: {
            Image(systemName: "play.fill")
                .imageScale(.small)
                .foregroundStyle(.secondary)
        })
        .buttonStyle(.plain)
        .help(runActionTitle(for: task.status))
    }

    /// Total attachments referenced anywhere on the task — description, every update,
    /// and the result. Used by the sidebar pip to indicate "this task carries files."
    private var attachmentCount: Int {
        task.descriptionAttachments.count
            + task.updates.reduce(0) { $0 + $1.attachments.count }
            + task.resultAttachments.count
    }

    @ViewBuilder
    private func templatePip() -> some View {
        HStack(spacing: 2) {
            Image(systemName: "doc.on.doc")
                .imageScale(.small)
            Text("Template")
                .font(.caption2)
        }
        .foregroundStyle(.tertiary)
        .help("Template — starting it clones a fresh instance to run")
    }

    @ViewBuilder
    private func attachmentPip() -> some View {
        HStack(spacing: 2) {
            Image(systemName: "paperclip")
                .imageScale(.small)
            Text("\(attachmentCount)")
                .font(.caption2.monospacedDigit())
        }
        .foregroundStyle(.secondary)
        .help("\(attachmentCount) attachment\(attachmentCount == 1 ? "" : "s")")
    }

    @ViewBuilder
    private func titleText() -> some View {
        let isCompact = density == .compact
        let font = isCompact ? AppFonts.taskTitleCompact : AppFonts.taskTitle
        switch style {
        case .active:
            Text(task.title)
                .font(font)
                .lineLimit(isCompact ? 1 : 2)
                .truncationMode(compactTruncation)
        case .archived:
            Text(task.title)
                .font(font)
                .lineLimit(isCompact ? 1 : 2)
                .truncationMode(compactTruncation)
                .foregroundStyle(.secondary)
        case .recentlyDeleted:
            Text(task.title)
                .font(font)
                .lineLimit(1)
                .truncationMode(compactTruncation)
                .foregroundStyle(.tertiary)
                .strikethrough(true, color: .secondary)
        }
    }

    /// Runs of the same template share a long common prefix ("Monitor iMessages for commands
    /// from …"), so tail truncation clips away the only part that ever differs. Middle
    /// truncation keeps both ends and drops the boilerplate in between.
    private var compactTruncation: Text.TruncationMode {
        density == .compact ? .middle : .tail
    }

    @ViewBuilder
    private func runningInlineControls() -> some View {
        HStack(spacing: 6) {
            Button(action: {
                let slug = task.id.uuidString.prefix(8)
                stopLogger.notice("UI.taskCard inline Pause clicked task=\(slug, privacy: .public)")
                Task {
                    stopLogger.notice("UI.taskCard inline Pause Task body running task=\(slug, privacy: .public)")
                    await viewModel.pauseTask(id: task.id)
                    stopLogger.notice("UI.taskCard inline Pause Task body returned task=\(slug, privacy: .public)")
                }
            }, label: {
                Image(systemName: "pause.fill")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            })
            .buttonStyle(.plain)
            .help("Pause")

            Button(action: {
                let slug = task.id.uuidString.prefix(8)
                stopLogger.notice("UI.taskCard inline Stop clicked task=\(slug, privacy: .public)")
                Task {
                    stopLogger.notice("UI.taskCard inline Stop Task body running task=\(slug, privacy: .public)")
                    await viewModel.stopTask(id: task.id)
                    stopLogger.notice("UI.taskCard inline Stop Task body returned task=\(slug, privacy: .public)")
                }
            }, label: {
                Image(systemName: "stop.fill")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            })
            .buttonStyle(.plain)
            .help("Stop")
        }
    }

    /// Metadata strip rendered below the description: cost (left, orange) and
    /// the style-specific status / timestamp (right). Visible on `.active` and
    /// `.archived` rows; `.recentlyDeleted` rows skip this entirely.
    @ViewBuilder
    private func metadataLine() -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            costChip()
            elapsedChip()

            Spacer(minLength: 0)

            switch style {
            case .active:
                if task.status != .running {
                    ScheduledRunsIndicator(task: task, density: density, viewModel: viewModel)
                }
            case .archived:
                Text(taskTimestamp(task.startedAt ?? task.createdAt))
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
                    .fixedSize()
            case .recentlyDeleted:
                EmptyView()
            }
        }
    }

    private var hasScheduledWakes: Bool {
        !(viewModel.pendingWakesByTaskID[task.id] ?? []).isEmpty
    }

    /// Estimated cost chip. Reads from the cache populated by the row-level
    /// `.task(id:)` loader — never queries `UsageStore` itself. Rendered in
    /// orange so the eye picks it out at a glance. Shows for any task with
    /// non-zero accrued cost, regardless of status — a failed task that burned
    /// real money is information the user needs.
    @ViewBuilder
    private func costChip() -> some View {
        if let cost = viewModel.cachedTaskCost(task.id), cost > 0 {
            // A nested plain button: clicking the money opens the standalone Task Cost window,
            // while clicking anywhere else on the row still opens Task Detail (the outer button).
            Button(action: {
                AgentSmithApp.showOrOpenTaskCostDetail(taskID: task.id, openWindow: openWindow)
            }, label: {
                Text(String(format: "$%.2f", cost))
                    .font(density == .compact ? .caption2.monospacedDigit() : .caption.monospacedDigit())
                    .foregroundStyle(.orange)
                    .fixedSize()
            })
            .buttonStyle(.plain)
            .help("Show cost breakdown")
        }
    }

    /// Final elapsed runtime, shown just right of cost. Tertiary so cost (orange) stays the
    /// primary left-edge signal while elapsed rides along as glanceable context. Only for
    /// FINISHED tasks (`completedAt` set) — a still-running task's elapsed would be frozen at
    /// last redraw rather than ticking, so we don't pretend the row is a live stopwatch.
    @ViewBuilder
    private func elapsedChip() -> some View {
        if task.completedAt != nil, let elapsed = task.elapsedDisplayString {
            Text(elapsed)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .layoutPriority(-1)
        }
    }

    @ViewBuilder
    private func descriptionText() -> some View {
        Text(task.description)
            .font(AppFonts.taskDescription)
            .foregroundStyle(style == .active ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
    }

}

// MARK: - Scheduled-runs indicator

/// Compact pill on a task row showing the next pending wake's fire time. Falls back to the
/// task's `updatedAt` timestamp when the task has no pending wakes (so completed tasks still
/// show *something*). When pending wakes exist, the pill is a button that pops over a list
/// of every upcoming run for the task — useful when a recurring schedule has many pending
/// occurrences queued.
private struct ScheduledRunsIndicator: View {
    let task: AgentTask
    let density: TaskRowDensity
    let viewModel: AppViewModel

    @State private var showingPopover = false

    var body: some View {
        let pendingWakes = viewModel.pendingWakesByTaskID[task.id] ?? []

        if let nextWake = pendingWakes.first {
            Button(action: { showingPopover.toggle() }, label: {
                HStack(spacing: 3) {
                    Image(systemName: nextWake.recurrence == nil ? "clock" : "arrow.triangle.2.circlepath")
                        .imageScale(.small)
                    Text("Next: \(formatScheduledTime(nextWake.wakeAt))")
                    if pendingWakes.count > 1 {
                        Text("+\(pendingWakes.count - 1)")
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(TaskStatusBadge.color(for: .scheduled).opacity(0.25)))
                    }
                }
                .font(.caption2)
                .foregroundStyle(TaskStatusBadge.color(for: .scheduled))
                .fixedSize()
            })
            .buttonStyle(.plain)
            .help(pendingWakes.count == 1 ? "Show scheduled run" : "Show \(pendingWakes.count) scheduled runs")
            .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
                ScheduledRunsPopover(task: task, wakes: pendingWakes, viewModel: viewModel)
            }
        } else {
            Text(density == .compact ? compactTaskTimestamp(task.startedAt ?? task.createdAt) : taskTimestamp(task.startedAt ?? task.createdAt))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize()
        }
    }
}

/// Popover content listing every pending wake for a task. Each row shows the absolute
/// fire time, a relative "in N min/h" countdown, the recurrence pattern (if any), and a
/// cancel button — clicking cancel removes the wake via `AppViewModel.cancelTimer(id:)`,
/// which also refreshes `activeTimers` so the popover (and parent row) update in place.
private struct ScheduledRunsPopover: View {
    let task: AgentTask
    let wakes: [ScheduledWake]
    let viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Scheduled runs")
                    .font(.headline)
                Spacer()
                Text("\(wakes.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(wakes, id: \.id) { wake in
                        ScheduledRunsPopoverItem(wake: wake, onCancel: {
                            Task { await viewModel.cancelTimer(id: wake.id) }
                        })
                    }
                }
            }
            .frame(minWidth: 320, maxWidth: 400, minHeight: 80, maxHeight: 360)
        }
    }
}

struct ScheduledRunsPopoverRow: View {
    let wake: ScheduledWake
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: wake.recurrence == nil ? "clock" : "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
                .imageScale(.small)
                .frame(width: 16)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(formatScheduledTime(wake.wakeAt))
                    .font(.callout)
                HStack(spacing: 8) {
                    // TimelineView keeps the relative countdown ("in 2 min") fresh while
                    // the popover is open, so it doesn't go stale at the moment it was
                    // first shown. 30s cadence is precise enough for minute/hour buckets.
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(Self.relativeCountdown(to: wake.wakeAt, now: context.date))
                    }
                    if let recurrence = wake.recurrence {
                        Text("·")
                        Text(recurrence.displayDescription)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            Button(role: .destructive, action: onCancel, label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            })
            .buttonStyle(.plain)
            .help("Cancel this scheduled run")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private static func relativeCountdown(to date: Date, now: Date) -> String {
        let interval = date.timeIntervalSince(now)
        if interval < 60 { return "in <1 min" }
        if interval < 3600 { return "in \(Int(interval / 60)) min" }
        if interval < 86400 { return String(format: "in %.1f h", interval / 3600) }
        return String(format: "in %.1f d", interval / 86400)
    }
}

/// Feedback form for sending an escalated task back to Brown with specific changes. Brown respawns
/// from its saved context and the feedback becomes its "changes required" brief.
private struct SendBackToBrownSheet: View {
    let task: AgentTask
    let onSend: (String) -> Void
    let onCancel: () -> Void

    @State private var feedback: String = ""

    private var trimmed: String { feedback.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send “\(task.title)” back to Brown")
                .font(.headline)
            Text("Describe exactly what needs to change. Brown respawns with the task context plus your feedback.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $feedback)
                .font(.body)
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.3)))
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Send Back") { onSend(trimmed) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 480)
    }
}
