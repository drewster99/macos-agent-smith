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

        // Store result on the task (survives restarts) and hand it to acceptance
        // validation — the evaluator system, not Smith, judges submissions now. The
        // "Ready for Review" banner is preserved for the UI via the same task_complete
        // message kind, posted publicly (Smith's filter drops it; the user sees it).
        await context.taskStore.setResult(id: task.id, result: result, commentary: commentary, attachments: attachments)
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
