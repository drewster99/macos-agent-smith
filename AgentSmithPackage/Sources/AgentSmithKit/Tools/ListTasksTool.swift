import Foundation

/// Allows Smith to list task summary previews across active, archived,
/// and recently-deleted buckets, with filtering and pagination.
struct ListTasksTool: AgentTool {
    let name = "list_tasks"
    let toolDescription = """
        List task summaries across active, archived, recently-deleted, or all buckets. \
        Returns STRUCTURED JSON, not complete task details. Descriptions and acceptance criteria \
        are intentionally previews only (`truncatedDescriptionPreview`, `acceptanceCriteriaSummaries`). \
        Use `get_task_details` with returned IDs for full descriptions, validation prompts, \
        input enumerator prompts, steps, results, scheduling/template details, and history.
        """

    /// Default page size when the caller doesn't specify a limit.
    private static let defaultLimit = 25
    /// Maximum page size the caller can request.
    private static let maxLimit = 100
    private static let descriptionPreviewLimit = 500

    let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "disposition_filter": .dictionary([
                "type": .string("string"),
                "description": .string("Which task buckets to include. 'active' (default) = current tasks; 'archived' = archived tasks; 'recentlyDeleted' = recently deleted tasks; 'inactive' = archived + recently-deleted; 'all' = everything."),
                "enum": .array([.string("active"), .string("archived"), .string("recentlyDeleted"), .string("inactive"), .string("all")])
            ]),
            "status_filter": .dictionary([
                "type": .string("string"),
                "description": .string("Optional status filter applied after the disposition filter. Omit to include all statuses."),
                "enum": .array(AgentTask.Status.allCases.map { .string($0.rawValue) })
            ]),
            "is_template": .dictionary([
                "type": .string("boolean"),
                "description": .string("Optional template filter. true = only template launcher tasks; false = only non-template tasks.")
            ]),
            "has_parent_template": .dictionary([
                "type": .string("boolean"),
                "description": .string("Optional cloned-instance filter. true = only instances cloned from a template; false = only tasks without a parent template.")
            ]),
            "parent_task_id": .dictionary([
                "type": .string("string"),
                "description": .string("Optional UUID of a template; returns only cloned instances whose parentTemplateID matches it.")
            ]),
            "is_scheduled": .dictionary([
                "type": .string("boolean"),
                "description": .string("Optional scheduled filter. true = only tasks with scheduledRunAt; false = only tasks without scheduledRunAt.")
            ]),
            "query": .dictionary([
                "type": .string("string"),
                "description": .string("Optional case-insensitive text search over task title and description.")
            ]),
            "created_after": .dictionary([
                "type": .string("string"),
                "description": .string("Optional ISO-8601 lower bound for createdAt, inclusive.")
            ]),
            "created_before": .dictionary([
                "type": .string("string"),
                "description": .string("Optional ISO-8601 upper bound for createdAt, inclusive.")
            ]),
            "updated_after": .dictionary([
                "type": .string("string"),
                "description": .string("Optional ISO-8601 lower bound for updatedAt, inclusive.")
            ]),
            "updated_before": .dictionary([
                "type": .string("string"),
                "description": .string("Optional ISO-8601 upper bound for updatedAt, inclusive.")
            ]),
            "scheduled_after": .dictionary([
                "type": .string("string"),
                "description": .string("Optional ISO-8601 lower bound for scheduledRunAt, inclusive. Tasks without scheduledRunAt never match this filter.")
            ]),
            "scheduled_before": .dictionary([
                "type": .string("string"),
                "description": .string("Optional ISO-8601 upper bound for scheduledRunAt, inclusive. Tasks without scheduledRunAt never match this filter.")
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
        case "archived":
            allowedDispositions = [.archived]
        case "recentlyDeleted":
            allowedDispositions = [.recentlyDeleted]
        case "inactive":
            allowedDispositions = [.archived, .recentlyDeleted]
        case "all":
            allowedDispositions = [.active, .archived, .recentlyDeleted]
        default:
            return .failure("Invalid disposition_filter: '\(dispositionFilter)'. Valid values: active, archived, recentlyDeleted, inactive, all")
        }

        let parentTaskID: UUID?
        if case .string(let rawParentTaskID) = arguments["parent_task_id"] {
            guard let parsed = UUID(uuidString: rawParentTaskID) else {
                return .failure("Invalid parent_task_id: '\(rawParentTaskID)' is not a valid UUID.")
            }
            parentTaskID = parsed
        } else {
            parentTaskID = nil
        }

        let dateFilters: DateFilters
        switch Self.parseDateFilters(arguments) {
        case .success(let parsed): dateFilters = parsed
        case .failure(let message): return .failure(message)
        }

        // Active tasks are per-session (`taskStore`); archived + recently-deleted are global
        // (`inactiveTaskStore`). Pull from whichever store(s) the disposition filter needs.
        var pool: [AgentTask] = []
        if allowedDispositions.contains(.active) {
            pool += await context.taskStore.allTasks()
        }
        if allowedDispositions.contains(.archived) || allowedDispositions.contains(.recentlyDeleted) {
            pool += await context.taskStore.allInactiveTasks()
        }
        var tasks = pool
            .filter { allowedDispositions.contains($0.disposition) }

        // Optional status filter applied after disposition.
        if case .string(let filterValue) = arguments["status_filter"] {
            guard let status = AgentTask.Status(rawValue: filterValue) else {
                return .failure("Invalid status_filter: '\(filterValue)'. Valid values: \(Self.validStatusValues)")
            }
            tasks = tasks.filter { $0.status == status }
        }

        if case .bool(let value) = arguments["is_template"] {
            tasks = tasks.filter { $0.isTemplate == value }
        }
        if case .bool(let value) = arguments["has_parent_template"] {
            tasks = tasks.filter { ($0.parentTaskID != nil) == value }
        }
        if let parentTaskID {
            tasks = tasks.filter { $0.parentTaskID == parentTaskID }
        }
        if case .bool(let value) = arguments["is_scheduled"] {
            tasks = tasks.filter { ($0.scheduledRunAt != nil) == value }
        }
        if case .string(let rawQuery) = arguments["query"] {
            let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            if !query.isEmpty {
                tasks = tasks.filter {
                    $0.title.localizedCaseInsensitiveContains(query)
                        || $0.description.localizedCaseInsensitiveContains(query)
                }
            }
        }
        tasks = tasks.filter { dateFilters.includes($0) }
        tasks = tasks.sorted { $0.createdAt > $1.createdAt }

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
            return .success(Self.encode(ListTasksResponse(
                resultKind: "taskSummaryList",
                completeDetails: false,
                note: "No tasks found matching the given filters.",
                filters: Self.renderFilters(arguments: arguments, dispositionFilter: dispositionFilter),
                pagination: Pagination(offset: offset, limit: limit, returned: 0, totalMatching: 0, hasMore: false, nextOffset: nil),
                tasks: []
            )))
        }

