import Foundation

/// The parts of creating a task that `create_task` (Smith) and `create_child_task` (a coordinator's
/// worker) share, so the two can't drift: how steps and required capabilities are read, how
/// relevant context is attached, and the New Task banner.
enum TaskCreationSupport {

    /// The `steps` argument as trimmed, non-empty texts, in order.
    static func stepTexts(from arguments: [String: AnyCodable]) -> [String] {
        (ToolArguments.optionalArray(arguments, "steps") ?? []).compactMap { raw -> String? in
            guard case .string(let text) = raw else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// The `required_capabilities` argument as items of the task as written. Duplicates (compared
    /// as `RequiredCapability.normalizedText` does) are dropped, keeping the first spelling: one
    /// need listed twice is still one need.
    static func requiredCapabilities(from arguments: [String: AnyCodable], addedBy author: TaskAuthorship) -> [RequiredCapability] {
        var seen = Set<String>()
        return (ToolArguments.optionalArray(arguments, "required_capabilities") ?? []).compactMap { raw -> RequiredCapability? in
            guard case .string(let text) = raw else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let capability = RequiredCapability(text: trimmed, addedBy: author, origin: .asWritten)
            return seen.insert(capability.normalizedText).inserted ? capability : nil
        }
    }

    /// Retrieves memories and prior tasks relevant to a new (non-template) task, attaches them, and
    /// returns the sentence the tool result uses to say what was attached ("" when nothing was).
    static func attachRelevantContext(to task: AgentTask, context: ToolContext) async -> String {
        let retrieved = await context.retrieveContext(.newTask, task.title + " " + task.description)
        let attached = await TaskContextRetrieval.attachRelevantContext(
            taskID: task.id,
            results: retrieved,
            taskStore: context.taskStore
        )
        var noteParts: [String] = []
        if !attached.memories.isEmpty {
            noteParts.append("\(attached.memories.count) relevant memor\(attached.memories.count == 1 ? "y" : "ies")")
        }
        if !attached.priorTasks.isEmpty {
            noteParts.append("\(attached.priorTasks.count) relevant prior task\(attached.priorTasks.count == 1 ? "" : "s")")
        }
        return noteParts.isEmpty ? "" : " Attached: \(noteParts.joined(separator: ", "))."
    }

    /// Posts the New Task banner for a task just created, with its retrieved context and, when
    /// scheduled, its run time.
    static func announceCreated(taskID: UUID, title: String, description: String, scheduledRunAt: Date?, context: ToolContext) async {
        var meta: [String: AnyCodable] = [
            "messageKind": .kind(.taskCreated),
            "taskID": .string(taskID.uuidString),
            "taskDescription": .string(description)
        ]
        // Surface the scheduled run time so the New Task banner can render a chip on the
        // right ("Scheduled 9:15 AM"). Stored as Unix epoch seconds for stable round-tripping
        // through the existing AnyCodable JSON persistence path.
        if let scheduledRunAt {
            meta["scheduledRunAt"] = .double(scheduledRunAt.timeIntervalSince1970)
        }
        if let task = await context.taskStore.taskOrLibraryTemplate(id: taskID) {
            meta.merge(task.taskCreatedBannerCapabilitiesMetadata()) { current, _ in current }
            if let memories = task.relevantMemories, !memories.isEmpty {
                meta["contextMemoryCount"] = .int(memories.count)
                // Each entry: "85% — content [tags]". Entries separated by ASCII Record
                // Separator (U+001E) so multi-line content can't accidentally split entries
                // when the UI parses the metadata string.
                meta["contextMemories"] = .string(memories.map { m in
                    let pct = String(format: "%.0f%%", m.similarity * 100)
                    let tags = m.tags.isEmpty ? "" : " [\(m.tags.joined(separator: ", "))]"
                    return "\(pct) — \(m.content)\(tags)"
                }.joined(separator: "\u{1E}"))
            }
            if let priorTasks = task.relevantPriorTasks, !priorTasks.isEmpty {
                meta["contextPriorTaskCount"] = .int(priorTasks.count)
                // Each entry: header line ("85% — Title (id: UUID)") + newline + summary body.
                // Entries separated by ASCII Record Separator (U+001E) so summary bodies that
                // contain their own newlines (numbered lists, etc.) don't bleed between tasks
                // when the UI parses the metadata string.
                meta["contextPriorTasks"] = .string(priorTasks.map { p in
                    let pct = String(format: "%.0f%%", p.similarity * 100)
                    return "\(pct) — \(p.title) (id: \(p.taskID.uuidString))\n\(p.summary)"
                }.joined(separator: "\u{1E}"))
            }
        }
        await context.post(ChannelMessage(
            sender: .system,
            content: title,
            metadata: meta
        ))
    }
}
