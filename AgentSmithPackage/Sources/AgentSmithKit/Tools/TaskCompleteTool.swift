import Foundation

/// Brown tool: submits the task result for Smith's review, transitioning it to awaitingReview.
public struct TaskCompleteTool: AgentTool {
    public let name = "task_complete"
    public let toolDescription = """
        Submit your completed work for review. Provide the full result — do not summarize. \
        After calling this, stop working and wait for Smith's verdict. \
        Optionally attach files via `attachment_ids` (existing IDs) or `attachment_paths` \
        (local file paths to ingest) so Smith can review screenshots, generated artifacts, \
        or any output produced during the task.
        """

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "result": .dictionary([
                "type": .string("string"),
                "description": .string("The full result of your work. Include everything relevant — do not summarize.")
            ]),
            "commentary": .dictionary([
                "type": .string("string"),
                "description": .string("Optional commentary about approach, caveats, or notes for Smith.")
            ]),
            "attachment_ids": .dictionary([
                "type": .string("array"),
                "items": .dictionary(["type": .string("string")]),
                "description": .string("Optional UUID strings of existing attachments (from the task description, prior updates, or earlier Brown sessions) to include with the result.")
            ]),
            "attachment_paths": .dictionary([
                "type": .string("array"),
                "items": .dictionary(["type": .string("string")]),
                "description": .string("Optional local file paths to read and attach to the result. Each is loaded, persisted to the per-session attachments directory, and surfaced to Smith with the awaitingReview banner.")
            ]),
            "deliverables": .dictionary([
                "type": .string("array"),
                "description": .string("Optional STRUCTURED deliverables — one entry per distinct piece of proof, so validators can find the evidence for each acceptance requirement. Each entry: `ref` (a short tag naming which requirement/deliverable it is), and any of `text` (an inline value/answer), `attachment_ids`, `attachment_paths` (files that ARE the evidence — e.g. per-locale screenshots), and `description` (for a group of files). Use this in ADDITION to `result` when the work has discrete, taggable evidence; omit it for a plain text result."),
                "items": .dictionary([
                    "type": .string("object"),
                    "properties": .dictionary([
                        "ref": .dictionary(["type": .string("string"), "description": .string("Short tag naming the requirement/deliverable this evidence is for.")]),
                        "text": .dictionary(["type": .string("string"), "description": .string("An inline value or note for this deliverable (e.g. the answer).")]),
                        "attachment_ids": .dictionary(["type": .string("array"), "items": .dictionary(["type": .string("string")]), "description": .string("Existing attachment UUIDs that are this deliverable's evidence.")]),
                        "attachment_paths": .dictionary(["type": .string("array"), "items": .dictionary(["type": .string("string")]), "description": .string("Local file paths (ingested) that are this deliverable's evidence.")]),
                        "description": .dictionary(["type": .string("string"), "description": .string("Description for a group of files under this deliverable.")])
                    ])
                ])
            ])
        ]),
        "required": .array([.string("result")])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .brown
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard case .string(let result) = arguments["result"] else {
            // Auto-reject submissions missing the `result` argument entirely.
            // Smith is never involved — the runtime refuses to admit the submission.
            await postAutoRejection(reason: "the `result` argument was missing entirely", context: context)
            throw ToolCallError.missingRequiredArgument("result")
        }

        let trimmedResult = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedResult.isEmpty else {
            // Auto-reject empty/whitespace-only submissions. The task is NEVER transitioned to
            // awaitingReview, so Smith never gets the chance to review (or accept) a result-less
            // task. Brown's LLM sees the failure in its tool result and must retry with real content.
            await postAutoRejection(reason: "the `result` argument was empty or whitespace-only", context: context)
            return .failure("Auto-rejected: result must contain a meaningful summary of the completed work. The task has NOT been submitted for review. Re-read the task requirements and call `task_complete` again with the FULL result.")
        }

        let commentary: String?
        if case .string(let c) = arguments["commentary"] {
            commentary = c
        } else {
            commentary = nil
        }

        guard let task = await context.taskStore.taskForAgent(agentID: context.agentID) else {
            return .failure("No active task assigned to you.")
        }

        // Idempotency guard — a duplicate submission isn't really a failure, but it's
        // not a fresh successful submission either. Return success with a clear message.
        if task.status == .awaitingReview || task.status == .completed || task.status == .validating {
            return .success("Task already submitted.")
        }

        let resolution = await TaskUpdateTool.resolveAttachments(arguments: arguments, context: context)
        if let failureMessage = resolution.failure {
            return .failure(failureMessage)
        }
        // Ingest everything the worker placed in its evidence directory (text reports, logs,
        // screenshots it copied in) so those artifacts become clickable result attachments. This is
        // the ONE place the sweep runs — `setResult` replaces the attachment list each submission,
        // so a resubmission re-sweeps without accumulating. Merged AFTER the worker's explicit
        // attachments and deduped by filename so an explicitly-referenced file isn't doubled.
        var attachments = resolution.attachments
        attachments += await Self.ingestEvidenceDirectory(context: context, existing: attachments)

        // Optional structured deliverables → resultItems (additive; empty when omitted). Each
        // entry becomes a text item and/or an attachment item/group, tagged with its `ref`. A
        // per-entry attachment-resolution failure is skipped (best-effort) rather than blocking
        // the whole submission — the plain `result` + swept evidence still carry the work.
        let resultItems = await Self.buildDeliverables(arguments: arguments, context: context)
        // Also merge any deliverable-only attachments into the canonical `resultAttachments` so
        // they show in the UI and re-register on cold boot — `resultItems` adds STRUCTURE/tags, it
        // is not a separate attachment store. Deduped by id against the already-collected set.
        var seenAttachmentIDs = Set(attachments.map { $0.id })
        for attachment in resultItems.flatMap({ $0.attachments }) where seenAttachmentIDs.insert(attachment.id).inserted {
            attachments.append(attachment)
        }

        // Store result on the task (survives restarts) and hand it to acceptance
        // validation — the evaluator system, not Smith, judges submissions now. The
        // "Ready for Review" banner is preserved for the UI via the same task_complete
        // message kind, posted publicly (Smith's filter drops it; the user sees it).
        await context.taskStore.setResult(id: task.id, result: result, commentary: commentary, attachments: attachments, resultItems: resultItems)
        await context.taskStore.updateStatus(id: task.id, status: .validating)

        var message = "Task '\(task.title)' submitted — acceptance validation is running."
        if let commentary {
            message += "\n\nCommentary:\n\(commentary)"
        }
        await context.post(ChannelMessage(
            sender: .agent(context.agentRole),
            content: message,
            attachments: attachments,
            metadata: [
                "messageKind": .string("task_complete"),
                "taskTitle": .string(task.title)
            ]
        ))

        await context.beginTaskValidation(task.id)

        if attachments.isEmpty {
            return .success("Task submitted. Acceptance validation will judge it against the task's criteria; you'll receive a punch list if changes are needed. Wait.")
        }
        let names = attachments.map { $0.filename }.joined(separator: ", ")
        return .success("Task submitted with \(attachments.count) attachment(s) (\(names)). Acceptance validation will judge it; you'll receive a punch list if changes are needed. Wait.")
    }

    /// Parses the optional `deliverables` argument into structured `ResultItem`s. Each entry
    /// yields a `.text` item (when `text` is present) and/or an attachment item — `.attachment`
    /// for a single file, `.attachmentGroup` for several or when a group `description` is given —
    /// tagged with the entry's `ref`. Best-effort: an entry with no usable content is skipped, and
    /// a per-entry attachment-resolution failure yields no attachments for that entry rather than
    /// failing the whole submission. Returns `[]` when `deliverables` is absent.
    static func buildDeliverables(arguments: [String: AnyCodable], context: ToolContext) async -> [ResultItem] {
        guard case .array(let rawDeliverables) = arguments["deliverables"] else { return [] }
        var items: [ResultItem] = []
        for raw in rawDeliverables {
            guard case .dictionary(let entry) = raw else { continue }

            var refs: [String] = []
            if case .string(let ref) = entry["ref"] {
                let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { refs = [trimmed] }
            }

            var description: String?
            if case .string(let d) = entry["description"] { description = d }

            if case .string(let text) = entry["text"],
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                items.append(ResultItem(content: .text(text), refs: refs))
            }

            var entryArgs: [String: AnyCodable] = [:]
            if let ids = entry["attachment_ids"] { entryArgs["attachment_ids"] = ids }
            if let paths = entry["attachment_paths"] { entryArgs["attachment_paths"] = paths }
            if !entryArgs.isEmpty {
                let resolved = await TaskUpdateTool.resolveAttachments(arguments: entryArgs, context: context).attachments
                if resolved.count == 1, description == nil {
                    items.append(ResultItem(content: .attachment(resolved[0]), refs: refs))
                } else if !resolved.isEmpty {
                    items.append(ResultItem(content: .attachmentGroup(attachments: resolved, description: description), refs: refs))
                }
            }
        }
        return items
    }

    /// Ingests every regular file in the task's evidence directory as an attachment, skipping any
    /// whose filename already appears in `existing` (the worker's explicitly-referenced attachments)
    /// so nothing is doubled. Best-effort: a file that can't be read or ingested is skipped. Returns
    /// the newly ingested attachments. No-op when the task has no evidence directory.
    static func ingestEvidenceDirectory(context: ToolContext, existing: [Attachment]) async -> [Attachment] {
        guard let evidenceDir = context.taskEvidenceDirectory else { return [] }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: evidenceDir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        var existingNames = Set(existing.map { $0.filename })
        var ingested: [Attachment] = []
        for fileURL in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isRegular = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            guard isRegular else { continue }
            let filename = fileURL.lastPathComponent
            guard !existingNames.contains(filename), let data = try? Data(contentsOf: fileURL) else { continue }
            let mimeType = Self.mimeType(forExtension: fileURL.pathExtension)
            let (attachment, _) = await context.ingestAttachmentData(data, filename, mimeType)
            if let attachment {
                ingested.append(attachment)
                existingNames.insert(filename)
            }
        }
        return ingested
    }

    /// Minimal extension→MIME mapping for evidence ingest. Unknown types fall back to
    /// `application/octet-stream`; the attachment layer sniffs images/PDFs from the bytes regardless.
    static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "pdf": return "application/pdf"
        case "md", "markdown", "txt", "log": return "text/plain"
        case "json": return "application/json"
        case "html", "htm": return "text/html"
        case "csv": return "text/csv"
        default: return "application/octet-stream"
        }
    }

    /// Posts a system channel message recording an auto-rejection of an empty/missing-result
    /// submission. Makes the rejection visible in the UI and channel log, even though no state
    /// transition occurred. Smith is not involved — this is a runtime-level guard at submission time.
    private func postAutoRejection(reason: String, context: ToolContext) async {
        await context.post(ChannelMessage(
            sender: .system,
            content: "Auto-rejected `task_complete` submission: \(reason). Brown has been told to retry; task remains in its prior state.",
            metadata: [
                "messageKind": .string("submission_auto_rejected"),
                "reason": .string(reason)
            ]
        ))
    }
}
