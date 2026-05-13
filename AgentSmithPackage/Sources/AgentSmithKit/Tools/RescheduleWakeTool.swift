import Foundation

/// Smith tool: reschedules a single existing wake to a new fire time. Preserves the wake's
/// instructions and task linkage; only the fire time (and optionally the recurrence) changes.
/// Internally uses `scheduleWake` with `replacesID`, so the timer-event log records a single
/// `.cancelled(replaced)` + `.scheduled` pair the transcript renders as `rescheduled` —
/// instead of an unrelated-looking cancel and a new schedule.
struct RescheduleWakeTool: AgentTool {
    let name = "reschedule_wake"
    let toolDescription = """
        Reschedule an existing wake to a new fire time. Preserves the wake's instructions and \
        any task linkage. Use this whenever the user asks to move/postpone/bring-forward a \
        scheduled task action — do NOT call `cancel_wake` followed by `schedule_task_action`, \
        that creates two unrelated transcript lines and is harder for the user to follow. \
        \
        Required: `wake_id` and either `delay_seconds` OR `at_time` (ISO-8601). \
        Optional: `recurrence` to update the repeat pattern (omit to keep the existing one; \
        pass `{"type":"none"}` to clear an existing recurrence and make it one-shot). \
        \
        Use `list_scheduled_wakes` to find the wake's id.
        """

    private static let minDelaySeconds: Double = 5
    private static let maxDelaySeconds: Double = 365 * 24 * 60 * 60

    let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "wake_id": .dictionary([
                "type": .string("string"),
                "description": .string("UUID of the existing wake to reschedule. Required.")
            ]),
            "delay_seconds": .dictionary([
                "type": .string("number"),
                "description": .string("Seconds from now for the new fire time (5–31_536_000). Either delay_seconds OR at_time is required.")
            ]),
            "at_time": .dictionary([
                "type": .string("string"),
                "description": .string("Absolute ISO-8601 timestamp for the new fire time. Either delay_seconds OR at_time is required.")
            ]),
            "recurrence": .dictionary([
                "type": .string("object"),
                "description": .string("Optional new recurrence pattern. Omit to keep existing; pass {\"type\":\"none\"} to clear.")
            ])
        ]),
        "required": .array([.string("wake_id")])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .smith
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard case .string(let idString) = arguments["wake_id"] else {
            throw ToolCallError.missingRequiredArgument("wake_id")
        }
        guard let wakeID = UUID(uuidString: idString) else {
            return .failure("Invalid wake_id: '\(idString)' is not a valid UUID.")
        }
        let existing = await context.listScheduledWakes().first { $0.id == wakeID }
        guard let existing else {
            return .failure("No wake found with id \(wakeID.uuidString). Use list_scheduled_wakes to see current ids.")
        }

        let now = Date()
        let fireTimeResult = TimerArgumentParsing.resolveFireTime(
            arguments: arguments,
            now: now,
            minDelaySeconds: Self.minDelaySeconds,
            maxDelaySeconds: Self.maxDelaySeconds
        )
        let newFireTime: Date
        switch fireTimeResult {
        case .success(let date): newFireTime = date
        case .failure(let message): return .failure(message)
        }

        // Recurrence handling: omitted → keep existing; {"type":"none"} → clear; otherwise parse.
        let newRecurrence: Recurrence?
        if let raw = arguments["recurrence"] {
            if case .dictionary(let dict) = raw,
               case .string(let typeRaw) = dict["type"],
               typeRaw.lowercased() == "none" {
                newRecurrence = nil
            } else {
                let parsed = TimerArgumentParsing.parseRecurrence(raw)
                if case .invalid(let message) = parsed {
                    return .failure("Invalid recurrence: \(message)")
                }
                newRecurrence = parsed.value
            }
        } else {
            newRecurrence = existing.recurrence
        }

        let outcome = await context.scheduleWake(
            newFireTime,
            existing.instructions,
            existing.taskID,
            existing.id,
            newRecurrence,
            existing.survivesTaskTermination
        )
        return TimerArgumentParsing.formatScheduleOutcome(outcome, kind: "Rescheduled wake")
    }
}
