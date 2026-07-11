import Foundation

/// Allows agents to search the semantic memory store and prior task summaries.
///
/// Available to both Smith and Brown. Returns matching memories (prioritized) and
/// relevant prior task summaries, ranked by semantic similarity.
struct SearchMemoryTool: AgentTool {
    let name = "search_memory"
    let toolDescription = """
        Search long-term memory and prior task history using natural language. \
        Returns saved memories and summaries of past tasks, ranked by semantic similarity \
        and split into "Relevant" (cleared the relevance gate — trust these) and "Weak \
        Matches" (below the gate — usually unrelated; ignore unless a title obviously \
        fits). Use when approaching a task that might relate to past work, or to look up \
        previously saved knowledge. Not every query has relevant matches — an all-weak or \
        empty result is normal and just means nothing applies.
        """

    /// Floor on raw cosine below which a candidate is dropped entirely, even for this
    /// explicit (ungated) search — clears true junk while keeping near-misses. Sits
    /// below both injection gates (memory 0.58, task 0.66) so gate-adjacent matches
    /// still surface in the "Weak Matches" tier.
    private static let toolSearchFloor: Double = 0.42

    let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "query": .dictionary([
                "type": .string("string"),
                "description": .string("Natural language search query describing what you're looking for.")
            ]),
            "limit": .dictionary([
                "type": .string("integer"),
                "description": .string("Maximum number of candidates per category to consider. Results are filtered by tiered relevance thresholds. Default: 5.")
            ])
        ]),
        "required": .array([.string("query")])
    ]

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    public init() {}

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard case .string(let query) = arguments["query"],
              !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ToolCallError.missingRequiredArgument("query")
        }

        let limit: Int
        if case .int(let l) = arguments["limit"] {
            limit = max(1, min(l, 10))
        } else {
            limit = 5
        }

        // This is an EXPLICIT agent search (pull), not pushed auto-context, so it stays
        // more permissive than the injection sites — the agent asked, and near-misses
        // sometimes matter. But two things keep it honest (the old behavior returned the
        // raw top-K, which buried real matches under a wall of 43% noise the model was
        // told was "filtered by relevance thresholds" — it wasn't):
        //   (B) a low floor drops true junk below `toolSearchFloor`; and
        //   (A) results are TIERED — entries clearing the injection gate are "Relevant",
        //       the rest are labeled "Weak matches (below relevance gate)" so the model
        //       discounts them instead of trusting them.
        // `excludeDeletedTasks: false`: the agent explicitly asked, so deleted tasks still
        // surface here (they're hidden only from the unrequested auto-context push).
        let rawResults = try await context.memoryStore.searchAll(
            query: query,
            memoryLimit: limit,
            taskLimit: limit,
            excludeDeletedTasks: false
        )
        let memories = rawResults.memories.filter { $0.similarity >= Self.toolSearchFloor }
        let taskSummaries = rawResults.taskSummaries.filter { $0.similarity >= Self.toolSearchFloor }
        let results = (memories: memories, taskSummaries: taskSummaries, isEmpty: memories.isEmpty && taskSummaries.isEmpty)

        if results.isEmpty {
            await context.post(ChannelMessage(
                sender: .system,
                content: query,
                metadata: [
                    "messageKind": .string("memory_searched"),
                    "searchQuery": .string(query),
                    "memoryCount": .int(0),
                    "taskCount": .int(0)
                ]
            ))
            // Empty result is a successful query — the search worked, nothing matched.
            return .success("No relevant memories or prior tasks found for: \"\(query)\"")
        }

        var sections: [String] = []

        // Tier by the injection cosine gate: strong matches first, weak matches under a
        // clear "probably unrelated" heading so the model doesn't treat them as signal.
        let strongMemories = results.memories.filter { $0.similarity >= MemoryStore.memoryInjectionCosineGate }
        let weakMemories = results.memories.filter { $0.similarity < MemoryStore.memoryInjectionCosineGate }
        let strongTasks = results.taskSummaries.filter { $0.similarity >= MemoryStore.taskInjectionCosineGate }
        let weakTasks = results.taskSummaries.filter { $0.similarity < MemoryStore.taskInjectionCosineGate }

        func memoryLine(_ index: Int, _ result: MemorySearchResult) -> String {
            let tagText = result.memory.tags.isEmpty ? "" : " [tags: \(result.memory.tags.joined(separator: ", "))]"
            return "\(index). (similarity: \(String(format: "%.2f", result.similarity))) \(result.memory.content)\(tagText)"
        }
        func taskLine(_ index: Int, _ result: TaskSummarySearchResult) -> String {
            let dateStr = Self.dateFormatter.string(from: result.summary.createdAt)
            return "\(index). (similarity: \(String(format: "%.2f", result.similarity)), status: \(result.summary.status.rawValue), date: \(dateStr), task_id: \(result.summary.id.uuidString)) **\(result.summary.title)**: \(result.summary.summary)"
        }

        if !strongMemories.isEmpty {
            var lines = ["## Relevant Memories"]
            for (index, result) in strongMemories.enumerated() { lines.append(memoryLine(index + 1, result)) }
            sections.append(lines.joined(separator: "\n"))
        }
        if !strongTasks.isEmpty {
            var lines = ["## Relevant Prior Tasks"]
            lines.append("*The items below are short summaries only. Use `get_task_details` with the `task_ids` parameter (you can pass up to 10 IDs at once) to fetch full task descriptions, results, and commentary — but only when a summary clearly relates to what you actually need.*")
            for (index, result) in strongTasks.enumerated() { lines.append(taskLine(index + 1, result)) }
            sections.append(lines.joined(separator: "\n"))
        }
        if !weakMemories.isEmpty || !weakTasks.isEmpty {
            var lines = ["## Weak Matches (below the relevance gate — probably unrelated; ignore unless a title clearly fits)"]
            for (index, result) in weakMemories.enumerated() { lines.append(memoryLine(index + 1, result)) }
            for (index, result) in weakTasks.enumerated() { lines.append(taskLine(index + 1, result)) }
            sections.append(lines.joined(separator: "\n"))
        }
        if sections.isEmpty {
            sections.append("Only weak, likely-unrelated matches were found for: \"\(query)\"")
        }

        // Build per-entry strings for the UI banner. Same shape as `CreateTaskTool`'s
        // context metadata so the channel log renders memory/task search results with
        // the same expandable layout used for task-creation context.
        let memoryEntries = results.memories.map { result -> String in
            let pct = String(format: "%.0f%%", result.similarity * 100)
            let tagText = result.memory.tags.isEmpty ? "" : " [tags: \(result.memory.tags.joined(separator: ", "))]"
            return "\(pct) — \(result.memory.content)\(tagText)"
        }
        let taskEntries = results.taskSummaries.map { result -> String in
            let pct = String(format: "%.0f%%", result.similarity * 100)
            return "\(pct) — \(result.summary.title) (id: \(result.summary.id.uuidString))\n\(result.summary.summary)"
        }

        var bannerMetadata: [String: AnyCodable] = [
            "messageKind": .string("memory_searched"),
            "searchQuery": .string(query),
            "memoryCount": .int(results.memories.count),
            "taskCount": .int(results.taskSummaries.count)
        ]
        if !memoryEntries.isEmpty {
            bannerMetadata["memoryResults"] = .string(memoryEntries.joined(separator: "\u{1E}"))
        }
        if !taskEntries.isEmpty {
            bannerMetadata["taskResults"] = .string(taskEntries.joined(separator: "\u{1E}"))
        }

        // Post a channel banner so memory searches are visible in the transcript.
        await context.post(ChannelMessage(
            sender: .system,
            content: query,
            metadata: bannerMetadata
        ))

        return .success(sections.joined(separator: "\n\n"))
    }
}
