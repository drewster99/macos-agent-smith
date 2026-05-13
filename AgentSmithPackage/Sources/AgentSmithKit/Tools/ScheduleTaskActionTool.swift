import Foundation

/// Smith tool: schedules a future timer that will tell Smith to perform a specific action on
/// an existing task at the scheduled time. The action is *not* auto-executed — instead, the
/// timer fires with a pre-rendered imperative ("Call run_task on <id> to start the task")
/// that Smith reads and executes via the matching tool. This keeps Jones in the loop on
/// every actual side effect without duplicating its evaluation surface for timer-driven
/// actions.
///
/// Use this whenever the user says "do X to task Y at time T" — e.g. "run task <id> at 9pm",
/// "stop the build task in 30 minutes", "summarize the migration task tomorrow morning."
struct ScheduleTaskActionTool: AgentTool {
    let name = "schedule_task_action"
    let toolDescription = """
        Schedule a future imperative to perform an action on an existing task. When the timer \
        fires you'll receive instructions like "Call run_task on <id>" — execute them. \
        \
        Required: `task_id` (UUID of an existing task), `action`, and either `delay_seconds` \
        OR `at_time` (ISO-8601). \
        \
        `action` must be one of: \
          • run        — start/resume/restart the task (calls run_task at fire time) \
          • pause      — flip the task to paused (calls update_task) \
          • stop       — flip the task to interrupted (calls update_task) \
          • summarize  — describe progress to the user (call list_tasks + message_user) \
        \
        Optional: `extra_instructions` — additional context appended to the auto-rendered \
        imperative (e.g. "and tell Drew it's done"). `recurrence` for repeating actions. \
        `replaces_id` to overwrite an existing scheduled action. \
        \
        For recurring actions, pass `recurrence` as one of: \
          • {"type":"interval","minutes":30}  (also accepts `seconds` and/or `hours`; min total 60s) \
          • {"type":"daily","hour":21,"minute":0} \
          • {"type":"weekly","hour":15,"minute":0,"on":["mon","wed","fri"]} \
          • {"type":"monthly","hour":9,"minute":0,"day_of_month":1} \
        \
        The wake is auto-cancelled if the task transitions to a terminal status (completed/failed) \
        before the timer fires. For action=run on a recurring schedule, the wake survives the run \
        because each occurrence reopens the task before running it.
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
                    .string("stop"),
                    .string("summarize")
                ]),
                "description": .string("Action to perform when the timer fires. Required.")
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
                "description": .string("Optional additional context appended to the auto-rendered imperative.")
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
              let action = TaskActionKind(rawValue: actionRaw.lowercased()) else {
            return .failure("action is required and must be one of: run, pause, stop, summarize.")
        }
        guard let task = await context.taskStore.task(id: taskID) else {
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

        let imperative = action.imperativeText(for: task, extra: extra)
        let outcome = await context.scheduleWake(
            wakeAt,
            imperative,
            taskID,
            replacesID,
            recurrenceResult.value,
            action.survivesTaskTermination
        )
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
                    "messageKind": .string("task_action_scheduled"),
                    "actionKind": .string(action.rawValue),
                    "taskID": .string(task.id.uuidString),
                    "taskTitle": .string(task.title),
                    "scheduledRunAt": .double(wakeAt.timeIntervalSince1970),
                    "wakeID": .string(wake.id.uuidString)
                ]
            ))
        }
        return TimerArgumentParsing.formatScheduleOutcome(outcome, kind: "Scheduled task action")
    }
}

/// Action variants understood by `schedule_task_action`. Each variant knows how to render
/// itself as an imperative ("Call run_task on <id>...") so the wake fires with a clear
/// directive rather than a vague memo.
public enum TaskActionKind: String, Sendable, Codable {
    case run, pause, stop, summarize

    /// Headline shown in the channel-log banner that announces a `schedule_task_action` —
    /// pairs with `bannerSymbolName` and `bannerLabel` for the four user-visible variants.
    /// `run` returns the same headline as the others for consistency, even though the
    /// matched task is usually announced via the New Task banner from `create_task`.
    func bannerHeadline(for task: AgentTask) -> String {
        task.title
    }

    /// Action label for the banner ("Pause", "Stop", "Summarize", "Run").
    public var bannerLabel: String {
        switch self {
        case .run: return "Run"
        case .pause: return "Pause"
        case .stop: return "Stop"
        case .summarize: return "Summarize"
        }
    }

    /// Whether this action's wake should survive the linked task's first termination. True
    /// for actions whose explicit purpose is to act on a task whose previous run is already
    /// done — `run` (rerun the task) and `summarize` (often scheduled *after* the task has
    /// finished). False for `pause` / `stop` since neither is meaningful once the task has
    /// terminated.
    public var survivesTaskTermination: Bool {
        switch self {
        case .run, .summarize: return true
        case .pause, .stop: return false
        }
    }

    /// SF Symbol used in the action banner.
    public var bannerSymbolName: String {
        switch self {
        case .run: return "play.circle.fill"
        case .pause: return "pause.circle.fill"
        case .stop: return "stop.circle.fill"
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
        case .stop:
            return "Call `update_task` on \(task.id.uuidString) with status `interrupted` to stop the task \"\(task.title)\"." + suffix
        case .summarize:
            return "Call `list_tasks` to refresh state, then `message_user` with a brief summary of progress on the task \"\(task.title)\" (id \(task.id.uuidString))." + suffix
        }
    }
}
