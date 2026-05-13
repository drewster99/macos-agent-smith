import Foundation
import os

nonisolated private let runTaskLogger = Logger(subsystem: "com.agentsmith", category: "RunTaskTool")

/// Allows Smith to run an existing pending, paused, interrupted, failed, or completed task
/// without duplicating it. When invoked on a failed or completed task, the task's terminal
/// state is reset (result, commentary, and completedAt are cleared and status returns to
/// `.pending`) before the run begins — the user said "try again" / "redo that" / "reopen
/// that" means "rerun on the same task ID", not "create a new one."
struct RunTaskTool: AgentTool {
    let name = "run_task"
    let toolDescription = "Run an existing pending, paused, interrupted, failed, or completed task. Restarts with a clean context and auto-spawns Brown+Jones. Failed and completed tasks are auto-reset (prior result/commentary cleared, status flipped back to pending) before running — this is how you reopen a completed task without creating a duplicate. The `instructions` field is REQUIRED — include any updates, permissions, scope changes, or clarifications from the user. These are appended to the task description and survive the restart.\nIMPORTANT: Only one task can run at a time. Calling `run_task` will STOP any currently executing task."

    let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "task_id": .dictionary([
                "type": .string("string"),
                "description": .string("UUID of the pending, paused, interrupted, failed, or completed task to run. Completed tasks are reopened (terminal state cleared) so the same id keeps its history.")
            ]),
            "instructions": .dictionary([
                "type": .string("string"),
                "description": .string("Instructions to append to the task description. Include any new permissions, scope changes, or clarifications from the user. If the user said nothing new, summarize their confirmation (e.g. 'User confirmed: proceed as described'). These survive the restart and are visible to Brown and Jones.")
            ])
        ]),
        "required": .array([.string("task_id"), .string("instructions")])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .smith
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        // Resolve task_id with two layers of forgiveness for model brain-fade:
        //  1. If task_id is missing entirely, auto-resolve when there's exactly one
        //     pending/paused/interrupted task — the unambiguous case where "yes go
        //     ahead" obviously means the only outstanding task. Observed on
        //     gemma3:27b: it names the task UUID in its assistant text but fails
        //     to put it in the structured tool_call args, even after being told
        //     the exact ID list. We can't fix the model; we can stop the loop.
        //  2. If task_id is present but not a valid UUID, fall through to the
        //     existing error path so the user sees the typo instead of acting on
        //     guesswork — guessing only helps when the model omitted the field
        //     entirely.
        let resolvedTaskID: UUID
        var autoResolved = false
        if case .string(let taskIDString) = arguments["task_id"] {
            guard let parsed = UUID(uuidString: taskIDString) else {
                return .failure("""
                    Invalid task_id: '\(taskIDString)' is not a valid UUID. \
                    \(await Self.candidateTaskList(context: context))
                    """)
            }
            resolvedTaskID = parsed
        } else if let onlyPending = await Self.onlyPendingRunnableTaskID(context: context) {
            resolvedTaskID = onlyPending
            autoResolved = true
        } else {
            return .failure(await Self.missingTaskIDFailure(context: context))
        }
        let taskID = resolvedTaskID
        guard var task = await context.taskStore.task(id: taskID) else {
            return .failure("""
                No task found with ID \(taskID). \
                \(await Self.candidateTaskList(context: context))
                """)
        }
        if autoResolved {
            // Surface the auto-pick so the user sees it in the success banner and
            // a future log search can identify when this fallback fired.
            runTaskLogger.notice("auto-resolved missing task_id → \(taskID.uuidString, privacy: .public) (\(task.title, privacy: .public))")
        }
        // Allow pending/paused/interrupted directly. For failed, reset the task back to
        // pending first so the retry runs on the same task ID (preserving history and prior
        // context). Completed tasks get the same reopen-in-place treatment so the user's
        // "redo that one" never silently turns into a new duplicate task.
        if task.status == .failed {
            _ = await context.taskStore.resetFailedTask(id: taskID)
            guard let refreshed = await context.taskStore.task(id: taskID), refreshed.status.isRunnable else {
                return .failure("Could not reset task '\(task.title)' for retry.")
            }
            task = refreshed
        } else if task.status == .completed {
            _ = await context.taskStore.reopenCompletedTask(id: taskID)
            guard let refreshed = await context.taskStore.task(id: taskID), refreshed.status.isRunnable else {
                return .failure("Could not reopen completed task '\(task.title)'.")
            }
            task = refreshed
        } else if !task.status.isRunnable {
            return .failure("""
                Task '\(task.title)' has status '\(task.status.rawValue)' — run_task only works on pending, paused, interrupted, failed, or completed tasks. \
                Use list_tasks to check current statuses, or create_task if you need a new task.
                """)
        }

        // Refuse to restart if another task is running or awaiting review.
        // Running: would kill Brown mid-work. AwaitingReview: Smith should review first.
        let allTasks = await context.taskStore.allTasks()
        if let runningTask = allTasks.first(where: { $0.status == .running && $0.id != taskID }) {
            return .failure("""
                Cannot start '\(task.title)' — task '\(runningTask.title)' is still running. \
                Wait for the current task to complete (or fail) before calling run_task. \
                The task has been created and is queued as pending.
                """)
        }
        if let reviewTask = allTasks.first(where: { $0.status == .awaitingReview && $0.id != taskID }) {
            return .failure("""
                Cannot start '\(task.title)' — task '\(reviewTask.title)' is awaiting your review. \
                Call review_work to accept or reject it first, then run_task to start the next task.
                """)
        }

        // Prevent restart loops: if the system *just* restarted for this exact task AND
        // Brown is still actively running it, don't restart again. After a pause/stop the
        // task's status drops out of `.running`, Brown is gone, and `currentResumingTaskID`
        // is stale — a legitimate resume must NOT be blocked by a stale flag, otherwise
        // Smith loops forever telling the user "Brown is auto-spawned" while nothing happens.
        if context.currentResumingTaskID == taskID, task.status == .running {
            return .failure("""
                The system has already restarted for this task and Brown is actively working on it. \
                Do NOT call run_task again. Brown will signal progress via task_update / task_complete; \
                you'll also receive an automatic 10-minute Brown-activity digest.
                """)
        }

        // The model's `instructions` field is sometimes a malformed JSON value
        // (gemma3:27b has been seen emitting `"instructions":"User confirmed":"..."`).
        // Treat any missing or non-string value as "no instructions" rather than
        // failing — the field is meant to capture user-supplied refinements, and
        // a bare confirmation has no refinements to capture. Going to .failure on
        // a missing instructions field re-traps the same model into another
        // text-only apology loop.
        let instructions: String = {
            if case .string(let s) = arguments["instructions"] { return s }
            return ""
        }()

        // Amend the task with the instructions before restarting, so they survive
        // the context reset and are visible to the new Smith, Brown, and Jones.
        let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            await context.taskStore.amendDescription(id: taskID, amendment: trimmed)
        }

        await context.restartForNewTask(task.id)

        let autoNote = autoResolved
            ? " (auto-resolved task_id because it was omitted from the call and only one task was eligible)"
            : ""
        return .success("Running task '\(task.title)' (ID: \(task.id)).\(autoNote) System is restarting with a clean context to begin work.")
    }

    /// When exactly one active task is in a pending/paused/interrupted status (the
    /// "obviously runnable now" set), returns its ID. Returns nil if there are
    /// zero or more than one — auto-pick is reserved for unambiguous cases.
    /// Failed/completed tasks are excluded because resurrecting them on guess is
    /// destructive.
    private static func onlyPendingRunnableTaskID(context: ToolContext) async -> UUID? {
        let allTasks = await context.taskStore.allTasks()
        let pending = allTasks.filter {
            $0.disposition == .active && (
                $0.status == .pending || $0.status == .paused || $0.status == .interrupted
            )
        }
        guard pending.count == 1 else { return nil }
        return pending.first?.id
    }

    /// Builds the "missing task_id" error body. Includes the runnable task list so the
    /// model has everything it needs to self-correct on the next turn — observed on
    /// gemma3:27b producing tool calls with no `task_id` and a malformed `instructions`
    /// blob that buried the user's confirmation. A bare "Missing required argument"
    /// gave the model nothing to work with; this hands it the IDs and the exact retry
    /// shape so the next turn lands.
    private static func missingTaskIDFailure(context: ToolContext) async -> String {
        """
        Missing required argument 'task_id' for run_task. \
        \(await candidateTaskList(context: context)) \
        Re-call run_task with task_id=<one of those IDs> AND instructions=<a string summarizing \
        the user's confirmation, e.g. 'User confirmed: proceed as described'>. Both fields are required.
        """
    }

    /// Returns a one-line description of the tasks currently eligible for `run_task`.
    /// Empty list is reported explicitly so the model doesn't keep guessing IDs.
    private static func candidateTaskList(context: ToolContext) async -> String {
        let allTasks = await context.taskStore.allTasks()
        let candidates = allTasks.filter {
            $0.disposition == .active && (
                $0.status == .pending || $0.status == .paused || $0.status == .interrupted ||
                $0.status == .failed || $0.status == .completed
            )
        }
        guard !candidates.isEmpty else {
            return "There are no runnable tasks right now (use list_tasks to confirm)."
        }
        let summary = candidates.prefix(10).map { "\($0.id.uuidString) (\"\($0.title)\", status=\($0.status.rawValue))" }
            .joined(separator: "; ")
        return "Runnable task IDs: \(summary)."
    }
}
