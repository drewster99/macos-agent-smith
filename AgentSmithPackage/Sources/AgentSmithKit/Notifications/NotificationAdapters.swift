import Foundation

/// A `RecipientTarget` backed by a closure — lets `OrchestrationRuntime` supply the delivery
/// mechanism (inject into an agent's conversation, post to the channel, an outward bridge, …)
/// without the notification layer importing orchestration.
public struct ClosureRecipientTarget: RecipientTarget {
    private let deliverText: @Sendable (String, AgentNotification) async -> Bool

    public init(_ deliverText: @escaping @Sendable (String, AgentNotification) async -> Bool) {
        self.deliverText = deliverText
    }

    public func deliver(_ text: String, for notification: AgentNotification) async -> Bool {
        await deliverText(text, notification)
    }
}

/// A `NotificationRuntime` backed by closures — the runtime builds it with `[weak self]` forwards
/// so the notification handlers can drive task lifecycle without a direct dependency on the actor.
public struct ClosureNotificationRuntime: NotificationRuntime {
    private let autoRun: @Sendable (UUID) async -> Void
    private let setStatus: @Sendable (UUID, AgentTask.Status) async -> Bool
    private let title: @Sendable (UUID) async -> String?
    private let systemNotice: @Sendable (String, UUID?) async -> Void

    public init(
        autoRunTask: @escaping @Sendable (UUID) async -> Void,
        setTaskStatus: @escaping @Sendable (UUID, AgentTask.Status) async -> Bool,
        taskTitle: @escaping @Sendable (UUID) async -> String?,
        postSystemNotice: @escaping @Sendable (String, UUID?) async -> Void
    ) {
        self.autoRun = autoRunTask
        self.setStatus = setTaskStatus
        self.title = taskTitle
        self.systemNotice = postSystemNotice
    }

    public func autoRunTask(_ taskID: UUID) async { await autoRun(taskID) }
    public func setTaskStatus(_ taskID: UUID, to status: AgentTask.Status) async -> Bool { await setStatus(taskID, status) }
    public func taskTitle(_ taskID: UUID) async -> String? { await title(taskID) }
    public func postSystemNotice(_ text: String, taskID: UUID?) async { await systemNotice(text, taskID) }
}

/// Builds the `AgentNotification` for a fired `ScheduledWake`, mapping the wake's structured
/// `action` (and taskID) to a payload type + recipient. The idempotency key is the wake's own id —
/// each occurrence has a unique id (recurrence mints a fresh one), so a re-post of the SAME
/// occurrence after a crash yields the same notification id and the ledger dedups it.
public enum WakeNotificationFactory {
    public static func notification(for wake: ScheduledWake) -> AgentNotification {
        let type: String
        let recipient: Recipient
        var data: [String: AnyCodable] = [:]

        if let taskID = wake.taskID, let action = wake.action {
            switch action {
            case .run, .pause, .interrupt:
                type = KnownNotificationType.taskAction.rawValue
                recipient = .runtime
                data["action"] = .string(action.rawValue)
                data["task_id"] = .string(taskID.uuidString)
            case .summarize:
                type = KnownNotificationType.taskSummary.rawValue
                recipient = .smith
                data["task_id"] = .string(taskID.uuidString)
                data["message"] = .string(wake.instructions)
            }
        } else {
            // No structured task action (a bare reminder, or a legacy pause/summarize whose action
            // migrated to nil) — deliver the instruction text to Smith, who executes it.
            type = KnownNotificationType.reminder.rawValue
            recipient = .smith
            data["message"] = .string(wake.instructions)
        }

        return AgentNotification(
            id: NotificationID(namespace: TriggerSource.timer(scheduleID: wake.originalID, occurrence: wake.wakeAt).namespace, key: wake.id.uuidString),
            triggerSource: .timer(scheduleID: wake.originalID, occurrence: wake.wakeAt),
            recipient: recipient,
            title: String(wake.instructions.prefix(AgentNotification.maxTitleCharacters)),
            createdAt: Date(),
            payload: Payload(type: type, data: data)
        )
    }
}
