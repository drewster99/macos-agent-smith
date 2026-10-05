import Foundation
import SwiftLLMKit

/// The one definition of how a coordinator's note about a child task travels through the
/// `NotificationBroker`: to `.taskWorker(coordinatorTaskID)`, a PULL recipient whose durable queue
/// waits for the coordinator's worker — the live one drains it at its next loop top, a respawned
/// one after its briefing turn — and is acknowledged only once acted on. Ids are deterministic, so
/// a resubmission (a crash between submitting and recording, a dropped outcome re-sent with a
/// departure) dedups.
public enum CoordinatorBriefingDelivery {
    /// The payload keys of a `coordinator_briefing`.
    public enum Key {
        public static let note = "note"
        public static let childTaskID = "child_task_id"
        public static let effectRecordID = "effect_record_id"
        /// Smith's own note about the same transition — present only when the coordinator's note
        /// REPLACED it (`CoordinatorTaskBriefing.replacesSmithBriefing`): what Smith is owed if the
        /// coordinator never reads this one.
        public static let smithNote = "smith_note"
    }

    /// A child's outcome or stall, from the effect record its status write left.
    static func outcomeNotification(
        for record: TaskEffectRecord,
        coordinatorTaskID: UUID,
        note: String,
        smithNote: String?,
        now: Date = Date()
    ) -> AgentNotification {
        let transition = record.transition
        let trigger = TriggerSource.taskTransition(taskID: transition.taskID, statusRevision: transition.statusRevision)
        var data: [String: AnyCodable] = [
            Key.note: .string(note),
            Key.childTaskID: .string(transition.taskID.uuidString),
            Key.effectRecordID: .string(record.id)
        ]
        if let smithNote { data[Key.smithNote] = .string(smithNote) }
        return AgentNotification(
            id: NotificationID(namespace: trigger.namespace, key: record.id),
            triggerSource: trigger,
            recipient: .taskWorker(taskID: coordinatorTaskID),
            title: "Child task \(transition.to.displayName)",
            createdAt: now,
            payload: Payload(type: KnownNotificationType.coordinatorBriefing.rawValue, data: data)
        )
    }

    /// An unfinished child that left the active list. Keyed by the child's last status revision and
    /// where it went, so a repeated event dedups and a later, different departure does not.
    static func departureNotification(_ departure: CoordinatorChildDeparture, now: Date = Date()) -> AgentNotification {
        let child = departure.child
        let trigger = TriggerSource.taskLifecycle(taskID: child.id)
        let destination: String
        switch departure.departure {
        case .leftActive(let disposition): destination = disposition.rawValue
        case .permanentlyDeleted: destination = "permanentlyDeleted"
        }
        return AgentNotification(
            id: NotificationID(namespace: trigger.namespace, key: "\(child.id.uuidString)|\(child.statusRevision)|\(destination)"),
            triggerSource: trigger,
            recipient: .taskWorker(taskID: departure.coordinatorTaskID),
            title: "Child task left the task list",
            createdAt: now,
            payload: Payload(type: KnownNotificationType.coordinatorBriefing.rawValue, data: [
                Key.note: .string(CoordinatorTaskBriefing.departureNote(departure)),
                Key.childTaskID: .string(child.id.uuidString)
            ])
        )
    }

    /// Smith's copy of a child's note. ONE id, used by the direct fallback (the coordinator was
    /// already gone at delivery) and by the reroute (it went with the note still queued), so the
    /// two dedup against each other.
    static func smithFallback(effectRecordID: String, trigger: TriggerSource, title: String, smithNote: String, now: Date = Date()) -> AgentNotification {
        AgentNotification(
            id: NotificationID(namespace: trigger.namespace, key: "\(effectRecordID)|smith"),
            triggerSource: trigger,
            recipient: .smith,
            title: title,
            createdAt: now,
            payload: Payload(type: KnownNotificationType.taskBriefing.rawValue, data: ["note": .string(smithNote)])
        )
    }

    /// Smith's copy of a queued note its coordinator will never read; nil when Smith is owed nothing
    /// (a stall or departure note, or an outcome whose Smith note was never replaced). Throws for a
    /// notification that isn't a well-formed `coordinator_briefing`.
    static func smithFallback(rerouting queued: AgentNotification) throws -> AgentNotification? {
        guard queued.payload.type == KnownNotificationType.coordinatorBriefing.rawValue else {
            throw NotificationHandlerError("not a coordinator_briefing: \(queued.payload.type)")
        }
        guard case .string(let smithNote)? = queued.payload.data[Key.smithNote] else { return nil }
        guard case .string(let recordID)? = queued.payload.data[Key.effectRecordID] else {
            throw NotificationHandlerError("coordinator_briefing has a Smith note but no effect record id")
        }
        return smithFallback(effectRecordID: recordID, trigger: queued.triggerSource, title: queued.title, smithNote: smithNote)
    }
}
