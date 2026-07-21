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
        Create a new task.

        Writing the parameters to pass to `create_task` is the most important job you will ever do.
        Accuracy, clarity, conciseness and completeness are absolutely paramount. Study the tool
        descriptions, including the given examples, and think through to make sure everything will
        work as expected.

        If the configured maximum task concurrency has a free worker slot, the \
        new task auto-starts immediately and the system restarts on it — you do NOT need a \
        follow-up `run_task` call. If every worker slot is occupied, the new task is queued as \
        pending; the response tells you so and you should leave it alone until a slot becomes free. \
        \
        Optional `scheduled_run_at`: an ISO-8601 timestamp at which the task should run. When \
        set, the task is created with status `scheduled` (auto-start is suppressed) and a timer is \
        auto-scheduled to fire at that time and instruct you to call `run_task`. Do NOT call \
        `schedule_task_action` separately when you've already passed `scheduled_run_at` — that \
        would double-schedule the run. Separately call `schedule_task_action` after the task is \
        created if you want to set up a RECURRING task. \
        \
        IMPORTANT — `attachment_ids`: if the user's message included ANY attachments (an image, \
        screenshot, PDF, or other file — shown to you as `[filename](file://…) … id=<UUID>` \
        markdown links), and the worker might need them to do the task, you MUST pass their EXACT \
        `id=` UUIDs in the `attachment_ids` array. The worker (Brown) does NOT see the user's \
        attachments unless you forward them here — omitting them means the worker is blind to the \
        screenshot/file the user provided. You can use the `attach_file` tool to create attachment IDs for \
        any other files you want the worker agent to use during the task. Using `attach_file` copies \
        the named files into attachment storage, so avoid using it for files that the worker agent \
        should modify in-place. If files need to be modified in place or if you need to reference an \
        entire folder, include the path of the file/folder in your `description` parameter text.
        """

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary(
            [
                "title": .dictionary([
                    "type": .string("string"),
                    "description": .string("Short title for the task.")
                ]),
                "description": .dictionary([
                    "type": .string("string"),
                    "description": .string("""

                        Detailed description of what needs to be done, based closely on the directive(s) provided by the user. This communication must be clear, concise and complete. It is the one and only embodiment of the user's intent, and as such it must be embodied perfectly. Consider including the user's text verbatim. Make sure your final description doesn't miss or misrepresent any nuance in the user's request. Pay attention not only to the user's specific words and details, but also think about what the user MOST LIKELY MEANT. The worker agent won't see ANY of your conversations with the user. Everything it needs must be detailed here.
                        Include a Capabilities Needed section at the bottom of your description, where you list bullet points of capabilities that the worker agent will likely need to complete the task. Never name a specific tool. For example, don't say "grep", say "Search for content in files". Don't say "bash", specify the specific things the agent will need to do with the shell, like "Find source code files", "Edit files", "Compile the Xcode project", etc..

                        Use the `steps` parameter to include a clear step-by-step todo list of steps the worker agent should take to complete the task.
                        Use the `acceptance_criteria` parameter to spell out what 'done' and 'complete' look like, and how to verify/validate.
                    """)
                ]),
                "scheduled_run_at": .dictionary([
                    "type": .string("string"),
                    "description": .string("Optional ISO-8601 timestamp. When set and in the future, the task is created with status `scheduled` and a paired timer fires at that time to run it. Use when the user says \"do X at <time>\". If the user wants a recurring task, consider creating this task as a template by setting the `is_template` parameter to `true`. To schedule the task on a recurring schedule, follow up with a `schedule_task_action` call after the `create_task` call completes.")
                ]),
                "attachment_ids": .dictionary([
                    "type": .string("array"),
                    "items": .dictionary(["type": .string("string")]),
                    "description": .string("UUID strings of attachments to include with this task. Use when the user attached an image, PDF, or file the worker will need. The IDs are surfaced in the user's incoming message as `[filename](file://…) … id=<UUID>` markdown links. Forward the EXACT id values verbatim. Brown will see image attachments as image content and any non-image attachments as text references with file paths.")
                ]),
                "acceptance_criteria": .dictionary(
                    [
                        "type": .string("array"),
                        "items": .dictionary(
                            [
                                "type": .string("object"),
                                "properties": .dictionary(
                                    [
                                        "name": .dictionary(
                                            [
                                                "type": .string("string"),
                                                "description": .string("""
                                                    Short display-only name. This is how the user will see this deliverable in the user interface, so this text should be meaningful to the user.

                                                    Example 1: "Verifying JSON downloaded"

                                                    Example 2: "Checking provided word is allowed"
                                                    """)
                                            ]
                                        ),
                                        "validation_prompt": .dictionary(
                                            [
                                                "type": .string(
                                                    "string"
                                                ),
                                                "description": .string(
                                                    """
                                                    Detailed instructions for the validator - what to check, how to check it, what kind \
                                                    of evidence is acceptable, what is considered a failure/rejection. This \
                                                    prompt will typically be interpreted very literally, so be sure it is clear, \
                                                    concise and complete.

                                                    Example 1: "Confirm that the worker agent ran a web search and fetched the JSON file from the website. Also confirm the JSON file exists - the agent must either have attached it or given a path to the file. If they gave a path, confirm you can read the path. If all true, ACCEPT this item. Else REJECT."

                                                    Example 2 might be used when an enumerator is provided: "Look at the provided enumeration input and confirm that the term provided exists in list of words found in the file /tmp/allowed_words.txt.  If the word is found, ACCEPT this item. If not, REJECT."

                                                    Example 3: "If the user mentioned buffalos, ACCEPT.  If the user mentioned horses, REJECT. If the user didn't mention either buffalos or horses, WAIVE this item."
                                                    """
                                                )
                                            ]
                                        ),
                                        "input_enumerator_prompt": .dictionary(
                                            [
                                                "type": .string(
                                                    "string"
                                                ),
                                                "description": .string(
                                                    """
                                                    Optional: Instructions for an LLM that MUST return a JSON array of strings. Each string is checked *independently* with the `validation_prompt`. Every item must pass for this acceptance criterion to be accepted. If any are rejected, this entire criterion is rejected.

                                                    Example 1 enumerates Java files in a particular directory/folder. The `validation_prompt` will then be applied to each file returned: "Do a directory listing of the /tmp/foo folder and return a JSON array of strings, one for each '.java' file in that folder. For each file returned, include the full path."

                                                    Example 2 instructs the LLM to return a hardcoded list: "Respond with these items in a JSON array, and nothing else - no other text, commentary, etc.: Flour, Sugar, Ham"
                                                    """
                                                )
                                            ]
                                        ),
                                        "waivable": .dictionary(
                                            [
                                                "type": .string(
                                                    "boolean"
                                                ),
                                                "description": .string(
                                                    "Whether WAIVE is permitted. Default false. Waivable items may be skipped at the discretion of the validator."
                                                )
                                            ]
                                        )
                                    ]
                                ),
                                "required": .array([.string("name"), .string("validation_prompt")])
                            ]
                        ),
                        "description": .string("""
                            Acceptance / validation criteria -- the list of deliverables -- for this task. ALL items must either \
                            pass (be accepted) or be waived for the task to be considered successful.

                            Put all validation instructions and list acceptable evidence into `validation_prompt`.

                            If the `validation_prompt` should be run on an arbitrary number of items, use the optional `input_enumerator_prompt`. The `input_enumerator_prompt` must instruct the LLM to return a JSON array of strings; each string will be validated with the `validation_prompt` independently, and every subcheck must pass. If any fail, the given criterion is rejected.

                            Write prompts so correct work passes, including edge cases and explicit alternatives. Encode user-declared MUST-FAIL gates as non-waivable criteria with no escape hatch.
                            """)
                    ]
                ),
                "steps": .dictionary([
                    "type": .string("array"),
                    "items": .dictionary(["type": .string("string")]),
                    "description": .string("""
                        Initial to-do list of steps for the worker, in order. PROVIDE THIS whenever the work has a natural sequence — it seeds the worker's plan and gives validators a record to check against. Note that these steps are guidance to the worker agent, not requirements. Once the task starts, the worker owns this to-do list and may edit, delete, re-order items as it wishes. Validators see only the *final* list.
                        """)
                ]),
                "is_template": .dictionary([
                    "type": .string("boolean"),
                    "description": .string("Make this a TEMPLATE. A template never runs itself. Each time it's started, a fresh instance is cloned (title/description/steps/criteria copied, all run-state blank) and that instance runs. Use for a task the user wants to trigger repeatedly (either manually or on a schedule) and get a clean run each time. Default `false`. When you schedule a RECURRING run on a task with `schedule_task_action`, it becomes a template automatically.")
                ]),
                "template_inputs": .dictionary([
                    "type": .string("array"),
                    "items": .dictionary([
                        "type": .string("object"),
                        "properties": .dictionary([
                            "name": .dictionary([
                                "type": .string("string"),
                                "description": .string("Stable machine-readable key. Must match ^[a-z][a-z0-9_]*$ and be unique within the template.")
                            ]),
                            "description": .dictionary([
                                "type": .string("string"),
                                "description": .string("User/agent-facing help text explaining what value to provide.")
                            ]),
                            "required": .dictionary([
                                "type": .string("boolean"),
                                "description": .string("true if this input must be provided before the template can run. Default false.")
                            ])
                        ]),
                        "required": .array([.string("name"), .string("description")])
                    ]),
                    "description": .string("""
                        Optional string-only template input definitions. Valid only when `is_template` is true. Required inputs must be supplied as `input_values` when run_task instantiates the template; non-template tasks cannot define inputs.

                        Example 1 — a localization template that needs an app name:
                        [
                          {
                            "name": "target_app",
                            "description": "App name or bundle ID to test, e.g. Localizer or com.example.Localizer.",
                            "required": true
                          },
                          {
                            "name": "locale",
                            "description": "Optional locale to test, e.g. de-DE. Leave blank to use the task's default locale guidance.",
                            "required": false
                          }
                        ]

                        Example 2 — a repeatable repository audit:
                        [
                          {
                            "name": "repository_path",
                            "description": "Absolute path to the repository to inspect.",
                            "required": true
                          }
                        ]

                        Names must match ^[a-z][a-z0-9_]*$ and must be unique. Values are strings only. Blank optional values are omitted when the template runs.
                        """)
                ])
            ]
        ),
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
        // Criteria accept the same task-scoped prompt contract as set_acceptance_criteria.
        var seedCriteria: [AcceptanceCriterion] = []
        if case .array(let rawCriteria) = arguments["acceptance_criteria"], !rawCriteria.isEmpty {
            switch CriterionArgumentParsing.parse(rawCriteria) {
            case .success(let parsed):
                seedCriteria = parsed.map {
                    AcceptanceCriterion(name: $0.name, validationPrompt: $0.validationPrompt, inputEnumeratorPrompt: $0.inputEnumeratorPrompt, waivable: $0.waivable, origin: .smith)
                }
            case .failure(let problem):
                return .failure("Task NOT created — the acceptance_criteria are invalid: \(problem.message) Fix them and call create_task again.")
            }
        }

        var isTemplate = false
        if case .bool(let flag) = arguments["is_template"] { isTemplate = flag }
        let templateInputDefinitions: [TemplateInputDefinition]
        if case .array(let rawTemplateInputs) = arguments["template_inputs"] {
            guard isTemplate else {
                return .failure("template_inputs are valid only when is_template is true. Ordinary non-template tasks cannot define template inputs.")
            }
            switch Self.parseTemplateInputDefinitions(rawTemplateInputs) {
            case .success(let definitions):
                templateInputDefinitions = definitions
            case .failure(let message):
                return .failure("Task NOT created — template_inputs are invalid: \(message)")
            }
        } else {
            templateInputDefinitions = []
        }
        if scheduledRunAt != nil && templateInputDefinitions.contains(where: \.required) {
            return .failure("Task NOT created — scheduled_run_at cannot be used with required template_inputs yet because scheduled template runs do not carry input_values. Create the template without scheduled_run_at, then run it manually with input_values.")
        }

        let task = await context.taskStore.addTask(
            title: title,
            description: description,
            scheduledRunAt: scheduledRunAt,
            descriptionAttachments: resolvedAttachments,
            isTemplate: isTemplate,
            templateInputDefinitions: templateInputDefinitions
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
            let inputNote = templateInputDefinitions.isEmpty
                ? ""
                : " Template inputs: \(templateInputDefinitions.map(\.name).joined(separator: ", "))."
            return .success("Template task created (ID: \(task.id), title: \"\(title)\").\(contextNote)\(inputNote) It won't run on its own — starting it (run_task, the play button, or a scheduled run) clones a fresh instance each time.")
        }

        // Auto-start the new task when a worker slot is free. Prevents the failure mode
        // where Smith creates a task and then idles instead of immediately calling
        // run_task. Beyond capacity the task queues as pending — auto-run starts it when
        // a slot frees; Smith must NOT poll run_task for it.
        let capacity = await context.workerCapacity()
        let slotHolders = existingTasks.filter { other in
            other.id != task.id &&
            other.disposition == .active &&
            (other.status == .starting || other.status == .running || other.status == .awaitingReview || other.status == .validating)
        }
        if slotHolders.count < capacity {
            await context.restartForNewTask(task.id, nil)
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

    private enum TemplateInputParseResult {
        case success([TemplateInputDefinition])
        case failure(String)
    }

    private static func parseTemplateInputDefinitions(_ rawInputs: [AnyCodable]) -> TemplateInputParseResult {
        var definitions: [TemplateInputDefinition] = []
        for raw in rawInputs {
            guard case .dictionary(let fields) = raw else {
                return .failure("Every template input must be an object with required 'name' and 'description' fields.")
            }
            guard case .string(let rawName) = fields["name"] else {
                return .failure("Every template input requires a string 'name'.")
            }
            guard case .string(let rawDescription) = fields["description"] else {
                return .failure("Template input '\(rawName)' requires a string 'description'.")
            }
            let required: Bool
            if case .bool(let value) = fields["required"] {
                required = value
            } else {
                required = false
            }
            definitions.append(TemplateInputDefinition(name: rawName, description: rawDescription, required: required))
        }
        if let problem = TemplateInputValidation.validateDefinitions(definitions) {
            return .failure(problem)
        }
        return .success(definitions)
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
