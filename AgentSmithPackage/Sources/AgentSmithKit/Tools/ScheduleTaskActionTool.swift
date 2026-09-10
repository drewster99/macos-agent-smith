import Foundation

/// Smith tool: schedules a future timer that performs a specific action on an existing task.
///
/// **How a fired schedule dispatches.** `run` is executed MECHANICALLY by the runtime — the wake
/// produces a `task_action` notification addressed to `.runtime`, which starts (or durably queues)
/// the task without an LLM turn. `pause` and `interrupt` are mechanical too. Only `summarize`
/// routes to Smith, since it is the one action that needs judgment. The `instructions` text on the
/// wake ("Call `run_task` on <id>…") is what the TIMER UI and the transcript show; it is not what
/// dispatch reads — that is the wake's structured `action`.
///
/// This is worth stating because the doc here used to say the opposite (that Smith reads the
/// imperative and calls the matching tool), long after the mechanical path replaced it. That gap is
/// how `run` came to be dispatched down a path with a STRICTER status gate than the `run_task` its
/// own text names, silently discarding scheduled retries of failed tasks. Both now ask
/// `TaskStore.prepareForRun`.
///
/// Security review is not bypassed: the mechanical path spawns a worker, and every tool call that
/// worker then makes routes through the Security Agent as usual.
///
/// Use this whenever the user says "do X to task Y at time T" — e.g. "run task <id> at 9pm",
/// "stop the build task in 30 minutes", "summarize the migration task tomorrow morning."
struct ScheduleTaskActionTool: AgentTool {
    let name = "schedule_task_action"
    let toolDescription = """
        Schedule a future action on an existing task. run/pause/interrupt are performed \
        automatically by the system when the timer fires — you are NOT asked to execute them and \
        must not schedule a duplicate. Only `summarize` comes back to you to carry out. \
        \
        Required: `task_id` (UUID of an existing task), `action`, and either `delay_seconds` \
        OR `at_time` (ISO-8601). \
        \
        `action` must be one of: \
          • run        — start/resume/restart the task (performed automatically) \
          • pause      — flip the task to paused (performed automatically) \
          • interrupt  — flip the task to interrupted (performed automatically) \
          • summarize  — comes back to YOU: get_task_details, then message_user with progress \
        \
        Optional: `extra_instructions` — refinements for that run (e.g. "use Safari only"), \
        applied to the task when it starts. `recurrence` for repeating actions. \
        `replaces_id` to overwrite an existing scheduled action. \
        \
        For recurring actions, pass `recurrence` as one of: \
          • {"type":"interval","minutes":30}  (also accepts `seconds` and/or `hours`; min total 60s) \
          • {"type":"daily","hour":21,"minute":0} \
          • {"type":"weekly","hour":15,"minute":0,"on":["mon","wed","fri"]} \
          • {"type":"monthly","hour":9,"minute":0,"day_of_month":1} \
        \
        For action=run, a failed task is auto-reset and a completed one reopened at fire time, \
        exactly as run_task does — so scheduling a retry of a failed task works. If the task is in \
        some other unstartable status when the timer fires (still running, awaiting help), the run \
        does NOT happen: you are told, and nothing retries it. For action=run on a recurring \
        schedule, the wake survives the run because each occurrence reopens the task before running it.
        """

    private static let minDelaySeconds: Double = 5
    private static let maxDelaySeconds: Double = 365 * 24 * 60 * 60

