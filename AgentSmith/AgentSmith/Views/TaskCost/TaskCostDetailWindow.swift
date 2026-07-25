import SwiftUI
import AgentSmithKit
import SwiftLLMKit

/// Standalone, resizable/movable window showing one task's cost & usage detail. It reconstructs its
/// data from shared state given only a task id, so any surface can open it with
/// `openWindow(value: TaskCostDetailTarget(taskID:))` — the spending dashboard's task rows and the
/// task sidebar's cost chip both do. Unlike the old modal sheet, a window can be moved and resized.
///
/// The view is global (not session-scoped): records come from the shared `UsageStore` filtered by
/// task id, so the picture is the task's ENTIRE history, not a dashboard time-range slice.
struct TaskCostDetailWindow: View {
    let taskID: UUID
    @Bindable var shared: SharedAppState
    @Environment(\.openWindow) private var openWindow

    @State private var records: [UsageRecord] = []
    @State private var task: AgentTask?
    @State private var summary: TaskSummaryEntry?
    /// All-time average cost across tasks, for the "vs Average" comparison (0 hides it).
    @State private var averageTaskCostUSD: Double = 0
    @State private var taskCount: Int = 0
    @State private var resolvedSessionID: UUID?
    @State private var isLoading = true

    private var aggregator: UsageAggregator { UsageAggregator(pricingLookup: shared.pricingLookup) }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading task cost…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TaskCostDetailSheet(
                    taskID: taskID,
                    titleOverride: task?.title ?? summary?.title ?? "Task \(taskID.uuidString.prefix(8))",
                    task: task,
                    taskSummary: summary,
                    records: records,
                    taskCountInRange: taskCount,
                    averageTaskCostUSD: averageTaskCostUSD,
                    aggregator: aggregator,
                    onOpenTaskDetail: openTaskDetailAction(),
                    showsDoneButton: false
                )
            }
        }
        .frame(minWidth: 640, minHeight: 520)
        .background(AppColors.background)
        .task(id: taskID) { await load() }
    }

    private func load() async {
        isLoading = true
        let all = await shared.usageStore.allRecords()
        let mine = all.filter { $0.taskID == taskID }
        records = mine
        resolvedSessionID = mine.first?.sessionID

        task = shared.archivedTasks.first(where: { $0.id == taskID })
            ?? shared.deletedTasks.first(where: { $0.id == taskID })
        summary = shared.storedTaskSummaries.first(where: { $0.id == taskID })

        // All-time average TASK cost (task-attributed records only — nil-task Orchestration cost is
        // excluded so it doesn't inflate the average), the same basis the dashboard uses per-range.
        let byTask = aggregator.byTask(all)
        let taskCosts = byTask.compactMap { key, value in key == nil ? nil : value.totalCostUSD }
        taskCount = taskCosts.count
        averageTaskCostUSD = taskCosts.isEmpty ? 0 : taskCosts.reduce(0, +) / Double(taskCosts.count)

        isLoading = false
    }

    /// Opens the full Task Detail window in the session that owns this task (resolved from its usage
    /// records). Nil when no record carries a session id, so the id footer renders as plain text.
    private func openTaskDetailAction() -> ((UUID) -> Void)? {
        guard let sessionID = resolvedSessionID else { return nil }
        let open = openWindow
        return { requestedTaskID in
            AgentSmithApp.showOrOpenTaskDetail(
                target: TaskDetailTarget(sessionID: sessionID, taskID: requestedTaskID),
                openWindow: open
            )
        }
    }
}
