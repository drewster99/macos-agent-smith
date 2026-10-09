import Foundation

/// A pending wake and the session whose wake scheduler owns it. Only that session can cancel it.
public struct OwnedScheduledWake: Sendable, Equatable, Identifiable {
    public let wake: ScheduledWake
    public let sessionID: UUID
    public var id: UUID { wake.id }

    public init(wake: ScheduledWake, sessionID: UUID) {
        self.wake = wake
        self.sessionID = sessionID
    }
}

/// The task rows' view of upcoming runs: every open session's pending wakes, by task, soonest first.
///
/// Wakes belong to one session's scheduler, but a library template — the task a recurring schedule
/// lives on — is listed in every window. Indexing only the viewing session's wakes is why a
/// template's "Next:" chip was missing from every window but the one that scheduled it (#23). The
/// index is display-only: each wake keeps its owning session, which alone can cancel it.
public enum PendingWakeIndex {
    /// Wakes that are still pending at `now` and belong to a task, grouped by task and sorted by
    /// fire time. A wake with no task (a reminder) or a fire time already past is left out.
    public static func build(_ wakesBySession: [UUID: [ScheduledWake]], now: Date) -> [UUID: [OwnedScheduledWake]] {
        var grouped: [UUID: [OwnedScheduledWake]] = [:]
        for (sessionID, wakes) in wakesBySession {
            for wake in wakes where wake.wakeAt > now {
                guard let taskID = wake.taskID else { continue }
                grouped[taskID, default: []].append(OwnedScheduledWake(wake: wake, sessionID: sessionID))
            }
        }
        for key in grouped.keys {
            grouped[key]?.sort { ($0.wake.wakeAt, $0.wake.id.uuidString) < ($1.wake.wakeAt, $1.wake.id.uuidString) }
        }
        return grouped
    }
}
