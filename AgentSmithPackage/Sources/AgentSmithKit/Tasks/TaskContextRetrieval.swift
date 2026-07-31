import Foundation

/// Retrieves relevant memories + prior-task summaries for a task and attaches them via
/// `TaskStore.setRelevantContext`, so the task begins work with CURRENT context.
///
/// Shared by task creation (`CreateTaskTool`) AND by every template instantiation (`RunTaskTool`,
/// `OrchestrationRuntime.resolveStartTarget`). Attaching at instantiation is the point: a template
/// that runs repeatedly — a scheduled daily run, say — otherwise starts each instance with no
/// memories at all (the original fetch landed on the template, and instances neither inherit nor
/// re-fetch it), so it never benefits from memories accumulated since it was authored.
///
/// Retrieval failure is non-fatal — the task simply starts without attached context.
public enum TaskContextRetrieval {
    /// Attaches already-retrieved matches to `taskID` and returns what was attached so the caller can
    /// surface a note or channel metadata. Retrieval itself is done by the caller through the resolved
    /// `retrieveContext(.newTask, …)` entry point — so whether memories and/or prior tasks are searched
    /// (and the empty-when-disabled short-circuit) follows the orchestration settings. Empty arrays
    /// when nothing cleared the relevance gates or retrieval was off.
    @discardableResult
    public static func attachRelevantContext(
        taskID: UUID,
        results: SemanticSearchResults,
        taskStore: TaskStore
    ) async -> (memories: [RelevantMemory], priorTasks: [RelevantPriorTask]) {
        guard !results.isEmpty else { return ([], []) }

        let memories = results.memories.map {
            RelevantMemory(
                content: $0.memory.content,
                tags: $0.memory.tags,
                similarity: $0.similarity,
                createdAt: $0.memory.createdAt,
                lastUpdatedAt: $0.memory.lastUpdatedAt,
                memoryID: $0.memory.id
            )
        }
        let priorTasks = results.taskSummaries.map {
            RelevantPriorTask(
                taskID: $0.summary.id,
                title: $0.summary.title,
                summary: $0.summary.summary,
                similarity: $0.similarity,
                latestDate: $0.summary.createdAt
            )
        }
        await taskStore.setRelevantContext(
            id: taskID,
            memories: memories.isEmpty ? nil : memories,
            priorTasks: priorTasks.isEmpty ? nil : priorTasks
        )
        return (memories, priorTasks)
    }
}
