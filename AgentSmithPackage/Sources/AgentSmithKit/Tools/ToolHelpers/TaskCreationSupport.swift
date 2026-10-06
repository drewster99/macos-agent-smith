import Foundation

/// The parts of creating a task that `create_task` (Smith) and `create_child_task` (a coordinator's
/// worker) share, so the two can't drift: how steps and required capabilities are read, how
/// relevant context is attached, and the New Task banner.
enum TaskCreationSupport {

    /// The `steps` argument as trimmed, non-empty texts, in order — or why it can't be read.
    static func stepTexts(from arguments: [String: AnyCodable]) -> Result<[String], MalformedListArgument> {
        stringList(arguments, "steps")
    }

    /// The `required_capabilities` argument as items of the task as written
    /// (`RequiredCapability.makeAsWritten`: duplicates dropped, keeping the first spelling) — or why
    /// it can't be read.
    static func requiredCapabilities(from arguments: [String: AnyCodable], addedBy author: TaskAuthorship) -> Result<[RequiredCapability], MalformedListArgument> {
        stringList(arguments, "required_capabilities").map { RequiredCapability.makeAsWritten($0, addedBy: author) }
    }

    struct MalformedListArgument: Error {
        let message: String
    }

    private static func stringList(_ arguments: [String: AnyCodable], _ key: String) -> Result<[String], MalformedListArgument> {
        switch ToolArguments.strictOptionalStringList(arguments, key) {
        case .absent: return .success([])
        case .value(let items): return .success(items)
        case .malformed(let problem): return .failure(MalformedListArgument(message: problem))
        }
    }

    /// The sentence a start tool returns instead of "starting" while the worker's model can't be used
    /// (`ProviderOutage`): the start waits, and Smith must not retry or recreate it. Nil otherwise.
    static func outageHoldNote(context: ToolContext) async -> String? {
        guard let outage = await context.workerProviderOutage() else { return nil }
        return "Queued, not started: the worker's model '\(outage.modelID)' can't be used (\(outage.kind.displayDescription)). It starts on its own when the user changes the worker's model or presses Play on a paused task. Do NOT call `run_task` on it again or recreate it."
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
