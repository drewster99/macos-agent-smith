import Foundation

/// Allows Smith to create new tasks.
///
/// Tasks default to `.pending`. When `scheduled_run_at` is supplied with a future time, the
/// task is created with status `.scheduled` and a paired `schedule_task_action(action: run)`
/// timer is auto-registered against the new task — the timer fires at `scheduled_run_at` and
/// instructs Smith to call `run_task`. The auto-runner skips `.scheduled` tasks so this
/// closes the previous "user expected fire-time, queue jumped ahead" race.
public struct CreateTaskTool: AgentTool {
    public let name = "create_task"
    public let toolDescription = """
        Create a new task. If no other task is currently running or awaiting review, the new task \
        auto-starts immediately and the system restarts on it — you do NOT need a follow-up \
        `run_task` call. If another task is running or awaiting review, the new task is queued as \
        pending; the response tells you so and you should leave it alone until the current task \
        finishes. \
        \
        Optional `scheduled_run_at`: an ISO-8601 timestamp at which the task should run. When \
        set, the task is created with status `scheduled` (auto-start is suppressed) and a timer is \
        auto-scheduled to fire at that time and instruct you to call `run_task`. Do NOT call \
        `schedule_task_action` separately when you've already passed `scheduled_run_at` — that \
        would double-schedule the run. \
        \
        IMPORTANT — `attachment_ids`: if the user's message included ANY attachments (an image, \
        screenshot, PDF, or other file — shown to you as `[filename](file://…) … id=<UUID>` \
        markdown links), and the worker might need them to do the task, you MUST pass their EXACT \
        `id=` UUIDs in the `attachment_ids` array. The worker (Brown) does NOT see the user's \
        attachments unless you forward them here — omitting them means the worker is blind to the \
        screenshot/file the user provided.
        """

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "title": .dictionary([
                "type": .string("string"),
                "description": .string("Short title for the task.")
            ]),
            "description": .dictionary([
                "type": .string("string"),
                "description": .string("Detailed description of what needs to be done. This description should include (1) A detailed description of the goal or problem being solved, (2) A markdown-formatted step by step list of all the things that need to be done, including any relevant inputs, data files, or user directives, (3) The desired result/output of the task, (4) A brief list of verifications, tests, or other steps to be taken to confirm successful completion and a second section for success verification / things to test or double-check for completeness.")
            ]),
            "scheduled_run_at": .dictionary([
                "type": .string("string"),
                "description": .string("Optional ISO-8601 timestamp. When set and in the future, the task is created with status `scheduled` and a paired timer fires at that time to run it. Use when the user says \"do X at <time>\".")
            ]),
            "attachment_ids": .dictionary([
                "type": .string("array"),
                "items": .dictionary(["type": .string("string")]),
                "description": .string("Optional UUID strings of attachments to include with this task. Use when the user attached an image, PDF, or file the worker will need. The IDs are surfaced in the user's incoming message as `[filename](file://…) … id=<UUID>` markdown links. Forward the EXACT id values verbatim. Brown will see image attachments as image content and any non-image attachments as text references with file paths.")
            ]),
            "acceptance_criteria": .dictionary([
                "type": .string("array"),
                "description": .string("Acceptance criteria — the checklist the automated validation system judges the worker's submission against. PROVIDE THESE ON EVERY REAL TASK: derive 2-5 concrete, evidence-checkable criteria from what the user asked for (including any validation the user explicitly requested). Each item is either a STRING (criterion text, default validator) or an OBJECT {text, waivable?, validator_name?, prepare?, inline_validator?} — the same shapes as `set_acceptance_criteria`, so custom/named validators and dynamic prepare functions can be attached at creation. The validator is EXTREMELY strict and literal: write each criterion so a CORRECT result passes even in edge cases — ties, zero/empty results, nonexistent targets, ambiguous inputs (e.g. 'identifies the most-starred repository, or reports a tie / that none exists, whichever the data shows'). If the worker can do the task correctly and still fail the criterion as written, the criterion is wrong — and repeated no-progress rejections FAIL the task. Omit only for trivial reminder-style tasks.")
            ]),
            "steps": .dictionary([
                "type": .string("array"),
                "items": .dictionary(["type": .string("string")]),
                "description": .string("Initial step list for the worker, in order. PROVIDE THIS whenever the work has a natural sequence — it seeds the worker's plan and gives validators a record to check against. The worker owns and evolves it from there (`manage_steps`); validators see the final list including anything skipped or removed.")
            ]),
            "is_template": .dictionary([
                "type": .string("boolean"),
                "description": .string("Make this a TEMPLATE. A template never runs itself — each time it's started, a fresh instance is cloned (title/description/steps/criteria copied, all run-state blank) and that instance runs. Use for a task the user wants to trigger repeatedly and get a clean run each time. Default false. (When you schedule a RECURRING run on a task, it becomes a template automatically.)")
            ])
        ]),
        "required": .array([.string("title"), .string("description")])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .smith
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        // gemma3:27b has been seen calling create_task with empty arg objects ({})
        // even when the user clearly meant "run the existing pending task." If
        // title/description are missing AND there's already a pending task that
        // would match the user's intent, redirect the model to run_task instead
        // of letting it spin in apology loops. We do NOT auto-act here — we
        // return a failure with the exact run_task call to make next, so the
        // model takes the corrective action explicitly.
        guard case .string(let title) = arguments["title"] else {
            return .failure(await Self.missingTitleFailure(context: context))
        }
        guard case .string(let description) = arguments["description"] else {
            return .failure(await Self.missingDescriptionFailure(context: context, title: title))
        }

        // Resolve any caller-supplied attachment IDs against the per-session registry.
        // Unknown IDs are returned as a tool failure so Smith re-issues create_task with
        // a corrected list rather than silently dropping the user's attachments.
        var resolvedAttachments: [Attachment] = []
        if case .array(let raw) = arguments["attachment_ids"] {
            let idStrings: [String] = raw.compactMap {
                if case .string(let s) = $0 { return s }
                return nil
            }
            if !idStrings.isEmpty {
                let outcome = await context.resolveAttachments(idStrings)
                if !outcome.rejected.isEmpty {
                    return .failure("create_task: unknown attachment_ids: \(outcome.rejected.joined(separator: ", ")). Use the EXACT id values from the `[filename](file://…) … id=<UUID>` markdown links in the user's message.")
                }
                resolvedAttachments = outcome.resolved
            }
        }

        var scheduledRunAt: Date?
        if case .string(let isoString) = arguments["scheduled_run_at"] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var parsed = formatter.date(from: isoString)
            if parsed == nil {
                let lenient = ISO8601DateFormatter()
                lenient.formatOptions = [.withInternetDateTime]
                parsed = lenient.date(from: isoString)
            }
            guard let resolved = parsed else {
                return .failure("Invalid scheduled_run_at: '\(isoString)' is not a valid ISO-8601 timestamp.")
            }
            if resolved <= Date().addingTimeInterval(5) {
                return .failure("scheduled_run_at must be at least 5 seconds in the future. To run immediately, omit the field.")
            }
            scheduledRunAt = resolved
        }

        // Refuse to create a duplicate of an existing active task with the same title.
        let existingTasks = await context.taskStore.allTasks()
        let actionableStatuses: Set<AgentTask.Status> = [.pending, .running, .paused, .awaitingReview, .interrupted, .scheduled, .validating]
        if let duplicate = existingTasks.first(where: {
            $0.disposition == .active && actionableStatuses.contains($0.status) && $0.title.caseInsensitiveCompare(title) == .orderedSame
        }) {
            return .failure("""
                A task with the same title already exists: "\(duplicate.title)" \
                (ID: \(duplicate.id), status: \(duplicate.status.rawValue)). \
                Use the existing task instead of creating a duplicate.
                """)
        }

        // Parse acceptance criteria BEFORE creating the task — bad criteria then mean
        // NO task, not an orphaned banner-less task plus a "fix it later" errand.
        // Criteria accept the same shapes as set_acceptance_criteria: plain strings, or
        // {text, waivable?, validator_name?, prepare?, inline_validator?} objects — so Smith
        // can attach custom validators at creation time, not just after.
        var seedCriteria: [AcceptanceCriterion] = []
        if case .array(let rawCriteria) = arguments["acceptance_criteria"], !rawCriteria.isEmpty {
            let registry = await context.loadEvaluatorRegistry()
            switch CriterionArgumentParsing.parse(rawCriteria, registry: registry) {
            case .success(let parsed):
                seedCriteria = parsed.map {
                    AcceptanceCriterion(text: $0.text, waivable: $0.waivable, origin: .smith, validator: $0.validator, prepare: $0.prepare)
                }
            case .failure(let problem):
                return .failure("Task NOT created — the acceptance_criteria are invalid: \(problem.message) Fix them and call create_task again.")
            }
        }

        var isTemplate = false
        if case .bool(let flag) = arguments["is_template"] { isTemplate = flag }

        let task = await context.taskStore.addTask(
            title: title,
            description: description,
            scheduledRunAt: scheduledRunAt,
            descriptionAttachments: resolvedAttachments,
            isTemplate: isTemplate
        )

        if !seedCriteria.isEmpty {
            await context.taskStore.setAcceptanceCriteria(id: task.id, criteria: seedCriteria)
        }
        if case .array(let rawSteps) = arguments["steps"] {
            let texts = rawSteps.compactMap { raw -> String? in
                guard case .string(let s) = raw else { return nil }
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            if !texts.isEmpty {
                await context.taskStore.setSteps(
                    id: task.id,
                    steps: texts.map { TaskStep(text: $0, origin: .smith) }
                )
            }
        }

        // Search semantic memory for relevant context to attach to this task.
        let searchQuery = title + " " + description
        var contextNote = ""
        do {
            let results = try await context.memoryStore.searchAll(
                query: searchQuery,
                memoryLimit: 3,
                taskLimit: 3,
                memoryCosineGate: MemoryStore.memoryInjectionCosineGate,
                taskCosineGate: MemoryStore.taskInjectionCosineGate,
                memoryInstruction: MemoryStore.memoryRetrievalInstruction,
                taskInstruction: MemoryStore.taskRetrievalInstruction
            )
            if !results.isEmpty {
                let memories: [RelevantMemory]? = results.memories.isEmpty ? nil : results.memories.map {
                    RelevantMemory(
                        content: $0.memory.content,
                        tags: $0.memory.tags,
                        similarity: $0.similarity,
                        createdAt: $0.memory.createdAt,
                        lastUpdatedAt: $0.memory.lastUpdatedAt
                    )
                }
                let priorTasks: [RelevantPriorTask]? = results.taskSummaries.isEmpty ? nil : results.taskSummaries.map {
                    RelevantPriorTask(
                        taskID: $0.summary.id,
                        title: $0.summary.title,
                        summary: $0.summary.summary,
                        similarity: $0.similarity,
                        latestDate: $0.summary.createdAt
                    )
                }
                await context.taskStore.setRelevantContext(
                    id: task.id,
                    memories: memories,
                    priorTasks: priorTasks
                )

                var parts: [String] = []
                if let memories, !memories.isEmpty {
                    parts.append("\(memories.count) relevant memor\(memories.count == 1 ? "y" : "ies")")
                }
                if let priorTasks, !priorTasks.isEmpty {
                    parts.append("\(priorTasks.count) relevant prior task\(priorTasks.count == 1 ? "" : "s")")
                }
                if !parts.isEmpty {
                    contextNote = " Attached: \(parts.joined(separator: ", "))."
                }
            }
        } catch {
            // Memory search failure is non-fatal — task still gets created.
        }

        // Build metadata for the task_created channel message, including any retrieved context.
        var meta: [String: AnyCodable] = [
            "messageKind": .string("task_created"),
            "taskID": .string(task.id.uuidString),
            "taskDescription": .string(description)
        ]
        // Surface the scheduled run time so the New Task banner can render a chip on the
        // right ("Scheduled 9:15 AM"). Stored as Unix epoch seconds for stable round-tripping
        // through the existing AnyCodable JSON persistence path.
        if let scheduledRunAt {
            meta["scheduledRunAt"] = .double(scheduledRunAt.timeIntervalSince1970)
        }
        if let task = await context.taskStore.task(id: task.id) {
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

        // If the caller asked for a scheduled run, register the matching wake immediately so
        // the user-visible chain is one tool call → one timer + one task.
        if let scheduledRunAt {
            let imperative = TaskActionKind.run.imperativeText(
                for: task.copyWithScheduledRunAt(scheduledRunAt),
                extra: nil
            )
            let outcome = await context.scheduleWake(
                scheduledRunAt,
                imperative,
                task.id,
                nil,
                nil,
                TaskActionKind.run.survivesTaskTermination
            )
            switch outcome {
            case .scheduled(let wake):
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                return .success("Task created (ID: \(task.id), title: \"\(title)\") in scheduled status. Will fire at \(formatter.string(from: scheduledRunAt)) (timer id \(wake.id.uuidString)).\(contextNote)")
            case .error(let message):
                return .success("Task created (ID: \(task.id), title: \"\(title)\") but timer registration failed: \(message). Re-schedule via schedule_task_action(task_id: \(task.id.uuidString), action: \"run\").")
            }
        }

        // A TEMPLATE is a launcher, not work to run — never auto-start it. It runs only
        // when explicitly started (run_task / play button / a scheduled run), which then
        // clones a fresh instance.
        if isTemplate {
            return .success("Template task created (ID: \(task.id), title: \"\(title)\").\(contextNote) It won't run on its own — starting it (run_task, the play button, or a scheduled run) clones a fresh instance each time.")
        }

        // Auto-start the new task when a worker slot is free. Prevents the failure mode
        // where Smith creates a task and then idles instead of immediately calling
        // run_task. Beyond capacity the task queues as pending — auto-run starts it when
        // a slot frees; Smith must NOT poll run_task for it.
        let capacity = await context.workerCapacity()
        let slotHolders = existingTasks.filter { other in
            other.id != task.id &&
            other.disposition == .active &&
            (other.status == .running || other.status == .awaitingReview || other.status == .validating)
        }
        if slotHolders.count < capacity {
            await context.restartForNewTask(task.id)
            return .success("Task created (ID: \(task.id), title: \"\(title)\").\(contextNote) A worker is being spawned to begin work on it now.")
        }

        return .success("Task created (ID: \(task.id), title: \"\(title)\").\(contextNote) All \(capacity) task slot(s) are busy — it is queued as pending and auto-run will start it when a slot frees. Do NOT call `run_task` on it.")
    }

    /// Build the "missing title" tool error. If there's exactly one pending task
    /// already, mention run_task as a possibility — observed on gemma3:27b emitting
    /// empty-argument create_task calls when "yes go ahead" clearly meant "run the
    /// existing pending task."
    ///
    /// The candidate set excludes once-scheduled tasks (`scheduledRunAt != nil`), and the
    /// wording offers rather than asserts: an earlier version claimed the pending task
    /// "matches the user's intent" without having checked, which steered Smith into
    /// welding an unrelated user request onto a system-promoted 9 PM reminder
    /// (2026-07-08 incident).
    private static func missingTitleFailure(context: ToolContext) async -> String {
        let allTasks = await context.taskStore.allTasks()
        let pending = allTasks.filter {
            $0.disposition == .active && $0.scheduledRunAt == nil && (
                $0.status == .pending || $0.status == .paused || $0.status == .interrupted
            )
        }
        if pending.count == 1, let only = pending.first {
            return """
                Missing required argument 'title' for create_task. \
                If the user is describing NEW work, re-call create_task with title=<short imperative> \
                and description=<one-paragraph detail>. ONLY IF the user was clearly referring to the \
                existing pending task '\(only.title)' (id: \(only.id.uuidString)) — e.g. they said \
                "yes, go ahead" — call run_task with that task_id instead. Do not assume the pending \
                task is what they meant.
                """
        }
        return """
            Missing required argument 'title' for create_task. Re-call create_task with both \
            title=<short imperative> and description=<one-paragraph detail>. If the user is \
            referring to an existing pending task, use run_task instead — call list_tasks first \
            to find it.
            """
    }

    /// Build the "missing description" tool error. Same shape as the missing-title error;
    /// same non-assertive wording and same exclusion of once-scheduled tasks.
    private static func missingDescriptionFailure(context: ToolContext, title: String) async -> String {
        let allTasks = await context.taskStore.allTasks()
        let pending = allTasks.filter {
            $0.disposition == .active && $0.scheduledRunAt == nil && (
                $0.status == .pending || $0.status == .paused || $0.status == .interrupted
            )
        }
        if pending.count == 1, let only = pending.first {
            return """
                Missing required argument 'description' for create_task (title='\(title)'). \
                If the user is describing NEW work, re-call create_task with a description. \
                ONLY IF the user was clearly referring to the existing pending task \
                '\(only.title)' (id: \(only.id.uuidString)) should you call run_task with that \
                task_id instead. Do not assume the pending task is what they meant.
                """
        }
        return "Missing required argument 'description' for create_task (title='\(title)'). Re-call with description=<one-paragraph detail of what needs to be done>."
    }
}

private extension AgentTask {
    /// Returns a copy with the supplied `scheduledRunAt` — used when assembling imperative
    /// strings for tasks that were just created (the local `task` variable from
    /// `addTask` doesn't include the scheduled time the way the persisted record does, but
    /// this is purely for display).
    func copyWithScheduledRunAt(_ date: Date) -> AgentTask {
        var copy = self
        copy.scheduledRunAt = date
        return copy
    }
}
