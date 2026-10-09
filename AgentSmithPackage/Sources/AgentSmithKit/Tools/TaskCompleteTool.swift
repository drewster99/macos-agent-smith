import Foundation

/// Brown tool: submits the task result for Smith's review, transitioning it to awaitingReview.
public struct TaskCompleteTool: AgentTool {
    /// Submitting work is a task communication. Parking is handled separately, by `handoffLifecycleTools`.
    public var successEffects: Set<ToolEffect> { [.reportedTaskProgress] }

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
        commentary = ToolArguments.optionalString(arguments, "commentary")

        guard let task = await context.taskStore.taskForAgent(agentID: context.agentID) else {
            return .failure("No active task assigned to you.")
        }

        // Idempotency guard — a duplicate submission isn't really a failure, but it's
        // not a fresh successful submission either. Return success with a clear message.
        if task.status == .awaitingReview || task.status == .completed || task.status == .validating {
            return .success("Task already submitted.")
        }

        // Shared by the top-level attachments and every deliverable, so a file cited in both is
        // ingested once and the deliverable points at the same attachment.
        let pathIngestions = AttachmentPathIngestions()
        let resolution = await TaskUpdateTool.resolveAttachments(arguments: arguments, context: context, pathIngestions: pathIngestions)
        if let failureMessage = resolution.failure {
            return .failure(failureMessage)
        }
        // Optional structured deliverables → resultItems (additive; empty when omitted). Each
        // entry becomes a text item and/or an attachment item/group, tagged with its `ref`. A
        // per-entry attachment-resolution failure is skipped (best-effort) rather than blocking
        // the whole submission — the plain `result` + swept evidence still carry the work.
        let resultItems = await Self.buildDeliverables(arguments: arguments, context: context, pathIngestions: pathIngestions)
        // Also merge any deliverable-only attachments into the canonical `resultAttachments` so
        // they show in the UI and re-register on cold boot — `resultItems` adds STRUCTURE/tags, it
        // is not a separate attachment store. Deduped by id against the already-collected set.
        var attachments = resolution.attachments
        var seenAttachmentIDs = Set(attachments.map { $0.id })
        for attachment in resultItems.flatMap({ $0.attachments }) where seenAttachmentIDs.insert(attachment.id).inserted {
            attachments.append(attachment)
        }
        // Ingest everything the worker placed in its evidence directory (text reports, logs,
        // screenshots it copied in) so those artifacts become clickable result attachments. This is
        // the ONE place the sweep runs — `setResult` replaces the attachment list each submission,
        // so a resubmission re-sweeps without accumulating. Runs LAST and skips a file already
        // attached (same bytes, either form of its name), so a
        // file the worker already attached — explicitly or through a deliverable, which is how
        // workers usually cite their evidence file — is not ingested a second time.
        let evidenceSweep = await Self.ingestEvidenceDirectory(context: context, existing: attachments)
        attachments += evidenceSweep.attachments
        let evidenceProblemNote = evidenceSweep.problems.isEmpty ? "" : """


            Evidence not attached:
            \(evidenceSweep.problems.map { "- \($0)" }.joined(separator: "\n"))
            """

        // Store result on the task (survives restarts) and hand it to acceptance
        // validation — the evaluator system, not Smith, judges submissions now. The
        // "Ready for Review" banner is preserved for the UI via the same task_complete
        // message kind, posted publicly (Smith's filter drops it; the user sees it).
        await context.taskStore.setResult(id: task.id, result: result, commentary: commentary, attachments: attachments, resultItems: resultItems)
        guard await context.taskStore.updateStatus(id: task.id, status: .validating, cause: .submittedForValidation) else {
            let current = await context.taskStore.task(id: task.id)?.status.displayName ?? "unknown"
            return .failure("The task is \(current), so it can't be submitted for validation right now. Your result is saved on the task.")
        }

        var message = "Task '\(task.title)' submitted — acceptance validation is running."
        if let commentary {
            message += "\n\nCommentary:\n\(commentary)"
        }
        message += evidenceProblemNote
        await context.post(ChannelMessage(
            sender: .agent(context.agentRole),
            content: message,
            attachments: attachments,
            metadata: [
                "messageKind": .kind(.taskComplete),
                "taskTitle": .string(task.title)
            ]
        ))

        await context.beginTaskValidation(task.id)

