import Foundation

/// One entry in the durable scheduled-run queue: the task to start, plus the per-run refinements
/// the schedule attached (`schedule_task_action`'s `extra_instructions`).
///
/// The amendment rides the QUEUE rather than a side table because it has to survive exactly the
/// crash window the task id does — between the fired wake being settled and the worker actually
/// spawning. A parallel map keyed by task id would be a sidecar with its own persistence and its
/// own way to fall out of step.
///
/// **Wire compatibility:** the queue was persisted as a bare `[UUID]` before the amendment existed,
/// so `init(from:)` accepts either a bare UUID string or the object form. Encoding always writes
/// the object form. This is a one-way migration — a downgrade reads the new file as a decode
/// failure and starts with an empty queue, which is the same outcome as any other unreadable
/// queue file and loses at most a queued-but-unstarted run.
public struct PendingScheduledRun: Sendable, Codable, Equatable {
    public let taskID: UUID
    /// Applied to the started task (or, for a template, to its fresh instance) as that run's
    /// amendment. Nil when the schedule carried no refinements.
    public let amendment: String?

    public init(taskID: UUID, amendment: String? = nil) {
        self.taskID = taskID
        self.amendment = amendment
    }

    private enum CodingKeys: String, CodingKey { case taskID, amendment }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let id = try? single.decode(UUID.self) {
            self.taskID = id
            self.amendment = nil
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.taskID = try c.decode(UUID.self, forKey: .taskID)
        self.amendment = try c.decodeIfPresent(String.self, forKey: .amendment)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(taskID, forKey: .taskID)
        try c.encodeIfPresent(amendment, forKey: .amendment)
    }
}
