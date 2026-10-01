import Foundation
import SwiftLLMKit

/// Turns one firing of a task watch into the broker notification that carries it out, and composes
/// the text each notifying action delivers. The ONE place a firing's wire form is defined.
public enum TaskWatchDelivery {
    /// The `.external` recipient key the app registers its macOS notification service under.
    public static let macOSNotificationTarget = "macos"

    /// Payload keys (persisted in the broker's outbox and ledger).
    public enum Key {
        public static let taskID = "task_id"
        public static let targetTaskID = "target_task_id"
        public static let action = "action"
        public static let text = "text"
        /// The full notification title for the macOS banner (the envelope `title` is capped chrome).
        public static let bannerTitle = "banner_title"
    }

    /// The deterministic broker id of a firing.
    public static func notificationID(watchID: UUID, occurrence: Int) -> NotificationID {
        NotificationID(namespace: TriggerSource.taskWatch(watchID: watchID, occurrence: occurrence).namespace, key: "\(watchID.uuidString)|\(occurrence)")
    }

    public static func notification(task: AgentTask, watch: TaskWatch, firing: TaskWatchFiring, now: Date = Date()) -> AgentNotification {
        var data: [String: AnyCodable] = [Key.taskID: .string(task.id.uuidString)]
        let recipient: Recipient
        switch watch.action {
        case .startTask(let targetID):
            recipient = .runtime
            data[Key.action] = .string(TaskWatchPayloadAction.startTask.rawValue)
            data[Key.targetTaskID] = .string(targetID.uuidString)
        case .macOSNotification:
            recipient = .external(macOSNotificationTarget)
            data[Key.action] = .string(TaskWatchPayloadAction.deliverText.rawValue)
            data[Key.bannerTitle] = .string(bannerTitle(task: task, trigger: firing.trigger))
            data[Key.text] = .string(bannerBody(task: task, trigger: firing.trigger))
        case .summarizeToUser:
            recipient = .smith
            data[Key.action] = .string(TaskWatchPayloadAction.deliverText.rawValue)
            data[Key.text] = .string(summaryRequest(task: task, trigger: firing.trigger))
        case .instructSmith(let instructions):
            recipient = .smith
            data[Key.action] = .string(TaskWatchPayloadAction.deliverText.rawValue)
            data[Key.text] = .string(smithInstructions(instructions, task: task, trigger: firing.trigger))
        }
        return AgentNotification(
            id: notificationID(watchID: watch.id, occurrence: firing.occurrence),
            triggerSource: .taskWatch(watchID: watch.id, occurrence: firing.occurrence),
            recipient: recipient,
            title: "\(task.title) \(firing.trigger.displayName)",
            createdAt: now,
            payload: Payload(type: KnownNotificationType.taskWatch.rawValue, data: data)
        )
    }

    // MARK: - Text

    static func subject(_ task: AgentTask) -> String {
        "Task \"\(task.title)\" (ID: \(task.id.uuidString))"
    }

    static func summaryRequest(task: AgentTask, trigger: TaskWatchTrigger) -> String {
        var text = """
            [System: A task watch fired — \(subject(task)) \(trigger.displayName). The user asked to be told when \
            this happens. Send the user a short summary with `message_user` NOW: what happened and, if it \
            finished, the outcome. This overrides any "no action is needed" in a status note about this task.]
            """
        if let detail = outcomeDetail(task: task, trigger: trigger) {
            text += "\n\n\(detail)"
        }
        return text
    }

    static func smithInstructions(_ instructions: String, task: AgentTask, trigger: TaskWatchTrigger) -> String {
        """
        [System: A task watch fired — \(subject(task)) \(trigger.displayName). The user left these \
        instructions for this moment. Carry them out now:]
        \(instructions)
        """
    }

    static func bannerTitle(task: AgentTask, trigger: TaskWatchTrigger) -> String {
        "\"\(task.title)\" \(trigger.displayName)"
    }

    static func bannerBody(task: AgentTask, trigger: TaskWatchTrigger) -> String {
        switch trigger {
        case .started:
            return "Work has started."
        case .completed:
            return excerpt(task.summary ?? task.result) ?? "The task is complete."
        case .failed:
            return excerpt(task.updates.last?.message) ?? "The task failed."
        case .needsHelp:
            return excerpt(task.helpRequest) ?? "The worker is blocked and needs help."
        case .needsReview:
            return excerpt(task.validationBlockedReason) ?? "Acceptance validation needs your review."
        case .interrupted:
            return "The task was interrupted."
        }
    }

    /// The text behind a state, for a summary request: the summary or result of a completed task,
    /// the latest update of a failed one, the blocker of one that needs help.
    private static func outcomeDetail(task: AgentTask, trigger: TaskWatchTrigger) -> String? {
        switch trigger {
        case .completed:
            if let summary = task.summary, !summary.isEmpty { return "Task summary:\n\(summary)" }
            if let result = task.result, !result.isEmpty { return "Task result:\n\(result)" }
            return nil
        case .failed:
            return task.updates.last.map { "Latest update:\n\($0.message)" }
        case .needsHelp:
            return task.helpRequest.map { "The worker's request:\n\($0)" }
        case .needsReview:
            return task.validationBlockedReason.map { "Why it is parked:\n\($0)" }
        case .started, .interrupted:
            return nil
        }
    }

    private static let bannerBodyLimit = 240

    private static func excerpt(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        guard trimmed.count > bannerBodyLimit else { return trimmed }
        return String(trimmed.prefix(bannerBodyLimit - 1)) + "…"
    }
}
