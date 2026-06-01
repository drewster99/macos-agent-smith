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
    @Environment(\.openWindow) private var openWindow

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
                    ForEach(activeTasks) { task in
                        TaskListRow(task: task, style: .active, viewModel: viewModel)
                    }

                    if !archivedTasks.isEmpty || !deletedTasks.isEmpty {
                        bucketToggles(archivedCount: archivedTasks.count, deletedCount: deletedTasks.count)
                    }

                    if showArchived && !archivedTasks.isEmpty {
                        TaskSectionHeader(title: "Archived")
                        ForEach(archivedTasks) { task in
                            TaskListRow(task: task, style: .archived, viewModel: viewModel)
                        }
                    }

                    if showDeleted && !deletedTasks.isEmpty {
                        TaskSectionHeader(title: "Recently Deleted")
                        ForEach(deletedTasks) { task in
                            TaskListRow(task: task, style: .recentlyDeleted, viewModel: viewModel)
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

/// Wraps a `TaskRow` in the click-to-open Button + the role-appropriate context menu.
/// Kept separate from `TaskRow` so the row body itself is purely presentational and
/// can be Equatable-shortcut on its inputs.
struct TaskRowButton: View {
    let task: AgentTask
    let style: TaskRowStyle
    let viewModel: AppViewModel

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            AgentSmithApp.showOrOpenTaskDetail(
                target: TaskDetailTarget(sessionID: viewModel.session.id, taskID: task.id),
                openWindow: openWindow
            )
        } label: {
            TaskRow(task: task, style: style, viewModel: viewModel)
        }
        .buttonStyle(.plain)
        .contextMenu { contextMenu(task: task, style: style, viewModel: viewModel) }
    }

    @ViewBuilder
    private func contextMenu(task: AgentTask, style: TaskRowStyle, viewModel: AppViewModel) -> some View {
        Button(action: { copyTaskIDToPasteboard(task.id) }, label: {
            Label("Copy Task ID", systemImage: "doc.on.doc")
        })
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

        case .running:
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
            EmptyView()

        case .pending, .paused, .interrupted:
            Button(action: { Task { await viewModel.startTask(task) } }, label: {
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
}

/// Single row layout shared by all three buckets. The `style` argument drives the small
/// presentational deltas (icon opacity, line limits, strikethrough, etc.) so we don't
/// duplicate the layout three times. With `AgentTask: Equatable`, SwiftUI's per-input
/// diff at the ForEach boundary skips unchanged rows when only one task in the array
/// mutates.
/// Composite key for the task-cost `.task(id:)` modifier. Re-firing must happen
/// when either the task ID changes (different row) or the task reaches a terminal
/// status (`.completed` or `.failed`) — that's when the underlying records stop
/// growing and a fresh cache fetch is worthwhile. Shared by the sidebar row and
/// the detail window so both surfaces pick up cost the moment a task finishes.
struct TaskCostLoaderKey: Hashable {
    let taskID: UUID
    let isTerminal: Bool
}

private struct TaskRow: View {
    let task: AgentTask
    let style: TaskRowStyle
    let viewModel: AppViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            statusIcon()

            VStack(alignment: .leading, spacing: 3) {
                titleRow()

                if style != .recentlyDeleted {
                    descriptionText()
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    metadataLine()
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
        .contentShape(Rectangle())
        // Lazy-load the task's estimated cost. The id includes whether the task
        // has reached a terminal state (completed OR failed) so the loader
        // re-fires when a task we're watching transitions out of `.running` —
        // keying on `task.id` alone would only fire once on row appear and miss
        // the post-completion records.
        //
        // `force: true` evicts any partial value cached by the detail window
        // while the task was still running, so the list row picks up final cost.
        .task(id: TaskCostLoaderKey(taskID: task.id, isTerminal: task.status.isTerminal)) {
            await viewModel.loadTaskCost(task.id, force: true)
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private func statusIcon() -> some View {
        Image(systemName: TaskStatusBadge.icon(for: task.status))
            .foregroundStyle(iconForeground)
            .imageScale(.medium)
            .frame(width: 18)
            .padding(.top, style == .recentlyDeleted ? 0 : 2)
            .symbolEffect(
                .rotate,
                options: .repeat(.continuous),
                isActive: style == .active && task.status == .running
            )
    }

    private var iconForeground: AnyShapeStyle {
        switch style {
        case .active:
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

            if attachmentCount > 0 {
                attachmentPip()
            }

            if style == .active && task.status == .running {
                runningInlineControls()
            } else if style == .active && task.status.isRunnable {
                runInlineControl()
            }
        }
    }

    @ViewBuilder
    private func runInlineControl() -> some View {
        Button(action: { Task { await viewModel.startTask(task) } }, label: {
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
        switch style {
        case .active:
            Text(task.title)
                .font(AppFonts.taskTitle)
                .lineLimit(2)
        case .archived:
            Text(task.title)
                .font(AppFonts.taskTitle)
                .lineLimit(2)
                .foregroundStyle(.secondary)
        case .recentlyDeleted:
            Text(task.title)
                .font(AppFonts.taskTitle)
                .lineLimit(1)
                .foregroundStyle(.tertiary)
                .strikethrough(true, color: .secondary)
        }
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

            Spacer(minLength: 0)

            switch style {
            case .active:
                if task.status != .running {
                    HStack(spacing: 4) {
                        statusCapsule()
                        ScheduledRunsIndicator(task: task, viewModel: viewModel)
                    }
                }
            case .archived:
                Text(taskTimestamp(task.updatedAt))
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
                    .fixedSize()
            case .recentlyDeleted:
                EmptyView()
            }
        }
    }

    /// Estimated cost chip. Reads from the cache populated by the row-level
    /// `.task(id:)` loader — never queries `UsageStore` itself. Rendered in
    /// orange so the eye picks it out at a glance. Shows for any task with
    /// non-zero accrued cost, regardless of status — a failed task that burned
    /// real money is information the user needs.
    @ViewBuilder
    private func costChip() -> some View {
        if let cost = viewModel.cachedTaskCost(task.id), cost > 0 {
            Text(String(format: "$%.2f", cost))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.orange)
                .fixedSize()
        }
    }

    @ViewBuilder
    private func descriptionText() -> some View {
        Text(task.description)
            .font(AppFonts.taskDescription)
            .foregroundStyle(style == .active ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
    }

    @ViewBuilder
    private func statusCapsule() -> some View {
        Text(task.status.rawValue.capitalized)
            .font(.caption)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(TaskStatusBadge.color(for: task.status).opacity(0.2)))
            .foregroundStyle(TaskStatusBadge.color(for: task.status))
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
            Text(taskTimestamp(task.updatedAt))
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