    let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "task_id": .dictionary([
                "type": .string("string"),
                "description": .string("UUID of the existing task this action targets. Required.")
            ]),
            "action": .dictionary([
                "type": .string("string"),
                "enum": .array([
                    .string("run"),
                    .string("pause"),
                    .string("interrupt"),
                    .string("summarize")
                ]),
                "description": .string("Action to perform when the timer fires. run/pause/interrupt happen automatically; summarize returns to you. Required.")
            ]),
            "delay_seconds": .dictionary([
                "type": .string("number"),
                "description": .string("Seconds from now to fire (5–31_536_000). Either delay_seconds OR at_time is required.")
            ]),
            "at_time": .dictionary([
                "type": .string("string"),
                "description": .string("Absolute ISO-8601 timestamp to fire at. Either delay_seconds OR at_time is required.")
            ]),
            "extra_instructions": .dictionary([
                "type": .string("string"),
                "description": .string("Optional refinements for this run (e.g. 'use Safari only'), applied to the task when it starts.")
            ]),
            "recurrence": .dictionary([
                "type": .string("object"),
                "description": .string("Optional recurrence pattern. See tool description for shape.")
            ]),
            "replaces_id": .dictionary([
                "type": .string("string"),
                "description": .string("Optional UUID of an existing scheduled action to overwrite.")
            ])
        ]),
        "required": .array([.string("task_id"), .string("action")])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .smith
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard case .string(let taskIDString) = arguments["task_id"],
              let taskID = UUID(uuidString: taskIDString) else {
            return .failure("task_id is required and must be a valid UUID.")
        }
        guard case .string(let actionRaw) = arguments["action"],
              let action = TaskActionKind(lenient: actionRaw) else {
            return .failure("action is required and must be one of: run, pause, interrupt, summarize.")
        }
        // Library-aware: scheduling a RECURRING run promotes the task to a template, and promotion
        // moves it into the global library — so the per-session lookup stops finding the very task
        // this tool just created a schedule for. Without this, a follow-up call (changing the
        // recurrence, or `replaces_id`) answered "not found" and a recurring schedule could never
        // be edited after it was made.
        guard let task = await context.taskStore.taskOrLibraryTemplate(id: taskID) else {
            return .failure("Task \(taskID.uuidString) not found.")
        }

        let now = Date()
        let wakeAtResult = TimerArgumentParsing.resolveFireTime(
            arguments: arguments,
            now: now,
            minDelaySeconds: Self.minDelaySeconds,
            maxDelaySeconds: Self.maxDelaySeconds
        )
        let wakeAt: Date
        switch wakeAtResult {
        case .success(let date): wakeAt = date
        case .failure(let message): return .failure(message)
        }
        var replacesID: UUID?
        if case .string(let rid) = arguments["replaces_id"] {
            guard let parsed = UUID(uuidString: rid) else {
                return .failure("Invalid replaces_id: '\(rid)' is not a valid UUID.")
            }
            replacesID = parsed
        }
        let recurrenceResult = TimerArgumentParsing.parseRecurrence(arguments["recurrence"])
        if case .invalid(let message) = recurrenceResult {
            return .failure("Invalid recurrence: \(message)")
        }
        var extra: String?
        if case .string(let value) = arguments["extra_instructions"] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            extra = trimmed.isEmpty ? nil : trimmed
        }

        // A RECURRING run defaults the task to a TEMPLATE — the user wants a fresh
        // instance on each firing, not the same record re-run in place (which would
        // pile prior results into one task). Smith can toggle it off via update_task if
        // they specifically want in-place updates instead.
        if action == .run, recurrenceResult.value != nil, !task.isTemplate {
            if let problem = await context.taskStore.setTemplate(id: taskID, isTemplate: true) {
                return .failure("Cannot schedule recurring runs for this task: \(problem)")
            }
        }

        if action == .run, recurrenceResult.value != nil, replacesID == nil {
            let existingRecurringRuns = await context.listScheduledWakes()
                .filter { wake in
                    wake.taskID == taskID
                        && wake.recurrence != nil
                        && wake.action == .run
                }
                .sorted { $0.wakeAt < $1.wakeAt }
            replacesID = existingRecurringRuns.first?.id
            for wake in existingRecurringRuns.dropFirst() {
                _ = await context.cancelScheduledWake(wake.id)
            }
        }

        let imperative = action.imperativeText(for: task, extra: extra)
        let outcome = await context.scheduleWake(WakeRequest(
            wakeAt: wakeAt,
            instructions: imperative,
            taskID: taskID,
            replacesID: replacesID,
            recurrence: recurrenceResult.value,
            survivesTaskTermination: action.survivesTaskTermination,
            action: action,
            extraInstructions: extra
        ))
        // Surface the schedule as a dedicated channel banner so the user sees a task-style
        // row ("Pause", "Stop", "Summarize" — each with its own icon) instead of the
        // generic `System ⏰ scheduled …` line. The paired timer_activity row gets
        // suppressed in the channel log dispatch when this banner is present for the
        // same taskID.
        if case .scheduled(let wake) = outcome {
            await context.post(ChannelMessage(
                sender: .system,
                content: action.bannerHeadline(for: task),
                metadata: [
                    "messageKind": .kind(.taskActionScheduled),
                    "actionKind": .string(action.rawValue),
                    "taskID": .string(task.id.uuidString),
                    "taskTitle": .string(task.title),
                    "scheduledRunAt": .double(wakeAt.timeIntervalSince1970),
                    "wakeID": .string(wake.id.uuidString)
                ]
            ))
        }
        let result = TimerArgumentParsing.formatScheduleOutcome(outcome, kind: "Scheduled task action")
        // Re-read (library-aware) rather than reusing the `task` captured at the top: a recurring
        // run PROMOTES the task to a template above, and promotion moves it into the global library
        // — so the local copy is stale about both `isTemplate` and which store now owns it.
        let current = await context.taskStore.taskOrLibraryTemplate(id: taskID) ?? task
        guard case .scheduled = outcome, let advisory = Self.startabilityAdvisory(for: action, task: current) else {
            return result
        }
        return .success("\(result.output)\n\n\(advisory)")
    }

    /// A warning, when a `run` is scheduled against a task whose CURRENT status the fire-time path
    /// would not accept.
    ///
    /// Deliberately a warning and not a refusal: nearly every unstartable status is transient, and
    /// the normal case is precisely that it resolves before the timer fires — a `.running` task is
    /// usually `.completed` or `.failed` by then, and both of those ARE startable. Refusing here
    /// would block the most ordinary use of this tool ("retry that when the current run finishes").
    /// What the caller needs is to know the task isn't startable *right now*, so a schedule aimed at
    /// a task that will still be stuck reads as a mistake at the time it's made.
    ///
    /// `.scheduled` is not flagged: a run wake promotes a `.scheduled` task to `.pending` before
    /// dispatching it (`WakeScheduler.fireDue`), so it starts fine.
    private static func startabilityAdvisory(for action: TaskActionKind, task: AgentTask) -> String? {
        guard action == .run, !task.isTemplate else { return nil }
        guard !task.status.canBeStarted, task.status != .scheduled else { return nil }
        return """
            NOTE: '\(task.title)' is currently '\(task.status.rawValue)', which cannot be started. \
            That is usually fine — an in-flight task normally reaches completed or failed (both \
            startable) before the timer fires. But if it is still '\(task.status.rawValue)' at fire \
            time, the run will NOT start; you'll be told, and nothing will retry it.
            """
    }
}

