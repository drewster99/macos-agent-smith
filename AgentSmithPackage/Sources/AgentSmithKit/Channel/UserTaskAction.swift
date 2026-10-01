import Foundation
import SwiftLLMKit

/// What the user did to a task from the app UI, carried on a `.userTaskAction` channel message.
///
/// The notice's prose is written for Smith; this is the typed fact the transcript reads to decide
/// which inline control (Resume, Undelete) the row offers. Persisted as its raw value under
/// `metadata["userTaskAction"]`, so a raw value is a storage format — renaming a case is free,
/// changing its string orphans every notice already written.
public enum UserTaskAction: String, Codable, Sendable, Hashable, CaseIterable {
    case paused = "paused"
    case stopped = "stopped"
    case deleted = "deleted"
    /// The user chose Retry on a failed task; the failed task was soft-deleted and Smith asked to
    /// re-create it.
    case retryRequested = "retry_requested"
    /// The user chose Run Again on a completed task; Smith asked to create a fresh copy.
    case runAgainRequested = "run_again_requested"
    /// The user recovered a task from Recently Deleted.
    case undeleted = "undeleted"
    /// The user lowered the worker capacity; this task's worker was stopped and the task will
    /// resume automatically when a slot frees.
    case deferredForCapacity = "deferred_for_capacity"
}

public extension AnyCodable {
    /// Wraps a user task action for the `metadata["userTaskAction"]` slot.
    static func userTaskAction(_ action: UserTaskAction) -> AnyCodable {
        .string(action.rawValue)
    }
}

public extension ChannelMessage {
    /// The user task action this notice records, or nil when the message carries none.
    ///
    /// Display-only — it decides which inline control a transcript row shows — so an unknown value
    /// resolves to nil (no control) rather than trapping.
    var userTaskAction: UserTaskAction? {
        guard case .string(let raw)? = metadata?["userTaskAction"] else { return nil }
        return UserTaskAction(rawValue: raw)
    }
}
