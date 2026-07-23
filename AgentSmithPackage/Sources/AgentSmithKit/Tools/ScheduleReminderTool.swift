import Foundation

/// Smith tool: schedules a future timer that delivers an imperative directive to Smith when
/// it fires. Use for non-task reminders ("remind me to take a shower", "ping me to check on
/// X at 3pm"). Optional `recurrence` makes it fire repeatedly (daily, weekly on a set of
/// weekdays, monthly on a specific day-of-month, or a fixed interval).
///
/// For timers that act on an existing task (start it, pause it, etc.), use
/// `schedule_task_action` — it's a different tool with a more constrained shape so the
/// instructions can't go vague.
///
/// The wake this creates carries no `taskID`, which is exactly what distinguishes it: it is
/// never a candidate for mechanical dispatch, so it always arrives as text for Smith to act on,
/// and task-termination cleanup never touches it.
public struct ScheduleReminderTool: AgentTool {
    public let name = "schedule_reminder"
    public let toolDescription = """
        Schedule a future reminder. When the timer fires, you'll receive a `[System: ...]` \
        message containing the `instructions` text — execute them. Use this for user-driven \
        reminders that don't directly act on an existing task ("remind me to take a shower in \
        90 minutes", "tell me to brush my teeth every day at 9pm"). For timers that should \
        run/pause/stop a task you already created, use `schedule_task_action` instead. \
        \
        Required: `instructions` (imperative directive — NOT a memo) and either `delay_seconds` \
        OR `at_time` (ISO-8601). \
        Optional: `recurrence` for repeating reminders. `replaces_id` to overwrite an existing \
        reminder. \
        \
        IMPORTANT: `instructions` must be a direct imperative to yourself describing the EXACT \
        action(s) to perform when the timer fires — NOT a memo, NOT a summary of why you set it. \
        Examples: \
          • GOOD: "Tell Drew his shower reminder is up via message_user." \
          • GOOD: "Run list_tasks and report any still-pending items to Drew." \
          • BAD:  "Reminder for shower." (no verb, no actor, no action) \
          • BAD:  "Time to send email." (a memo, not an action) \
        \
        For recurring reminders, pass `recurrence` as one of: \
          • {"type":"interval","minutes":30}  (also accepts `seconds` and/or `hours`; min total 60s) \
          • {"type":"daily","hour":21,"minute":0} \
          • {"type":"weekly","hour":15,"minute":0,"on":["mon","wed","fri"]} \
          • {"type":"monthly","hour":9,"minute":0,"day_of_month":1} \
        Recurring reminders auto-schedule the next occurrence after each fire — you do NOT need \
        to call `schedule_reminder` again. Use `list_scheduled_wakes` to see them and \
        `cancel_wake` to stop one.
        """

    private static let minDelaySeconds: Double = 5
    private static let maxDelaySeconds: Double = 365 * 24 * 60 * 60

    public let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "delay_seconds": .dictionary([
                "type": .string("number"),
                "description": .string("Seconds from now to fire (5–31536000). Either delay_seconds OR at_time is required.")
            ]),
            "at_time": .dictionary([
                "type": .string("string"),
                "description": .string("Absolute ISO-8601 timestamp to fire at. Either delay_seconds OR at_time is required.")
            ]),
            "instructions": .dictionary([
                "type": .string("string"),
                "description": .string("Imperative directive surfaced verbatim when the timer fires. Required.")
            ]),
            "recurrence": .dictionary([
                "type": .string("object"),
                "description": .string("Optional recurrence pattern. See tool description for shape. When set, the timer auto-schedules the next occurrence after each fire.")
            ]),
            "replaces_id": .dictionary([
                "type": .string("string"),
                "description": .string("Optional UUID of an existing reminder to overwrite.")
            ])
        ]),
        "required": .array([.string("instructions")])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .smith
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard case .string(let instructions) = arguments["instructions"] else {
            throw ToolCallError.missingRequiredArgument("instructions")
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
        if case .string(let rawReplacesID) = arguments["replaces_id"] {
            guard let parsed = UUID(uuidString: rawReplacesID) else {
                return .failure("Invalid replaces_id: '\(rawReplacesID)' is not a valid UUID.")
            }
            replacesID = parsed
        }

        let recurrence = TimerArgumentParsing.parseRecurrence(arguments["recurrence"])
        if case .invalid(let message) = recurrence {
            return .failure("Invalid recurrence: \(message)")
        }

        // No taskID, and `survivesTaskTermination` is meaningless without one — a reminder is
        // never cancelled by task cleanup because that only targets wakes naming a task.
        let outcome = await context.scheduleWake(wakeAt, instructions, nil, replacesID, recurrence.value, false)
        return TimerArgumentParsing.formatScheduleOutcome(outcome, kind: "Reminder")
    }
}