/// Action variants understood by `schedule_task_action`. Each variant knows how to render
/// itself as an imperative ("Call run_task on <id>...") so the wake fires with a clear
/// directive rather than a vague memo.
public enum TaskActionKind: String, Sendable, Codable {
    case run, pause, interrupt, summarize

    /// Parses an action string leniently: the legacy value `"stop"` maps to `.interrupt` (the
    /// action was renamed to match the status it actually sets). Nil for anything unrecognized.
    public init?(lenient raw: String) {
        let lowered = raw.lowercased()
        if lowered == "stop" { self = .interrupt; return }
        guard let parsed = TaskActionKind(rawValue: lowered) else { return nil }
        self = parsed
    }

    /// Headline shown in the channel-log banner that announces a `schedule_task_action` —
    /// pairs with `bannerSymbolName` and `bannerLabel` for the four user-visible variants.
    /// `run` returns the same headline as the others for consistency, even though the
    /// matched task is usually announced via the New Task banner from `create_task`.
    func bannerHeadline(for task: AgentTask) -> String {
        task.title
    }

    /// Action label for the banner ("Pause", "Interrupt", "Summarize", "Run").
    public var bannerLabel: String {
        switch self {
        case .run: return "Run"
        case .pause: return "Pause"
        case .interrupt: return "Interrupt"
        case .summarize: return "Summarize"
        }
    }

    /// Whether this action's wake should survive the linked task's first termination. True
    /// for actions whose explicit purpose is to act on a task whose previous run is already
    /// done — `run` (rerun the task) and `summarize` (often scheduled *after* the task has
    /// finished). False for `pause` / `interrupt` since neither is meaningful once the task has
    /// terminated.
    public var survivesTaskTermination: Bool {
        switch self {
        case .run, .summarize: return true
        case .pause, .interrupt: return false
        }
    }

    /// SF Symbol used in the action banner.
    public var bannerSymbolName: String {
        switch self {
        case .run: return "play.circle.fill"
        case .pause: return "pause.circle.fill"
        case .interrupt: return "stop.circle.fill"
        case .summarize: return "doc.text.magnifyingglass"
        }
    }

    func imperativeText(for task: AgentTask, extra: String?) -> String {
        let suffix = extra.map { " " + $0 } ?? ""
        switch self {
        case .run:
            return "Call `run_task` on \(task.id.uuidString) to start the task \"\(task.title)\"." + suffix
        case .pause:
            return "Call `update_task` on \(task.id.uuidString) with status `paused` to pause the task \"\(task.title)\"." + suffix
        case .interrupt:
            return "Call `update_task` on \(task.id.uuidString) with status `interrupted` to stop the task \"\(task.title)\"." + suffix
        case .summarize:
            // `get_task_details`, not `list_tasks`: list_tasks now returns truncated summary
            // previews (no result/updates/commentary) and may not even include this task, so it
            // can't back a progress summary. get_task_details fetches the full record by id.
            return "Call `get_task_details` for \(task.id.uuidString), then `message_user` with a brief summary of progress on the task \"\(task.title)\"." + suffix
        }
    }
}
