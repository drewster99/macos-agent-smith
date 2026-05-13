import Foundation

/// Allows agents to fetch full details of one or more tasks by ID.
struct GetTaskDetailsTool: AgentTool {
    let name = "get_task_details"
    let toolDescription = """
        Fetch the full details of one or more tasks by their IDs, including title, description, \
        commentary, progress updates, result, and summary. Pass an array of task IDs (max 10) \
        to retrieve several tasks in a single call.
        """

    /// Maximum number of task IDs accepted in a single call.
    private static let maxTaskIDs = 10

    let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "task_ids": .dictionary([
                "type": .string("array"),
                "items": .dictionary(["type": .string("string")]),
                "description": .string("Array of task UUIDs to fetch. Maximum 10 IDs per call.")
            ])
        ]),
        "required": .array([.string("task_ids")])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        true
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        // Accept the canonical `task_ids` array, and tolerate a single legacy `task_id` string
        // so the LLM can degrade gracefully if it forgets the new schema.
        var requestedIDStrings: [String] = []
        if case .array(let items) = arguments["task_ids"] {
            for item in items {
                if case .string(let s) = item {
                    requestedIDStrings.append(s)
                }
            }
        } else if case .string(let single) = arguments["task_id"] {
            requestedIDStrings.append(single)
        }

        guard !requestedIDStrings.isEmpty else {
            throw ToolCallError.missingRequiredArgument("task_ids")
        }

        if requestedIDStrings.count > Self.maxTaskIDs {
            return .failure("Too many task IDs requested (\(requestedIDStrings.count)). Maximum is \(Self.maxTaskIDs) per call. Split into multiple calls.")
        }

        var sections: [String] = []
        var invalidIDs: [String] = []
        var notFoundIDs: [UUID] = []

        for idString in requestedIDStrings {
            guard let taskID = UUID(uuidString: idString) else {
                invalidIDs.append(idString)
                continue
            }
            guard let task = await context.taskStore.task(id: taskID) else {
                notFoundIDs.append(taskID)
                continue
            }
            sections.append(formatTask(task))
        }

        var output: [String] = []

        if !sections.isEmpty {
            // Separate each task with a horizontal rule so the LLM can clearly distinguish
            // boundaries between tasks in the response.
            output.append(sections.joined(separator: "\n\n---\n\n"))
        }

        if !invalidIDs.isEmpty {
            output.append("Invalid task IDs (not valid UUIDs): \(invalidIDs.joined(separator: ", "))")
        }
        if !notFoundIDs.isEmpty {
            let list = notFoundIDs.map(\.uuidString).joined(separator: ", ")
            output.append("No task found with ID(s): \(list). Use `list_tasks` to see available tasks.")
        }

        if output.isEmpty {
            return .failure("No tasks could be retrieved for the given IDs.")
        }

        // Failure if every requested ID was unresolvable; success if at least one task came back.
        let succeeded = !sections.isEmpty
        return ToolExecutionResult(output: output.joined(separator: "\n\n"), succeeded: succeeded)
    }

    /// Formats a single task's details. Each section is included only when present.
    private func formatTask(_ task: AgentTask) -> String {
        var parts: [String] = []
        parts.append("Task ID: \(task.id.uuidString)")
        parts.append("Title: \(task.title)")
        parts.append("Status: \(task.status.rawValue)")
        parts.append("Disposition: \(task.disposition.rawValue)")
        parts.append("Description: \(task.description)")

        if let commentary = task.commentary, !commentary.isEmpty {
            parts.append("Commentary: \(commentary)")
        }

        if !task.updates.isEmpty {
            let updateLines = task.updates.map { update in
                "  - [\(Self.formatDate(update.date))] \(update.message)"
            }
            parts.append("Progress updates:\n\(updateLines.joined(separator: "\n"))")
        }

        if let summary = task.summary, !summary.isEmpty {
            parts.append("Summary: \(summary)")
        }

        if let result = task.result, !result.isEmpty {
            parts.append("Result: \(result)")
        }

        return parts.joined(separator: "\n")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private static func formatDate(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }
}
