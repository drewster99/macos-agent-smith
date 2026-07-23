import Foundation

/// The notification `payload.type` strings this app itself produces. A FIRST-PARTY convenience
/// only — the broker keys handlers on a raw `String` and knows nothing about this enum, so a new
/// source can register a handler for a brand-new type without touching it.
///
/// Its two jobs: (1) typo-safe constants at our own `post` / `registerHandler` call sites instead
/// of scattered string literals; (2) backing the startup guard — iterate `allCases` and assert
/// every rawValue has a registered handler ("every first-party type is handled").
public enum KnownNotificationType: String, CaseIterable, Sendable {
    /// Mechanical task timer: run / pause / interrupt. Dispatch `.acted`, recipient `.runtime`.
    case taskAction = "task_action"
    /// Scheduled progress report on one task. Dispatch `.deliver`, recipient `.smith`.
    case taskSummary = "task_summary"
    /// Smith's self-directed timer (schedule_reminder). Dispatch `.deliver`, recipient `.smith`.
    case reminder
    /// Inbound external message observed by a worker. Dispatch `.deliver`, recipient `.smith`.
    case userMessage = "user_message"
}
