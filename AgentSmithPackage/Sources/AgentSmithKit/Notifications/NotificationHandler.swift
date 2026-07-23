import Foundation

/// What a handler did with a notification. The outcome IS the dispatch — there is no separate
/// dispatch-mode enum and no router switch on a declared mode.
public enum HandlerOutcome: Sendable, Equatable {
    /// The runtime effect is complete (e.g. a task was paused). No recipient delivery follows.
    case acted
    /// Hand this fully-framed text to the notification's recipient target. Type-specific framing
    /// (the untrusted-content warning for a user message, the "a timer fired" wrapper for a
    /// reminder) is applied HERE by the handler, not by the recipient target.
    case deliver(String)
}

/// The capabilities a notification handler needs from the runtime. A narrow facade so handlers
/// depend on an interface, not on `OrchestrationRuntime` directly (the runtime conforms via an
/// adapter). Keeps the notification subsystem free of a cycle back into orchestration.
public protocol NotificationRuntime: Sendable {
    /// Start (or resume) a task through the capacity-gated lifecycle path — queues at capacity,
    /// never evicts a live worker.
    func autoRunTask(_ taskID: UUID) async
    /// Set a task's status (used by the pause / interrupt actions).
    func setTaskStatus(_ taskID: UUID, to status: AgentTask.Status) async
    /// The current title of a task, for composing display/instruction text. Nil if unknown.
    func taskTitle(_ taskID: UUID) async -> String?
}

/// Decodes a notification's `data` and either performs the runtime effect or returns the text to
/// deliver. One handler is registered per `payload.type`.
public protocol NotificationHandler: Sendable {
    /// Perform this notification. Throw ONLY on malformed `data` for a type we own — a bug or
    /// corruption, not version skew (an unknown type never reaches a handler; it safe-no-ops).
    func handle(_ notification: AgentNotification, runtime: any NotificationRuntime) async throws -> HandlerOutcome
}