        // Empty page (offset already at or past the end) — surface a clear message instead
        // of a nonsensical "Showing tasks N+1–N of N" header.
        guard offset < totalMatching else {
            return .failure("Offset \(offset) is past the end of the result set (\(totalMatching) matching task(s)). Use a smaller offset or omit it to start from the beginning.")
        }

        let endIndex = min(offset + limit, totalMatching)
        let pageTasks = Array(tasks[offset..<endIndex])

        let rangeEnd = offset + pageTasks.count
        let hasMore = rangeEnd < totalMatching

        return .success(Self.encode(ListTasksResponse(
            resultKind: "taskSummaryList",
            completeDetails: false,
            note: "Descriptions and acceptance criteria are previews only. Use get_task_details for full task details.",
            filters: Self.renderFilters(arguments: arguments, dispositionFilter: dispositionFilter),
            pagination: Pagination(offset: offset, limit: limit, returned: pageTasks.count, totalMatching: totalMatching, hasMore: hasMore, nextOffset: hasMore ? rangeEnd : nil),
            tasks: pageTasks.map { Self.makeSummary(task: $0) }
        )))
    }

    private static var validStatusValues: String {
        AgentTask.Status.allCases.map(\.rawValue).joined(separator: ", ")
    }

    private struct DateFilters {
        var createdAfter: Date?
        var createdBefore: Date?
        var updatedAfter: Date?
        var updatedBefore: Date?
        var scheduledAfter: Date?
        var scheduledBefore: Date?

        func includes(_ task: AgentTask) -> Bool {
            if let createdAfter, task.createdAt < createdAfter { return false }
            if let createdBefore, task.createdAt > createdBefore { return false }
            if let updatedAfter, task.updatedAt < updatedAfter { return false }
            if let updatedBefore, task.updatedAt > updatedBefore { return false }
            if let scheduledAfter {
                guard let scheduledRunAt = task.scheduledRunAt, scheduledRunAt >= scheduledAfter else { return false }
            }
            if let scheduledBefore {
                guard let scheduledRunAt = task.scheduledRunAt, scheduledRunAt <= scheduledBefore else { return false }
            }
            return true
        }
    }

    private enum DateFilterParseResult {
        case success(DateFilters)
        case failure(String)
    }

    private enum OptionalDateParseResult {
        case success(Date?)
        case failure(String)
    }

    private static func parseDateFilters(_ arguments: [String: AnyCodable]) -> DateFilterParseResult {
        func parse(_ key: String) -> OptionalDateParseResult {
            guard case .string(let value) = arguments[key] else { return .success(nil) }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .success(nil) }
            guard let date = parseISO8601(trimmed) else {
                return .failure("Invalid \(key): '\(value)' is not a valid ISO-8601 timestamp.")
            }
            return .success(date)
        }

        switch (parse("created_after"), parse("created_before"), parse("updated_after"), parse("updated_before"), parse("scheduled_after"), parse("scheduled_before")) {
        case (.success(let createdAfter), .success(let createdBefore), .success(let updatedAfter), .success(let updatedBefore), .success(let scheduledAfter), .success(let scheduledBefore)):
            return .success(DateFilters(
                createdAfter: createdAfter,
                createdBefore: createdBefore,
                updatedAfter: updatedAfter,
                updatedBefore: updatedBefore,
                scheduledAfter: scheduledAfter,
                scheduledBefore: scheduledBefore
            ))
        case (.failure(let message), _, _, _, _, _),
             (_, .failure(let message), _, _, _, _),
             (_, _, .failure(let message), _, _, _),
             (_, _, _, .failure(let message), _, _),
             (_, _, _, _, .failure(let message), _),
             (_, _, _, _, _, .failure(let message)):
            return .failure(message)
        }
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    private static func renderFilters(arguments: [String: AnyCodable], dispositionFilter: String) -> [String: AnyCodable] {
        var filters: [String: AnyCodable] = ["disposition_filter": .string(dispositionFilter)]
        for key in [
            "status_filter", "is_template", "has_parent_template", "parent_task_id",
            "is_scheduled", "query", "created_after", "created_before",
            "updated_after", "updated_before", "scheduled_after", "scheduled_before"
        ] {
            if let value = arguments[key] {
                filters[key] = value
            }
        }
        return filters
    }

    private static func makeSummary(task: AgentTask) -> TaskSummary {
        let description = preview(task.description, limit: descriptionPreviewLimit)
        return TaskSummary(
            id: task.id.uuidString,
            title: task.title,
            status: task.status.rawValue,
            disposition: task.disposition.rawValue,
            createdAt: formatDate(task.createdAt),
            updatedAt: formatDate(task.updatedAt),
            isTemplate: task.isTemplate,
            isScheduled: task.scheduledRunAt != nil,
            scheduledRunAt: task.scheduledRunAt.map(formatDate),
            hasParentTemplate: task.parentTaskID != nil,
            parentTemplateID: task.parentTaskID?.uuidString,
            truncatedDescriptionPreview: description.text,
            descriptionWasTruncated: description.wasTruncated,
            acceptanceCriteriaSummaries: task.acceptanceCriteria.map { AcceptanceCriterionSummary(name: $0.name, waivable: $0.waivable, hasInputEnumeratorPrompt: $0.inputEnumeratorPrompt != nil) },
            acceptanceCriteriaCount: task.acceptanceCriteria.count
        )
    }

    private static func preview(_ text: String, limit: Int) -> (text: String, wasTruncated: Bool) {
        guard text.count > limit else { return (text, false) }
        return (String(text.prefix(limit)), true)
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(value)
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            return "{}"
        }
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private struct ListTasksResponse: Encodable {
        let resultKind: String
        let completeDetails: Bool
        let note: String
        let filters: [String: AnyCodable]
        let pagination: Pagination
        let tasks: [TaskSummary]
    }

    private struct Pagination: Encodable {
        let offset: Int
        let limit: Int
        let returned: Int
        let totalMatching: Int
        let hasMore: Bool
        let nextOffset: Int?
    }

    private struct TaskSummary: Encodable {
        let id: String
        let title: String
        let status: String
        let disposition: String
        let createdAt: String
        let updatedAt: String
        let isTemplate: Bool
        let isScheduled: Bool
        let scheduledRunAt: String?
        let hasParentTemplate: Bool
        let parentTemplateID: String?
        let truncatedDescriptionPreview: String
        let descriptionWasTruncated: Bool
        let acceptanceCriteriaSummaries: [AcceptanceCriterionSummary]
        let acceptanceCriteriaCount: Int
    }

    private struct AcceptanceCriterionSummary: Encodable {
        let name: String
        let waivable: Bool
        let hasInputEnumeratorPrompt: Bool
    }
}
