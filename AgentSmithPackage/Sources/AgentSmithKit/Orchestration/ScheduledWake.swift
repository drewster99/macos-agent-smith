import Foundation

/// A scheduled wake-up registered with an `AgentActor`. When `wakeAt` arrives, the actor
/// injects a `[System: ...]` user-role message containing the `instructions` into its
/// conversation and runs an LLM turn so the agent executes them.
///
/// When `recurrence` is non-nil, the runtime auto-schedules the next occurrence (with a fresh
/// id) immediately after firing, using `Recurrence.nextOccurrence(after:)`. The wake's
/// `originalID` is preserved across the recurrence chain so the timers UI can group fires.
public struct ScheduledWake: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    public var wakeAt: Date
    /// Imperative instructions the agent should execute when the wake fires. Written as a
    /// direct directive to the agent (e.g. "Call run_task on 07EA…", "Tell Drew his shower
    /// reminder is up"), surfaced verbatim in the wake's system message. Decoded from the
    /// pre-rename `reason` field for backward compatibility with persisted state.
    public var instructions: String
    /// Optional task association. When set, the wake is auto-cancelled when the task
    /// transitions to a terminal status (completed/failed) — see
    /// `OrchestrationRuntime.installTaskTerminationCleanup` — UNLESS
    /// `survivesTaskTermination` is set.
    public var taskID: UUID?
    /// Optional recurrence pattern. When non-nil, the runtime schedules the next occurrence
    /// after this one fires.
    public var recurrence: Recurrence?
    /// The id of the very first wake in a recurring chain. For one-shot wakes this equals
    /// `id`. For each subsequent recurrence the new wake has a fresh `id` but inherits the
    /// chain's `originalID` so the timers UI can group fires together.
    public var originalID: UUID
    /// Set when this wake was created by the runtime as the next link in a recurring chain.
    public var previousFireAt: Date?
    /// When true, this wake is preserved across `cancelWakesForTask` calls — used for
    /// `run` / `summarize` actions whose intent is precisely to act on
    /// a task whose previous run has already terminated. Without this flag, scheduling
    /// multiple `run_task` wakes against the same task wipes all-but-the-first wake the
    /// moment the first run completes.
    public var survivesTaskTermination: Bool

    /// The structured task action this wake performs, when it came from a task-action schedule.
    /// This is the SINGLE source of "what does this wake do" — consumers branch on it and NEVER
    /// on `instructions`, which is human-facing prose free to change. Nil for a bare reminder (no
    /// task action) and for a wake persisted before this field existed whose prose isn't run-shaped.
    public var action: TaskActionKind?

    public init(
        id: UUID = UUID(),
        wakeAt: Date,
        instructions: String,
        taskID: UUID? = nil,
        recurrence: Recurrence? = nil,
        originalID: UUID? = nil,
        previousFireAt: Date? = nil,
        survivesTaskTermination: Bool = false,
        action: TaskActionKind? = nil
    ) {
        self.id = id
        self.wakeAt = wakeAt
        self.instructions = instructions
        self.taskID = taskID
        self.recurrence = recurrence
        self.originalID = originalID ?? id
        self.previousFireAt = previousFireAt
        self.survivesTaskTermination = survivesTaskTermination
        self.action = action
    }

    private enum CodingKeys: String, CodingKey {
        case id, wakeAt, instructions, taskID, recurrence, originalID, previousFireAt
        case survivesTaskTermination, action, structuredDispatch
        case legacyReason = "reason"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(UUID.self, forKey: .id)
        self.id = id
        self.wakeAt = try c.decode(Date.self, forKey: .wakeAt)
        self.taskID = try c.decodeIfPresent(UUID.self, forKey: .taskID)
        if let instructions = try c.decodeIfPresent(String.self, forKey: .instructions) {
            self.instructions = instructions
        } else {
            self.instructions = try c.decode(String.self, forKey: .legacyReason)
        }
        self.recurrence = try c.decodeIfPresent(Recurrence.self, forKey: .recurrence)
        self.originalID = try c.decodeIfPresent(UUID.self, forKey: .originalID) ?? id
        self.previousFireAt = try c.decodeIfPresent(Date.self, forKey: .previousFireAt)
        let survivesWasPersisted = c.contains(.survivesTaskTermination)
        self.survivesTaskTermination = try c.decodeIfPresent(Bool.self, forKey: .survivesTaskTermination) ?? false

        // `structuredDispatch` is written true by every post-migration wake, so its ABSENCE means
        // exactly one thing: a wake persisted before `action` existed. That makes the legacy prose
        // inference a one-time migration, never a permanent matcher — a NEW reminder whose prose
        // happens to be run-shaped keeps its real `action` (nil), because it IS marked structured.
        let isStructured = try c.decodeIfPresent(Bool.self, forKey: .structuredDispatch) ?? false
        if isStructured {
            if let raw = try c.decodeIfPresent(String.self, forKey: .action) {
                self.action = TaskActionKind(lenient: raw)
            } else {
                self.action = nil
            }
        } else {
            let legacy = Self.legacyActionFromInstructions(self.instructions)
            self.action = legacy
            // A record predating BOTH fields decodes `survivesTaskTermination = false`, but a
            // recovered `.run` wake must survive task termination (that's what run wakes do — a
            // recurring run's series would otherwise be cancelled when its first run completes).
            // Heal it only when the key was genuinely absent, so an explicit persisted `false`
            // (a real, if unusual, choice) is respected.
            if legacy == .run, !survivesWasPersisted {
                self.survivesTaskTermination = TaskActionKind.run.survivesTaskTermination
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(wakeAt, forKey: .wakeAt)
        try c.encode(instructions, forKey: .instructions)
        try c.encodeIfPresent(taskID, forKey: .taskID)
        try c.encodeIfPresent(recurrence, forKey: .recurrence)
        if originalID != id {
            try c.encode(originalID, forKey: .originalID)
        }
        try c.encodeIfPresent(previousFireAt, forKey: .previousFireAt)
        if survivesTaskTermination {
            try c.encode(true, forKey: .survivesTaskTermination)
        }
        // Always stamp the marker so an absent key unambiguously flags a pre-migration record.
        try c.encode(true, forKey: .structuredDispatch)
        try c.encodeIfPresent(action, forKey: .action)
    }

    /// Recovers `action` for a wake persisted before the field existed. A FROZEN literal,
    /// deliberately NOT derived from `TaskActionKind.run.imperativeText` — it reads what OLD builds
    /// wrote (which never changes), so today's wording is free to evolve without breaking it. Only
    /// `run` is recovered: it's the only action any branch drives mechanically; legacy
    /// pause/interrupt/summarize decode to nil and route through Smith, which is safe.
    private static func legacyActionFromInstructions(_ instructions: String) -> TaskActionKind? {
        instructions.hasPrefix("Call `run_task` on ") ? .run : nil
    }
}

/// A labeled request to schedule a wake, passed through the `ToolContext.scheduleWake` closure.
/// Replaces what would otherwise be a 7-positional-argument closure — the mostly-optional fields
/// are unreadable positionally and the `action` addition tipped it over.
public struct WakeRequest: Sendable {
    public var wakeAt: Date
    public var instructions: String
    public var taskID: UUID?
    public var replacesID: UUID?
    public var recurrence: Recurrence?
    public var survivesTaskTermination: Bool
    /// The structured task action, when this wake performs one (run/pause/interrupt/summarize).
    /// Nil for a bare reminder. This is what lets the fired wake dispatch structurally, never by
    /// parsing `instructions`.
    public var action: TaskActionKind?

    public init(
        wakeAt: Date,
        instructions: String,
        taskID: UUID? = nil,
        replacesID: UUID? = nil,
        recurrence: Recurrence? = nil,
        survivesTaskTermination: Bool = false,
        action: TaskActionKind? = nil
    ) {
        self.wakeAt = wakeAt
        self.instructions = instructions
        self.taskID = taskID
        self.replacesID = replacesID
        self.recurrence = recurrence
        self.survivesTaskTermination = survivesTaskTermination
        self.action = action
    }
}

/// Result of a `scheduleWake` request.
enum ScheduleWakeOutcome: Sendable {
    case scheduled(ScheduledWake)
    /// The request was rejected (validation error, etc.).
    case error(String)
}

/// Why a scheduled wake was cancelled. Used by the timer-event log so the history view
/// can distinguish "user cancelled" from "auto-cancelled because the linked task ended".
public enum WakeCancellationCause: String, Sendable, Codable {
    case userRequest
    case taskTerminated
    case agentTerminated
    case replaced
}
