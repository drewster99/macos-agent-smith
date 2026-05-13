import Foundation

/// Allows Smith to list tasks across active, archived, and recently-deleted buckets,
/// with optional status filtering and pagination.
struct ListTasksTool: AgentTool {
    let name = "list_tasks"
    let toolDescription = """
        List tasks across active, archived (inactive), or all buckets, with their current status, \
        title, and description. Defaults to active tasks only. Supports pagination via `limit` and `offset` \
        for browsing large historical lists.
        """

    /// Default page size when the caller doesn't specify a limit.
    private static let defaultLimit = 25
    /// Maximum page size the caller can request.
    private static let maxLimit = 100

    let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "disposition_filter": .dictionary([
                "type": .string("string"),
                "description": .string("Which task buckets to include. 'active' (default) = current tasks; 'inactive' = archived + recently-deleted; 'all' = everything."),
                "enum": .array([.string("active"), .string("inactive"), .string("all")])
            ]),
            "status_filter": .dictionary([
                "type": .string("string"),
                "description": .string("Optional status filter applied after the disposition filter. Omit to include all statuses."),
                "enum": .array([.string("pending"), .string("running"), .string("paused"), .string("completed"), .string("failed"), .string("awaitingReview"), .string("interrupted")])
            ]),
            "limit": .dictionary([
                "type": .string("integer"),
                "description": .string("Maximum number of tasks to return. Default: 25, max: 100.")
            ]),
            "offset": .dictionary([
                "type": .string("integer"),
                "description": .string("Number of tasks to skip from the start of the result set. Default: 0. Use together with `limit` to page through historical tasks.")
            ])
        ]),
        "required": .array([])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .smith
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        // Disposition filter — defaults to active so the existing call pattern keeps working.
        let dispositionFilter: String
        if case .string(let value) = arguments["disposition_filter"] {
            dispositionFilter = value
        } else {
            dispositionFilter = "active"
        }

        let allowedDispositions: Set<AgentTask.TaskDisposition>
        switch dispositionFilter {
        case "active":
            allowedDispositions = [.active]
        case "inactive":
            allowedDispositions = [.archived, .recentlyDeleted]
        case "all":
            allowedDispositions = [.active, .archived, .recentlyDeleted]
        default:
            return .failure("Invalid disposition_filter: '\(dispositionFilter)'. Valid values: active, inactive, all")
        }

        var tasks = await context.taskStore.allTasks().filter { allowedDispositions.contains($0.disposition) }

        // Optional status filter applied after disposition.
        if case .string(let filterValue) = arguments["status_filter"] {
            guard let status = AgentTask.Status(rawValue: filterValue) else {
                return .failure("Invalid status_filter: '\(filterValue)'. Valid values: pending, running, paused, awaitingReview, completed, failed, interrupted")
            }
            tasks = tasks.filter { $0.status == status }
        }

        let totalMatching = tasks.count

        // Pagination — clamp limit to [1, maxLimit] and offset to [0, totalMatching].
        let requestedLimit: Int
        if case .int(let value) = arguments["limit"] {
            requestedLimit = value
        } else {
            requestedLimit = Self.defaultLimit
        }
        let limit = max(1, min(requestedLimit, Self.maxLimit))

        let requestedOffset: Int
        if case .int(let value) = arguments["offset"] {
            requestedOffset = value
        } else {
            requestedOffset = 0
        }
        let offset = max(0, min(requestedOffset, totalMatching))

        guard totalMatching > 0 else {
            // Empty result is a successful query, not a failure.
            return .success("No tasks found matching the given filters.")
        }

        // Empty page (offset already at or past the end) — surface a clear message instead
        // of a nonsensical "Showing tasks N+1–N of N" header.
        guard offset < totalMatching else {
            return .failure("Offset \(offset) is past the end of the result set (\(totalMatching) matching task(s)). Use a smaller offset or omit it to start from the beginning.")
        }

        let endIndex = min(offset + limit, totalMatching)
        let pageTasks = Array(tasks[offset..<endIndex])

        let lines = pageTasks.map { task in
            "[\(task.status.rawValue.uppercased())][\(task.disposition.rawValue)] \(task.title) (id: \(task.id.uuidString))\n  \(task.description)"
        }

        // Header indicates which slice was returned and whether more remain, so the LLM
        // can decide whether to call `list_tasks` again with a higher offset.
        let rangeEnd = offset + pageTasks.count
        var header = "Showing tasks \(offset + 1)–\(rangeEnd) of \(totalMatching) (disposition: \(dispositionFilter))"
        if rangeEnd < totalMatching {
            let remaining = totalMatching - rangeEnd
            header += ". \(remaining) more available — call `list_tasks` with offset=\(rangeEnd) to see the next page."
        }

        return .success("\(header)\n\(lines.joined(separator: "\n"))")
    }
}
