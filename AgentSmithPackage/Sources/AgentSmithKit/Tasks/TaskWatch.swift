import Foundation

/// A user- or Smith-defined rule on a task: "when this task reaches one of these states, do this".
/// Stored on the watched task (`AgentTask.watches`), so it travels with the task and fires in the
/// same store write as the transition that triggers it. See TaskStateEventsPlan.md.
public struct TaskWatch: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var triggers: Set<TaskWatchTrigger>
    public var action: TaskWatchAction
    public var lifetime: TaskWatchLifetime
    public var state: TaskWatchState
    /// The occurrence number the NEXT firing gets. Monotonic; survives compaction of
    /// `recentFirings`, so a firing's `watchID|occurrence` identity is never reused.
    public var nextOccurrence: Int
    public let createdBy: TaskAuthorship
    public let createdAt: Date
    /// The latest firings, oldest first. Unsettled firings are always kept; settled ones beyond
    /// `settledFiringsRetained` are compacted away (decision R4).
    public var recentFirings: [TaskWatchFiring]

    /// Settled firings kept per watch (decision R4).
    public static let settledFiringsRetained = 20

    public init(
        id: UUID = UUID(),
        triggers: Set<TaskWatchTrigger>,
        action: TaskWatchAction,
        lifetime: TaskWatchLifetime? = nil,
        createdBy: TaskAuthorship,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.triggers = triggers
        self.action = action
        self.lifetime = lifetime ?? action.defaultLifetime
        self.state = .active
        self.nextOccurrence = 1
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.recentFirings = []
    }

    public var isActive: Bool { state.isActive }

    /// Records a firing for `transition` and returns its occurrence. A `.once` watch is consumed
    /// HERE, when the firing is created — not when it is delivered — so it can never fire twice.
    mutating func recordFiring(trigger: TaskWatchTrigger, transition: TaskStatusTransition) -> Int {
        let occurrence = nextOccurrence
        nextOccurrence += 1
        recentFirings.append(TaskWatchFiring(occurrence: occurrence, trigger: trigger, transition: transition))
        if lifetime == .once {
            state = .consumed(at: transition.at)
        }
        compactSettledFirings()
        return occurrence
    }

    /// Updates one firing's state. Returns false when the firing is unknown.
    @discardableResult
    mutating func setFiringState(occurrence: Int, _ newState: TaskWatchFiring.State) -> Bool {
        guard let index = recentFirings.firstIndex(where: { $0.occurrence == occurrence }) else { return false }
        recentFirings[index].state = newState
        compactSettledFirings()
        return true
    }

    public func firing(occurrence: Int) -> TaskWatchFiring? {
        recentFirings.first { $0.occurrence == occurrence }
    }

    /// Drops the oldest SETTLED firings beyond the retention bound. Unsettled ones are never dropped.
    private mutating func compactSettledFirings() {
        let settled = recentFirings.filter(\.state.isSettled)
        let excess = settled.count - Self.settledFiringsRetained
        guard excess > 0 else { return }
        let dropped = Set(settled.prefix(excess).map(\.occurrence))
        recentFirings.removeAll { dropped.contains($0.occurrence) }
    }

    /// The copy a template instance receives: same rule, fresh identity, no history. `nil` for an
    /// action a template may not carry (see `TaskWatchAction.isAllowedOnTemplate`).
    func blueprintCopy(now: Date = Date()) -> TaskWatch? {
        guard isActive, action.isAllowedOnTemplate else { return nil }
        return TaskWatch(triggers: triggers, action: action, lifetime: lifetime, createdBy: createdBy, createdAt: now)
    }
}

/// The task states a watch can react to. Derived from a transition's `(to, cause)` in one place
/// (`init?(transition:)`), never from a bare status comparison: "started" is a worker actually
/// starting, not every entry into `.running` (validation handing rejections back also enters it).
public enum TaskWatchTrigger: String, Codable, Sendable, CaseIterable, Hashable {
    case started
    case completed
    case failed
    case needsHelp
    case needsReview
    case interrupted

    public init?(transition: TaskStatusTransition) {
        switch transition.cause {
        case .workerStarted, .workerStartedAtRuntimeStart:
            self = .started
            return
        case .sessionShutdown, .sessionDeletion:
            // The user quitting or deleting the session is not an event to notify about (decision 9).
            return nil
        case .capacityShed:
            // Lowering capacity parks the task for an automatic resume as soon as a slot frees: an
            // internal deferral, not an interruption anyone should react to (or chain on).
            return nil
        default:
            break
        }
        switch transition.to {
        case .completed: self = .completed
        case .failed: self = .failed
        case .awaitingHelp: self = .needsHelp
        case .awaitingReview: self = .needsReview
        case .interrupted: self = .interrupted
        case .pending, .starting, .running, .paused, .scheduled, .validating: return nil
        }
        // A missing-validator park is a configuration gap, not a review (the plan's matrix gives it
        // no watch trigger): only a validator escalation "needs review".
        if self == .needsReview, transition.cause != .validationEscalated { return nil }
    }

    public var displayName: String {
        switch self {
        case .started: return "starts"
        case .completed: return "completes"
        case .failed: return "fails"
        case .needsHelp: return "needs help"
        case .needsReview: return "needs review"
        case .interrupted: return "is interrupted"
        }
    }
}

/// What a watch does when it fires.
public enum TaskWatchAction: Codable, Sendable, Equatable, Hashable {
    /// Start another task in this session (a chain link). The target carries a start hold on the
    /// watched task until this fires.
    case startTask(taskID: UUID)
    /// Post a macOS notification.
    case macOSNotification
    /// Have Smith send the user a short summary.
    case summarizeToUser
    /// Hand Smith these instructions.
    case instructSmith(String)

    public var defaultLifetime: TaskWatchLifetime {
        switch self {
        case .startTask: return .once
        case .macOSNotification, .summarizeToUser, .instructSmith: return .everyTime
        }
    }

    /// A template is global; a `startTask` target is a task in ONE session, so a template may not
    /// carry one (decision 10). The notifying actions are fine as blueprints.
    public var isAllowedOnTemplate: Bool {
        if case .startTask = self { return false }
        return true
    }
}

public enum TaskWatchLifetime: String, Codable, Sendable {
    case once
    case everyTime
}

public enum TaskWatchState: Codable, Sendable, Equatable {
    case active
    case cancelled(at: Date)
    /// A `.once` watch that has fired.
    case consumed(at: Date)

    public var isActive: Bool {
        if case .active = self { return true }
        return false
    }
}

/// One firing of a watch: the audit record and the delivery state.
public struct TaskWatchFiring: Codable, Sendable, Equatable {
    public let occurrence: Int
    public let trigger: TaskWatchTrigger
    public let transition: TaskStatusTransition
    public var state: State

    public init(occurrence: Int, trigger: TaskWatchTrigger, transition: TaskStatusTransition) {
        self.occurrence = occurrence
        self.trigger = trigger
        self.transition = transition
        self.state = .pending
    }

    public enum State: Codable, Sendable, Equatable {
        /// Recorded with the transition; not yet handed to the broker.
        case pending
        /// Handed to the broker; its outcome is not known yet.
        case inFlight
        case delivered(at: Date)
        case refused(reason: String)
        /// The watch was cancelled before this firing settled.
        case cancelled

        public var isSettled: Bool {
            switch self {
            case .pending, .inFlight: return false
            case .delivered, .refused, .cancelled: return true
            }
        }
    }
}
