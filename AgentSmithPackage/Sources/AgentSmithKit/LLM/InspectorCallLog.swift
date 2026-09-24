import Foundation

/// A bounded, honest log of provider calls for one inspector subject (a role or an instance).
///
/// Retention is bounded on purpose — every retained turn carries a response and its input — but
/// the bound must never be silent. So the log owns three facts the retained array alone cannot
/// express:
///
/// - **Stable ordinals.** Each call gets its 1-based lifetime position when it arrives. Numbering
///   by retained-array index silently renamed lifetime call 44 to "1" after eviction.
/// - **Lifetime count**, so a view can say "latest 100 of 143".
/// - **Why a full context snapshot is absent** — dropped by the retention window versus never
///   captured are different facts and read differently.
public struct InspectorCallLog: Sendable, Equatable {
    /// Whether a completed turn still carries its full request snapshot, and if not, why.
    public enum SnapshotRetention: Sendable, Equatable {
        /// `turn.contextSnapshot` holds the full request.
        case retained
        /// The request was captured but released because the turn fell outside the snapshot window.
        case discardedByRetention
        /// The caller never supplied a full request snapshot for this turn.
        case notCaptured
    }

    /// One retained provider call.
    public enum Entry: Identifiable, Sendable, Equatable {
        case completed(ordinal: Int, turn: LLMTurnRecord, snapshot: SnapshotRetention)
        case failed(ordinal: Int, failure: LLMCallFailureRecord)

        public var id: UUID {
            switch self {
            case .completed(_, let turn, _): return turn.id
            case .failed(_, let failure): return failure.id
            }
        }

        /// 1-based lifetime position within the log's subject.
        public var ordinal: Int {
            switch self {
            case .completed(let ordinal, _, _), .failed(let ordinal, _): return ordinal
            }
        }
    }

    /// Retained calls, oldest first.
    public private(set) var entries: [Entry] = []
    /// Retained completed turns, oldest first — maintained alongside `entries` so readers that
    /// need only responses (cost/token stats) never re-filter on every render.
    public private(set) var retainedTurns: [LLMTurnRecord] = []
    /// Every call ever appended, including evicted ones.
    public private(set) var lifetimeCount: Int = 0
    /// Every failed call ever appended, including evicted ones.
    public private(set) var lifetimeFailureCount: Int = 0

    /// Maximum retained entries.
    public let capacity: Int
    /// Only the newest `snapshotWindow` completed turns keep their full context snapshot.
    public let snapshotWindow: Int

    public init(capacity: Int, snapshotWindow: Int) {
        precondition(capacity > 0, "InspectorCallLog capacity must be positive")
        precondition(snapshotWindow >= 0, "InspectorCallLog snapshotWindow must be non-negative")
        self.capacity = capacity
        self.snapshotWindow = snapshotWindow
    }

    /// Calls dropped by the capacity bound.
    public var evictedCount: Int { lifetimeCount - entries.count }

    /// Appends one call event, assigning its lifetime ordinal.
    public mutating func append(_ event: LLMCallEvent) {
        lifetimeCount += 1
        switch event {
        case .completed(let turn):
            let snapshot: SnapshotRetention = turn.contextSnapshot.isEmpty ? .notCaptured : .retained
            entries.append(.completed(ordinal: lifetimeCount, turn: turn, snapshot: snapshot))
            retainedTurns.append(turn)
        case .failed(let failure):
            lifetimeFailureCount += 1
            entries.append(.failed(ordinal: lifetimeCount, failure: failure))
        }
        evictOverflow()
        releaseSnapshotsOutsideWindow()
    }

    private mutating func evictOverflow() {
        let overflow = entries.count - capacity
        guard overflow > 0 else { return }
        let evicted = entries.prefix(overflow)
        let evictedTurnCount = evicted.reduce(0) { count, entry in
            if case .completed = entry { return count + 1 }
            return count
        }
        entries.removeFirst(overflow)
        retainedTurns.removeFirst(evictedTurnCount)
    }

    /// Walks newest-to-oldest, releasing every retained snapshot past the window.
    private mutating func releaseSnapshotsOutsideWindow() {
        var completedSeen = 0
        var turnIndex = retainedTurns.count
        for index in entries.indices.reversed() {
            guard case .completed(let ordinal, var turn, let snapshot) = entries[index] else { continue }
            completedSeen += 1
            turnIndex -= 1
            guard completedSeen > snapshotWindow else { continue }
            // Everything older was already released by an earlier append.
            guard snapshot == .retained else {
                if snapshot == .discardedByRetention { break }
                continue
            }
            turn.stripContextSnapshot()
            entries[index] = .completed(ordinal: ordinal, turn: turn, snapshot: .discardedByRetention)
            retainedTurns[turnIndex] = turn
        }
    }
}
