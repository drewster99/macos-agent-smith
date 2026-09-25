import Foundation

/// A durable side effect of one status transition, recorded ON THE TASK in the same write as the
/// status (`AgentTask.pendingEffects`), so the two become durable together or not at all. The
/// runtime's effect consumer delivers it once the write is on disk and removes it once delivered;
/// its id is deterministic, so a redelivery after a crash is recognized as the same effect.
public struct TaskEffectRecord: Codable, Sendable, Equatable, Identifiable {
    /// `taskID|statusRevision|subscriber` — deterministic, so a re-submission after a crash dedups.
    public let id: String
    public let transition: TaskStatusTransition
    public let effect: TaskEffect
    public var release: Release

    /// Whether the effect may be delivered yet. A transition whose effect depends on facts the
    /// writer establishes AFTER the status write (a completion banner, a worker's briefing) is
    /// written `held` and released once they exist (`TaskStore.releaseEffects`).
    public enum Release: String, Codable, Sendable {
        case held
        case released
    }

    public init(transition: TaskStatusTransition, effect: TaskEffect, release: Release) {
        self.id = "\(transition.taskID.uuidString)|\(transition.statusRevision)|\(effect.subscriber.rawValue)"
        self.transition = transition
        self.effect = effect
        self.release = release
    }
}

/// Who produced an effect — part of the effect's identity.
public enum TaskEffectSubscriber: String, Codable, Sendable {
    /// The built-in briefing that tells Smith about a task's status change.
    case smithBriefing
}

/// What a transition's effect does when delivered.
public enum TaskEffect: Codable, Sendable, Equatable {
    /// Tell Smith, through the broker's durable Smith queue.
    case smithBriefing(note: String)

    public var subscriber: TaskEffectSubscriber {
        switch self {
        case .smithBriefing: return .smithBriefing
        }
    }
}

/// Names a transition whose effects were written `held`. Pass it to `TaskStore.releaseEffects` once
/// the facts the effects depend on exist.
public struct TransitionEffectTicket: Sendable, Hashable {
    public let taskID: UUID
    public let statusRevision: Int
}

/// A released effect ready for delivery, with the store mutation that must be durable first.
public struct ReadyTaskEffect: Sendable, Equatable {
    public let taskID: UUID
    public let record: TaskEffectRecord
    /// `TaskStore.awaitDurable(through:)` must succeed for this before the effect is delivered.
    public let durableThrough: UInt64
}