        if attachments.isEmpty {
            return .success("Task submitted. Acceptance validation will judge it against the task's criteria; you'll receive a punch list if changes are needed. Wait.\(evidenceProblemNote)")
        }
        let names = attachments.map { $0.filename }.joined(separator: ", ")
        return .success("Task submitted with \(attachments.count) attachment(s) (\(names)). Acceptance validation will judge it; you'll receive a punch list if changes are needed. Wait.\(evidenceProblemNote)")
    }

    /// Parses the optional `deliverables` argument into structured `ResultItem`s. Each entry
    /// yields a `.text` item (when `text` is present) and/or an attachment item — `.attachment`
    /// for a single file, `.attachmentGroup` for several or when a group `description` is given —
    /// tagged with the entry's `ref`. Best-effort: an entry with no usable content is skipped, and
    /// a per-entry attachment-resolution failure yields no attachments for that entry rather than
    /// failing the whole submission. Returns `[]` when `deliverables` is absent.
    static func buildDeliverables(
        arguments: [String: AnyCodable],
        context: ToolContext,
        pathIngestions: AttachmentPathIngestions = AttachmentPathIngestions()
    ) async -> [ResultItem] {
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
                let resolved = await TaskUpdateTool.resolveAttachments(arguments: entryArgs, context: context, pathIngestions: pathIngestions).attachments
                if resolved.count == 1, description == nil {
                    items.append(ResultItem(content: .attachment(resolved[0]), refs: refs))
                } else if !resolved.isEmpty {
                    items.append(ResultItem(content: .attachmentGroup(attachments: resolved, description: description), refs: refs))
                }
            }
        }
        return items
    }

    /// What the evidence sweep did: the files it attached, and every piece of evidence it could not
    /// attach and why. A problem is reported to the worker and the transcript, never dropped.
    struct EvidenceSweep: Sendable, Equatable {
        var attachments: [Attachment] = []
        var problems: [String] = []
    }

    /// The most evidence files one submission attaches. A worker that dumped a build tree into its
    /// evidence directory would otherwise attach thousands of files to one message.
    static let maxEvidenceFiles = 200

    /// Ingests every regular file under the task's evidence directory — subfolders included, each
    /// named by its path relative to the directory (`screenshots/1.png`) — as an attachment, skipping
    /// any already in `existing` (the worker's explicit and deliverable attachments): the same file,
    /// judged by bytes and either form of its name, so nothing is doubled. Hidden files and package
    /// contents are skipped; a symbolic link is never followed. Every file that is evidence but
    /// could not be attached — unreadable, too large, over the file limit, a link, a failed
    /// ingest — is reported in `problems`. No evidence directory, or one that was never created, is
    /// an empty sweep.
    static func ingestEvidenceDirectory(context: ToolContext, existing: [Attachment]) async -> EvidenceSweep {
        guard let evidenceDir = context.taskEvidenceDirectory else { return EvidenceSweep() }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: evidenceDir.path, isDirectory: &isDirectory) else { return EvidenceSweep() }
        var sweep = EvidenceSweep()
        guard isDirectory.boolValue else {
            sweep.problems.append("the evidence path \(evidenceDir.path) is not a directory")
            return sweep
        }
        // The canonical path, so it shares the enumerated paths' prefix even when the directory is
        // reached through a symlink: the enumerator reports `/private/var/…` for a `/var/…` temp
        // directory. Not `resolvingSymlinksInPath()`, which maps `/private/var` BACK to `/var`.
        guard let canonicalPath = realpath(evidenceDir.path, nil) else {
            sweep.problems.append("the evidence directory \(evidenceDir.path) could not be resolved: \(String(cString: strerror(errno)))")
            return sweep
        }
        let root = URL(fileURLWithPath: String(cString: canonicalPath), isDirectory: true)
        free(canonicalPath)

        let listing = await Self.offCooperativePool { Self.listEvidenceFiles(under: root) }
        var candidates = listing.files
        sweep.problems += listing.problems

        candidates.sort { $0.relativePath < $1.relativePath }
        if candidates.count > maxEvidenceFiles {
            let skipped = candidates[maxEvidenceFiles...].map(\.relativePath)
            sweep.problems.append("\(skipped.count) file(s) over the \(maxEvidenceFiles)-file limit were not attached: \(skipped.prefix(10).joined(separator: ", "))\(skipped.count > 10 ? ", …" : "")")
            candidates.removeLast(candidates.count - maxEvidenceFiles)
        }

        // The same per-message cap explicit attachments are held to, counted across everything this
        // submission carries — checked against each file's size BEFORE reading it.
        let byteCap = await context.maxAttachmentBytesPerMessage()
        var totalBytes = existing.reduce(0) { $0 + $1.byteCount }
        for candidate in candidates {
            let mimeType = AttachmentRegistry.mimeType(forPathExtension: candidate.url.pathExtension)
            // An explicit attachment of `sub/report.md` is named `report.md`; only those can be this
            // same file (each path is visited once, so nothing this sweep attached can be).
            let bareName = (candidate.relativePath as NSString).lastPathComponent
            let namesakes = existing.filter { $0.filename == candidate.relativePath || $0.filename == bareName }
            let overCap = byteCap > 0 && totalBytes + candidate.size > byteCap
            // Over the cap, the file is read only when it may already be attached — then it needs no room.
            if overCap && namesakes.isEmpty {
                sweep.problems.append(Self.overCapProblem(candidate.relativePath, byteCap: byteCap))
                continue
            }
            let data: Data
            switch await Self.offCooperativePool({ Result { try Data(contentsOf: candidate.url) } }) {
            case .success(let read):
                data = read
            case .failure(let error):
                sweep.problems.append("\(candidate.relativePath): \(error.localizedDescription)")
                continue
            }
            // Skip only the SAME file already attached, not merely one sharing its name: a distinct
            // file that happens to share a name with another attachment is still evidence.
            if Self.isAttached(data, mimeType: mimeType, amongNamesakes: namesakes) { continue }
            if overCap {
                sweep.problems.append(Self.overCapProblem(candidate.relativePath, byteCap: byteCap))
                continue
            }
            let (attachment, error) = await context.ingestAttachmentData(data, candidate.relativePath, mimeType)
            guard let attachment else {
                sweep.problems.append("\(candidate.relativePath): \(error ?? "could not be attached")")
                continue
            }
            sweep.attachments.append(attachment)
            totalBytes += attachment.byteCount
        }
        return sweep
    }

    private static func overCapProblem(_ relativePath: String, byteCap: Int) -> String {
        String(format: "%@: not attached — it would take this submission over the %.1f MB attachment limit", relativePath, Double(byteCap) / 1_048_576.0)
    }

    /// Runs blocking file-system work (a directory walk, a file read) on a dispatch queue rather
    /// than the cooperative pool, which every task in the process shares and must keep moving.
    private static func offCooperativePool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }

    /// One file the evidence sweep may attach.
    private struct EvidenceFile: Sendable {
        let relativePath: String
        let url: URL
        let size: Int
    }

    /// Every regular file under `root` (resolved), each with its path relative to `root`, plus a
    /// problem line for every entry that is evidence but can't be attached as a file. Synchronous —
    /// `FileManager`'s directory walk cannot run in an async context — and called off the
    /// cooperative pool (`offCooperativePool`).
    private static func listEvidenceFiles(under root: URL) -> (files: [EvidenceFile], problems: [String]) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .fileSizeKey]
        let rootComponentCount = root.pathComponents.count
        func relativePath(of url: URL) -> String {
            url.pathComponents.dropFirst(rootComponentCount).joined(separator: "/")
        }
        let enumerationProblems = EvidenceEnumerationProblems()
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in
                enumerationProblems.append("\(relativePath(of: url)): \(error.localizedDescription)")
                return true
            }
        ) else {
            return ([], ["the evidence directory \(root.path) could not be read"])
        }
        var files: [EvidenceFile] = []
        var problems: [String] = []
        for case let url as URL in enumerator {
            let relativePath = relativePath(of: url)
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: Set(keys))
            } catch {
                problems.append("\(relativePath): \(error.localizedDescription)")
                continue
            }
            if values.isSymbolicLink == true {
                problems.append("\(relativePath): a symbolic link, not followed")
                continue
            }
            if values.isPackage == true {
                problems.append("\(relativePath): a package (bundle), not attached — zip it to include it")
                continue
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else {
                problems.append("\(relativePath): not a regular file")
                continue
            }
            files.append(EvidenceFile(relativePath: relativePath, url: url, size: values.fileSize ?? 0))
        }
        return (files, problems + enumerationProblems.all)
    }

    /// Whether a file with these bytes is already among `namesakes` — the attachments named like it.
    /// An attachment's stored bytes went through `AttachmentSanitizer` at ingest, which re-encodes
    /// images and rewrites PDFs, so the file matches either its raw or its sanitized bytes. An
    /// attachment resolved by id may not have its bytes loaded; its recorded size stands in then.
    private static func isAttached(_ data: Data, mimeType: String, amongNamesakes namesakes: [Attachment]) -> Bool {
        guard !namesakes.isEmpty else { return false }
        func matches(_ candidate: Data) -> Bool {
            namesakes.contains { attachment in
                if let attached = attachment.data { return attached == candidate }
                return attachment.byteCount == candidate.count
            }
        }
        return matches(data) || matches(AttachmentSanitizer.sanitize(data, mimeType: mimeType))
    }

    /// Posts a system channel message recording an auto-rejection of an empty/missing-result
    /// submission. Makes the rejection visible in the UI and channel log, even though no state
    /// transition occurred. Smith is not involved — this is a runtime-level guard at submission time.
    private func postAutoRejection(reason: String, context: ToolContext) async {
        await context.post(ChannelMessage(
            sender: .system,
            content: "Auto-rejected `task_complete` submission: \(reason). Brown has been told to retry; task remains in its prior state.",
            metadata: [
                "messageKind": .kind(.submissionAutoRejected),
                "reason": .string(reason)
            ]
        ))
    }
}

/// Collects the errors `FileManager.enumerator` reports through its handler while one evidence
/// sweep walks the directory. The handler runs synchronously inside that walk, on the sweep's own
/// thread, so it is never shared.
private final class EvidenceEnumerationProblems {
    private(set) var all: [String] = []
    func append(_ problem: String) { all.append(problem) }
}
