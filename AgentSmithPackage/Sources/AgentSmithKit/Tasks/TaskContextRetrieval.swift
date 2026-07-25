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
    /// Searches with the same caps and cosine gates the auto-context injection uses (top 3 memories
    /// + 3 prior tasks, relevance-gated), attaches the matches to `taskID`, and returns what was
    /// attached so the caller can surface a note or channel metadata. Empty arrays when nothing
    /// cleared the gates or the search failed.
    @discardableResult
    public static func attachRelevantContext(
        taskID: UUID,
        query: String,
        memoryStore: MemoryStore,
        taskStore: TaskStore
    ) async -> (memories: [RelevantMemory], priorTasks: [RelevantPriorTask]) {
        do {
            let results = try await memoryStore.searchAll(
                query: query,
                memoryLimit: 3,
                taskLimit: 3,
                memoryCosineGate: MemoryStore.memoryInjectionCosineGate,
                taskCosineGate: MemoryStore.taskInjectionCosineGate,
                memoryInstruction: MemoryStore.memoryRetrievalInstruction,
                taskInstruction: MemoryStore.taskRetrievalInstruction,
                source: "task-context"
            )
            guard !results.isEmpty else { return ([], []) }

            let memories = results.memories.map {
                RelevantMemory(
                    content: $0.memory.content,
                    tags: $0.memory.tags,
                    similarity: $0.similarity,
                    createdAt: $0.memory.createdAt,
                    lastUpdatedAt: $0.memory.lastUpdatedAt
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
        } catch {
            return ([], [])
        }
    }
}
