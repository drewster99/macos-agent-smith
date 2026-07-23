import Foundation

/// One row in the timer-history log. Captures every interesting lifecycle moment of a
/// scheduled wake — when it was set, when it fired, when it was cancelled and why. Persisted
/// per-session so the user can see "what timers actually happened?" across runs.
public struct TimerEvent: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let kind: Kind
    /// The wake's id at the moment of the event. For recurring chains this changes each fire
    /// (each occurrence is a fresh wake), but `originalID` stays the same.
    public let wakeID: UUID
    public let originalID: UUID
    public let instructions: String
    public let taskID: UUID?
    public let recurrenceDescription: String?
    /// Set on `.fired` events when the wake was the first of a multi-wake batch — gives the
    /// history view a way to show "X timers fired together at HH:MM".
    public let coalescedCount: Int?
    /// Set on `.scheduled` events for the originally-requested fire time, so the history view
    /// can show "fires at <date>" without joining against a separate snapshot.
    public let scheduledFireAt: Date?
    /// Set on `.cancelled` events. Lets the UI distinguish user-cancellation from
    /// auto-cancellation when the linked task ended.
    public let cancellationCause: WakeCancellationCause?
    /// The wake's structured task action, when it had one. Lets the history view label the row
    /// from `bannerLabel` instead of scraping the imperative prose. Nil for reminders and for
    /// events persisted before this field existed (decoded via `decodeIfPresent`).
    public let action: TaskActionKind?

    public enum Kind: String, Codable, Sendable {
        case scheduled
        case fired
        case cancelled
    }

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        kind: Kind,
        wakeID: UUID,
        originalID: UUID,
        instructions: String,
        taskID: UUID? = nil,
        recurrenceDescription: String? = nil,
        coalescedCount: Int? = nil,
        scheduledFireAt: Date? = nil,
        cancellationCause: WakeCancellationCause? = nil,
        action: TaskActionKind? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.wakeID = wakeID
        self.originalID = originalID
        self.instructions = instructions
        self.taskID = taskID
        self.recurrenceDescription = recurrenceDescription
        self.coalescedCount = coalescedCount
        self.scheduledFireAt = scheduledFireAt
        self.cancellationCause = cancellationCause
        self.action = action
    }
}

/// Append-only log of timer lifecycle events. Capped to keep memory bounded (oldest rows are
/// dropped first). Used by the View → Timers history pane.
public actor TimerEventLog {
    public static let maxRetainedEvents = 500

    private var events: [TimerEvent] = []
    private var onChange: (@Sendable () -> Void)?

    public init() {}

    public func setOnChange(_ handler: @escaping @Sendable () -> Void) {
        onChange = handler
    }

    /// Returns events newest-first.
    public func allEvents() -> [TimerEvent] {
        events.sorted { $0.timestamp > $1.timestamp }
    }

    public func record(_ event: TimerEvent) {
        events.append(event)
        if events.count > Self.maxRetainedEvents {
            events.removeFirst(events.count - Self.maxRetainedEvents)
        }
        onChange?()
    }

    /// Replaces the entire log — used at cold-launch to restore from disk.
    public func restore(_ persistedEvents: [TimerEvent]) {
        events = persistedEvents.suffix(Self.maxRetainedEvents)
        onChange?()
    }

    public func clear() {
        events.removeAll()
        onChange?()
    }
}

public extension TimerEvent {
    static func scheduled(from wake: ScheduledWake) -> TimerEvent {
        TimerEvent(
            kind: .scheduled,
            wakeID: wake.id,
            originalID: wake.originalID,
            instructions: wake.instructions,
            taskID: wake.taskID,
            recurrenceDescription: wake.recurrence?.displayDescription,
            scheduledFireAt: wake.wakeAt,
            action: wake.action
        )
    }

    static func fired(primary: ScheduledWake, batchSize: Int) -> TimerEvent {
        TimerEvent(
            kind: .fired,
            wakeID: primary.id,
            originalID: primary.originalID,
            instructions: primary.instructions,
            taskID: primary.taskID,
            recurrenceDescription: primary.recurrence?.displayDescription,
            coalescedCount: batchSize > 1 ? batchSize : nil,
            scheduledFireAt: primary.wakeAt,
            action: primary.action
        )
    }

    static func cancelled(wake: ScheduledWake, cause: WakeCancellationCause) -> TimerEvent {
        TimerEvent(
            kind: .cancelled,
            wakeID: wake.id,
            originalID: wake.originalID,
            instructions: wake.instructions,
            taskID: wake.taskID,
            recurrenceDescription: wake.recurrence?.displayDescription,
            scheduledFireAt: wake.wakeAt,
            cancellationCause: cause,
            action: wake.action
        )
    }
}
