import Foundation

/// Brown tool: sends a progress update to Smith about the current task.
public struct TaskUpdateTool: AgentTool {
    public let name = "task_update"
    public let toolDescription = """
        Send a progress update to Smith about your current task. No status change occurs. \
        Optionally attach files via `attachment_ids` (IDs of attachments already known to \
        the task or session) or `attachment_paths` (local file paths you want to include — \
        each is read, persisted into the per-session attachments dir, and forwarded to Smith).
        """

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "message": .dictionary([
                "type": .string("string"),
                "description": .string("The progress update message.")
            ]),
            "attachment_ids": .dictionary([
                "type": .string("array"),
                "items": .dictionary(["type": .string("string")]),
                "description": .string("Optional UUID strings of existing attachments to forward with the update. Use when relaying an attachment Smith already knows about (the task's description attachments or a prior update's attachments).")
            ]),
            "attachment_paths": .dictionary([
                "type": .string("array"),
                "items": .dictionary(["type": .string("string")]),
                "description": .string("Optional local file paths to read and attach. Each path is loaded, persisted under the per-session attachments directory, and surfaced to Smith. Use for screenshots, generated artifacts, or output files produced during the task.")
            ])
        ]),
        "required": .array([.string("message")])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .brown
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard case .string(let message) = arguments["message"] else {
            throw ToolCallError.missingRequiredArgument("message")
        }

        guard let task = await context.taskStore.taskForAgent(agentID: context.agentID) else {
            return .failure("No active task assigned to you.")
        }

        let resolution = await Self.collectAttachments(arguments: arguments, context: context)
        if let failureMessage = resolution.failure {
            return .failure(failureMessage)
        }
        let attachments = resolution.attachments

        // Persist on the task so it survives restarts.
        await context.taskStore.addUpdate(id: task.id, message: message, attachments: attachments)

        guard let smithID = await context.agentIDForRole(.smith) else {
            return .failure("Agent Smith is not available.")
        }

        // Post Brown's update as clean content — no system guidance embedded in it,
        // so Brown cannot craft text that manipulates the guidance via prompt injection.
        await context.post(ChannelMessage(
            sender: .agent(context.agentRole),
            recipientID: smithID,
            recipient: .agent(.smith),
            content: "Task update for '\(task.title)': \(message)",
            attachments: attachments,
            metadata: ["messageKind": .string("task_update")]
        ))

        // Post guidance as a separate system message so it cannot be influenced by Brown's text.
        await context.post(ChannelMessage(
            sender: .system,
            recipientID: smithID,
            recipient: .agent(.smith),
            content: "Scrutinize Brown's task update above CAREFULLY in the context of the user's intent AND the task description and details. Make sure Brown is on track and hasn't veered off course. Offer assistance or helpful suggestions if Brown appears to NEED it. DO NOT REPLY if do not have MEANINGFUL input to add. The user ALREADY SEES Brown's task update directly in the channel — DO NOT repeat, summarize, paraphrase, or relay Brown's update to the user via message_user. Doing so is duplicative noise.",
            metadata: ["messageKind": .string("task_update_guidance")]
        ))

        if attachments.isEmpty {
            return .success("Update sent to Agent Smith.")
        }
        let names = attachments.map { $0.filename }.joined(separator: ", ")
        return .success("Update sent to Agent Smith with \(attachments.count) attachment(s): \(names)")
    }

    /// Resolves both `attachment_ids` (existing) and `attachment_paths` (new local files)
    /// into a single `[Attachment]` list. On any resolution failure (unknown ID,
    /// file-not-found, too-large) returns a tool failure message rather than silently
    /// dropping attachments — Brown should retry with a corrected list.
    ///
    /// Enforces the runtime's per-message aggregate cap by summing `byteCount` across
    /// the resolved set. The check runs after both id-resolution and path-ingestion so
    /// the LLM gets a single accurate "too big" message rather than a partial-then-fail.
    fileprivate static func collectAttachments(
        arguments: [String: AnyCodable],
        context: ToolContext
    ) async -> (attachments: [Attachment], failure: String?) {
        var collected: [Attachment] = []

        if case .array(let raw) = arguments["attachment_ids"] {
            let idStrings: [String] = raw.compactMap {
                if case .string(let s) = $0 { return s }
                return nil
            }
            if !idStrings.isEmpty {
                let outcome = await context.resolveAttachments(idStrings)
                if !outcome.rejected.isEmpty {
                    return (collected, "Unknown attachment_ids: \(outcome.rejected.joined(separator: ", ")). The IDs must come from a `[filename](file://…) … id=<UUID>` markdown link Smith or Brown previously saw — do not invent them.")
                }
                collected.append(contentsOf: outcome.resolved)
            }
        }

        if case .array(let raw) = arguments["attachment_paths"] {
            let paths: [String] = raw.compactMap {
                if case .string(let s) = $0 { return s }
                return nil
            }
            for path in paths {
                let outcome = await context.ingestAttachmentFile(path)
                if let attachment = outcome.attachment {
                    collected.append(attachment)
                } else {
                    return (collected, outcome.error ?? "Failed to ingest attachment at path: \(path)")
                }
            }
        }

        // Aggregate-size guard: reject the call if the resolved set exceeds the
        // runtime's per-message cap. Applies across both `attachment_ids` and
        // `attachment_paths` because the LLM doesn't necessarily know individual sizes.
        let cap = await context.maxAttachmentBytesPerMessage()
        let total = collected.reduce(0) { $0 + $1.byteCount }
        if cap > 0, total > cap {
            let totalMB = Double(total) / 1_048_576.0
            let capMB = Double(cap) / 1_048_576.0
            return (collected, String(
                format: "Attachments exceed the per-message size cap: %.1f MB total, %.1f MB cap. Reduce the number of files or use smaller variants. Configurable in Settings → Attachments.",
                totalMB, capMB
            ))
        }

        return (collected, nil)
    }
}

/// Bridge so `TaskCompleteTool` can reuse the same id+path resolution logic without
/// duplicating it. Internal to the package.
extension TaskUpdateTool {
    static func resolveAttachments(
        arguments: [String: AnyCodable],
        context: ToolContext
    ) async -> (attachments: [Attachment], failure: String?) {
        await collectAttachments(arguments: arguments, context: context)
    }
}
