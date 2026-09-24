import Foundation

/// What caused a memory-store operation. Typed so no reader compares magic source strings.
public enum MemoryActivityOrigin: Sendable, Equatable {
    /// One of the orchestration retrieval points (auto-context, task context, validator, Security).
    case retrieval(RetrievalSource)
    /// An agent's `search_memory` tool call.
    case agentSearchMemory(AgentRole)
    /// The Memory Browser (user-driven search or edit).
    case memoryBrowser
    /// `save_memory`'s search for an existing memory to consolidate into.
    case memoryConsolidationCandidateSearch
    /// A caller outside the app's own paths (tests, tooling), named explicitly.
    case other(String)
}

/// Whether one corpus was searched, and exactly what it returned.
///
/// `notSearched` and `searched(hits: [])` are different facts: the first means the corpus's limit
/// was zero and no embedding or scan ran for it; the second means it was scored and nothing
/// passed ranking. Neither may be inferred from a hit count or an elapsed time.
public enum CorpusSearchOutcome<Hit: Sendable & Equatable>: Sendable, Equatable {
    case notSearched
    case searched(hits: [Hit])

    /// The returned hits, or nil when the corpus was not searched.
    public var hits: [Hit]? {
        switch self {
        case .notSearched: return nil
        case .searched(let hits): return hits
        }
    }
}

/// A returned memory as it was at query time. A snapshot, never a reference: a later edit or
/// deletion must not rewrite what a past query returned.
public struct MemoryHitSnapshot: Sendable, Equatable, Identifiable {
    public var id: UUID { memoryID }
    /// 1-based position in the returned order.
    public let rank: Int
    public let memoryID: UUID
    public let content: String
    public let tags: [String]
    public let source: MemoryEntry.Source
    public let sourceTaskID: UUID?
    public let cosineSimilarity: Double
    public let lexicalScore: Double
    public let reciprocalRankFusionScore: Double

    init(rank: Int, result: MemorySearchResult) {
        self.rank = rank
        memoryID = result.memory.id
        content = result.memory.content
        tags = result.memory.tags
        source = result.memory.source
        sourceTaskID = result.memory.sourceTaskID
        cosineSimilarity = result.similarity
        lexicalScore = result.textScore
        reciprocalRankFusionScore = result.rrfScore
    }
}

/// A returned prior-task summary as it was at query time.
public struct TaskSummaryHitSnapshot: Sendable, Equatable, Identifiable {
    public var id: UUID { taskID }
    /// 1-based position in the returned order.
    public let rank: Int
    public let taskID: UUID
    public let title: String
    public let summary: String
    public let status: AgentTask.Status
    public let taskCreatedAt: Date
    public let summaryCreatedAt: Date
    public let cosineSimilarity: Double
    public let lexicalScore: Double
    public let reciprocalRankFusionScore: Double

    init(rank: Int, result: TaskSummarySearchResult) {
        self.rank = rank
        taskID = result.summary.id
        title = result.summary.title
        summary = result.summary.summary
        status = result.summary.status
        taskCreatedAt = result.summary.taskCreatedAt
        summaryCreatedAt = result.summary.createdAt
        cosineSimilarity = result.similarity
        lexicalScore = result.textScore
        reciprocalRankFusionScore = result.rrfScore
    }
}

/// One memory-store query: what was asked, by whom, how long each phase took, and exactly what
/// each corpus returned.
public struct MemoryQueryActivity: Sendable, Equatable {
    public let query: String
    public let origin: MemoryActivityOrigin
    /// Links this query to the rest of one logical operation (a consolidation attempt).
    public let correlationID: UUID?
    /// Wall-clock round trip, including the query embedding.
    public let latencyMs: Int
    /// Time spent producing the query embedding(s).
    public let embedMs: Int
    /// Time spent scoring the memory corpus; nil when it was not searched.
    public let memoryScanMs: Int?
    /// Time spent scoring the prior-task corpus; nil when it was not searched.
    public let taskScanMs: Int?
    public let memories: CorpusSearchOutcome<MemoryHitSnapshot>
    public let taskSummaries: CorpusSearchOutcome<TaskSummaryHitSnapshot>

    public init(
        query: String,
        origin: MemoryActivityOrigin,
        correlationID: UUID?,
        latencyMs: Int,
        embedMs: Int,
        memoryScanMs: Int?,
        taskScanMs: Int?,
        memories: CorpusSearchOutcome<MemoryHitSnapshot>,
        taskSummaries: CorpusSearchOutcome<TaskSummaryHitSnapshot>
    ) {
        self.query = query
        self.origin = origin
        self.correlationID = correlationID
        self.latencyMs = latencyMs
        self.embedMs = embedMs
        self.memoryScanMs = memoryScanMs
        self.taskScanMs = taskScanMs
        self.memories = memories
        self.taskSummaries = taskSummaries
    }

    static func memoryOutcome(searched: Bool, results: [MemorySearchResult]) -> CorpusSearchOutcome<MemoryHitSnapshot> {
        guard searched else { return .notSearched }
        return .searched(hits: results.enumerated().map { MemoryHitSnapshot(rank: $0.offset + 1, result: $0.element) })
    }

    static func taskOutcome(searched: Bool, results: [TaskSummarySearchResult]) -> CorpusSearchOutcome<TaskSummaryHitSnapshot> {
        guard searched else { return .notSearched }
        return .searched(hits: results.enumerated().map { TaskSummaryHitSnapshot(rank: $0.offset + 1, result: $0.element) })
    }
}

/// One entry in the app-wide Memory activity feed.
///
/// `sequence` is assigned by `MemoryStore` — the single publisher — before the record leaves the
/// actor, so a consumer that receives records out of order (each delivery is its own main-actor
/// hop) can still order them exactly.
public struct MemoryActivity: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case query(MemoryQueryActivity)
    }

    public let id: UUID
    /// 1-based, strictly increasing per `MemoryStore` instance.
    public let sequence: Int
    public let timestamp: Date
    public let kind: Kind

    public init(id: UUID = UUID(), sequence: Int, timestamp: Date, kind: Kind) {
        self.id = id
        self.sequence = sequence
        self.timestamp = timestamp
        self.kind = kind
    }
}

/// A bounded, sequence-ordered window onto the Memory activity feed.
///
/// Inserts in `sequence` order regardless of arrival order, evicts the lowest sequences past
/// `capacity`, and counts everything ever received so a view can say "latest 200 of 327".
public struct MemoryActivityFeed: Sendable, Equatable {
    /// Retained activities, oldest (lowest sequence) first.
    public private(set) var activities: [MemoryActivity] = []
    /// Every activity ever received, including evicted ones.
    public private(set) var lifetimeCount = 0
    public let capacity: Int

    public init(capacity: Int) {
        precondition(capacity > 0, "MemoryActivityFeed capacity must be positive")
        self.capacity = capacity
    }

    public var evictedCount: Int { lifetimeCount - activities.count }

    public mutating func insert(_ activity: MemoryActivity) {
        lifetimeCount += 1
        let index = activities.lastIndex { $0.sequence < activity.sequence }.map { $0 + 1 } ?? 0
        activities.insert(activity, at: index)
        if activities.count > capacity {
            activities.removeFirst(activities.count - capacity)
        }
    }
}
