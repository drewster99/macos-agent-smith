import Foundation

/// Allows agents to search the semantic memory store and prior task summaries.
///
/// Available to both Smith and Brown. Returns matching memories (prioritized) and
/// relevant prior task summaries, ranked by semantic similarity.
struct SearchMemoryTool: AgentTool {
    let name = "search_memory"
    let toolDescription = """
        Search long-term memory and prior task history using natural language. \
        Returns relevant memories (saved insights) and summaries of similar past tasks, \
        ranked by semantic similarity. Use this when approaching a task that might relate \
        to past work, or when looking for previously saved knowledge.
        """

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

        let results = try await context.memoryStore.searchAll(
            query: query,
            memoryLimit: limit,
            taskLimit: limit
        )

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

        if !results.memories.isEmpty {
            var lines = ["## Relevant Memories"]
            for (index, result) in results.memories.enumerated() {
                let tagText = result.memory.tags.isEmpty ? "" : " [tags: \(result.memory.tags.joined(separator: ", "))]"
                lines.append("\(index + 1). (similarity: \(String(format: "%.2f", result.similarity))) \(result.memory.content)\(tagText)")
            }
            sections.append(lines.joined(separator: "\n"))
        }

        if !results.taskSummaries.isEmpty {
            var lines = ["## Relevant Prior Tasks"]
            lines.append("*The items below are short summaries only. Use `get_task_details` with the `task_ids` parameter (you can pass up to 10 IDs at once) to fetch full task descriptions, results, and commentary — but only when a summary clearly relates to what you actually need.*")
            for (index, result) in results.taskSummaries.enumerated() {
                let dateStr = Self.dateFormatter.string(from: result.summary.createdAt)
                lines.append("\(index + 1). (similarity: \(String(format: "%.2f", result.similarity)), status: \(result.summary.status.rawValue), date: \(dateStr), task_id: \(result.summary.id.uuidString)) **\(result.summary.title)**: \(result.summary.summary)")
            }
            sections.append(lines.joined(separator: "\n"))
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
