import Foundation
import os
import SemanticSearch

nonisolated private let memoryStoreLogger = Logger(subsystem: "com.agentsmith", category: "MemoryStore")

/// Search result pairing a memory with its scoring breakdown.
///
/// `similarity` is the raw cosine similarity from the embedding (kept under
/// the historical name so existing display code that formats it as a percentage stays
/// meaningful). `textScore` and `rrfScore` are additive: callers can ignore them, but
/// the search ordering returned by `MemoryStore` is by `rrfScore` descending.
public struct MemorySearchResult: Sendable {
    public let memory: MemoryEntry
    /// Cosine similarity between the query and the document, in `[-1, 1]`.
    public let similarity: Double
    /// Fraction of distinct query keywords found as whole tokens in the memory content, [0, 1].
    public let textScore: Double
    /// Reciprocal Rank Fusion score combining the semantic and lexical rankings (k=60).
    /// Used by `MemoryStore` to order results; higher means better combined match.
    public let rrfScore: Double
}

/// Search result pairing a task summary with its scoring breakdown. See
/// `MemorySearchResult` for the meaning of each score field.
public struct TaskSummarySearchResult: Sendable {
    public let summary: TaskSummaryEntry
    public let similarity: Double
    public let textScore: Double
    public let rrfScore: Double
}

/// Errors thrown by `MemoryStore` when the embedding backend returns something we
/// can't safely store or compare.
private enum MemoryStoreError: Error, CustomStringConvertible {
    /// The embedding backend returned an empty vector. Storing it would silently
    /// disable semantic search for the entry.
    case emptyEmbedding
    /// The embedding backend returned a vector containing NaN or infinity. Cosine
    /// math would propagate non-finite values through scoring and break sort order.
    case nonFiniteEmbedding

    var description: String {
        switch self {
        case .emptyEmbedding: return "Embedding backend returned an empty vector"
        case .nonFiniteEmbedding: return "Embedding backend returned a non-finite vector (NaN/inf)"
        }
    }
}

/// Combined search results from both memory and task summary corpora.
public struct SemanticSearchResults: Sendable {
    public let memories: [MemorySearchResult]
    public let taskSummaries: [TaskSummarySearchResult]

    /// True when both result sets are empty.
    public var isEmpty: Bool { memories.isEmpty && taskSummaries.isEmpty }
}

/// Lightweight struct for attaching relevant memories to tasks.
public struct RelevantMemory: Codable, Sendable, Equatable {
    public let content: String
    public let tags: [String]
    public let similarity: Double
    /// When the source `MemoryEntry` was originally saved. Optional so older tasks on
    /// disk (saved before this field existed) decode without falling over.
    public let createdAt: Date?
    /// When the source `MemoryEntry` was last edited, if ever. Optional for the same
    /// legacy-decode reason. UI prefers this over `createdAt` when present.
    public let lastUpdatedAt: Date?

    public init(
        content: String,
        tags: [String],
        similarity: Double,
        createdAt: Date? = nil,
        lastUpdatedAt: Date? = nil
    ) {
        self.content = content
        self.tags = tags
        self.similarity = similarity
        self.createdAt = createdAt
        self.lastUpdatedAt = lastUpdatedAt
    }
}

/// Lightweight struct for attaching relevant prior task summaries to tasks.
public struct RelevantPriorTask: Codable, Sendable, Equatable {
    public let taskID: UUID
    public let title: String
    public let summary: String
    public let similarity: Double
    /// Latest known timestamp on the prior task (typically the summary-generation time,
    /// which is post-completion). Optional so legacy tasks decode without failing.
    public let latestDate: Date?

    public init(
        taskID: UUID,
        title: String,
        summary: String,
        similarity: Double,
        latestDate: Date? = nil
    ) {
        self.taskID = taskID
        self.title = title
        self.summary = summary
        self.similarity = similarity
        self.latestDate = latestDate
    }

    /// Decodes a `RelevantPriorTask`, falling back to a random UUID for `taskID`
    /// when the key is absent.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        taskID = try c.decodeIfPresent(UUID.self, forKey: .taskID) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        summary = try c.decode(String.self, forKey: .summary)
        similarity = try c.decode(Double.self, forKey: .similarity)
        latestDate = try c.decodeIfPresent(Date.self, forKey: .latestDate)
    }
}

/// Thread-safe store for semantic memories and task summary embeddings.
///
/// Uses **single-vector embeddings** produced by `SemanticSearchEngine` (Qwen3 via MLX
/// by default). Each document is embedded as one L2-normalized vector and search
/// scores it against the query with a single cosine. Multi-vector retrieval (the
/// previous design with `splitAndEmbed`) was a workaround for `NLEmbedding`'s
/// sentence-only training and is no longer needed.
public actor MemoryStore {
    private var memories: [UUID: MemoryEntry] = [:]
    private var taskSummaries: [UUID: TaskSummaryEntry] = [:]
    private let engine: SemanticSearchEngine
    private var onChange: (@Sendable () -> Void)?
    /// Set when `searchAll` bumps retrieval stats. Decoupled from `onChange?()` so reads don't
    /// trigger a full-corpus re-serialization; flushed lazily by `persistRetrievalStatsIfNeeded()`.
    private var retrievalStatsDirty = false

    public init(engine: SemanticSearchEngine) {
        self.engine = engine
    }

    /// Registers a callback fired whenever memories or task summaries change.
    public func setOnChange(_ handler: @escaping @Sendable () -> Void) {
        onChange = handler
    }

    /// Flushes any pending retrieval-stat bumps accumulated on the read path. If stats are
    /// dirty, clears the flag and fires `onChange?()` so the normal persist path serializes
    /// the updated `retrievalCount`/`lastRetrievedAt` values. Harmless (a no-op) when clean,
    /// so it is safe to call unconditionally from the app-termination flush.
    public func persistRetrievalStatsIfNeeded() {
        guard retrievalStatsDirty else { return }
        retrievalStatsDirty = false
        onChange?()
    }

    // MARK: - Memory Operations

    /// Saves a new memory, embedding the content as a single L2-normalized vector
    /// using the current `SemanticSearchEngine`.
    @discardableResult
    public func save(
        content: String,
        source: MemoryEntry.Source,
        tags: [String] = [],
        sourceTaskID: UUID? = nil
    ) async throws -> MemoryEntry {
        let vector = try await engine.embed(content)
        try Self.validate(embedding: vector)
        let entry = MemoryEntry(
            content: content,
            embedding: vector,
            source: source,
            tags: tags,
            sourceTaskID: sourceTaskID,
            embeddingModelID: engine.model.identifier
        )
        memories[entry.id] = entry
        onChange?()
        return entry
    }

    /// Updates an existing memory's content and/or tags. Records who performed the edit
    /// in the entry's `lastUpdatedAt` / `lastUpdatedBy` fields. Re-embeds when the content
    /// changed. Returns the updated entry, or nil if the ID wasn't found (or was deleted
    /// concurrently while embedding).
    @discardableResult
    public func update(
        id: UUID,
        content: String? = nil,
        tags: [String]? = nil,
        updatedBy: MemoryEntry.UpdateSource
    ) async throws -> MemoryEntry? {
        guard let preEmbed = memories[id] else { return nil }
        let newContent = content ?? preEmbed.content
        let newTags = tags ?? preEmbed.tags
        let reembedded = content != nil && content != preEmbed.content
        let newEmbedding: [Float]
        if reembedded {
            newEmbedding = try await engine.embed(newContent)
            try Self.validate(embedding: newEmbedding)
        } else {
            newEmbedding = preEmbed.embedding
        }
        // Re-read after the (possible) embed suspension. Actor methods are reentrant,
        // so a delete or another update or a `searchAll` retrieval-count bump could
        // have landed while we awaited. Use the fresh entry for invariant fields
        // (createdAt, retrievalCount, lastRetrievedAt, source) so we don't clobber
        // them with stale snapshot values from before the suspend.
        guard let current = memories[id] else { return nil }
        let updated = MemoryEntry(
            id: current.id,
            content: newContent,
            embedding: newEmbedding,
            source: current.source,
            tags: newTags,
            sourceTaskID: current.sourceTaskID,
            createdAt: current.createdAt,
            lastRetrievedAt: current.lastRetrievedAt,
            retrievalCount: current.retrievalCount,
            lastUpdatedAt: Date(),
            lastUpdatedBy: updatedBy,
            embeddingModelID: reembedded ? engine.model.identifier : current.embeddingModelID
        )
        memories[id] = updated
        onChange?()
        return updated
    }

    /// Deletes a memory by ID.
    @discardableResult
    public func delete(id: UUID) -> Bool {
        guard memories.removeValue(forKey: id) != nil else { return false }
        onChange?()
        return true
    }

    /// All memories, newest first.
    public func allMemories() -> [MemoryEntry] {
        memories.values.sorted { $0.createdAt > $1.createdAt }
    }

    /// Total number of stored memories.
    public var memoryCount: Int { memories.count }

    // MARK: - Task Summary Operations

    /// Composes the embedding source text from all available task fields.
    ///
    /// Includes title, description, summary, result, commentary, and progress updates
    /// so the embedding captures the full topical signal of the task. No length caps —
    /// long results and update logs are embedded in full so they remain searchable.
    public static func composeEmbeddingText(task: AgentTask, summary: String) -> String {
        var parts: [String] = []
        parts.append(task.title)
        parts.append(task.description)
        parts.append(summary)
        if let result = task.result, !result.isEmpty {
            parts.append(result)
        }
        if let commentary = task.commentary, !commentary.isEmpty {
            parts.append(commentary)
        }
        if !task.updates.isEmpty {
            let updateText = task.updates.map(\.message).joined(separator: " ")
            parts.append(updateText)
        }
        return parts.joined(separator: "\n")
    }

    /// Saves a task summary, embedding the rich composite text as a single vector.
    /// Captures the task's original `createdAt` so the editor can show "when the task
    /// was asked for" rather than "when the summary was generated."
    @discardableResult
    public func saveTaskSummary(
        task: AgentTask,
        summary: String,
        status: AgentTask.Status
    ) async throws -> TaskSummaryEntry {
        let embeddingText = Self.composeEmbeddingText(task: task, summary: summary)
        let vector = try await engine.embed(embeddingText)
        try Self.validate(embedding: vector)
        let entry = TaskSummaryEntry(
            id: task.id,
            title: task.title,
            summary: summary,
            embeddingSourceText: embeddingText,
            embedding: vector,
            status: status,
            taskCreatedAt: task.createdAt,
            embeddingModelID: engine.model.identifier
        )
        taskSummaries[task.id] = entry
        onChange?()
        return entry
    }

    /// Re-embeds any stored memory or task summary whose `embeddingModelID` differs from the current
    /// engine's model identifier (including legacy `nil` rows). This is the migration hook for an
    /// embedding-output change (model / quantization / pooling) where the vector *dimension* is
    /// unchanged and so would otherwise go undetected. Per-entry failures are logged and skipped so
    /// one bad row can't abort the pass. Fires `onChange()` once if anything changed so the caller's
    /// persistence runs. Returns how many of each were re-embedded.
    @discardableResult
    /// How many stored entries `reembedStaleEntries()` would re-embed — i.e. whose `embeddingModelID`
    /// differs from the engine's current model identifier (and have re-embeddable text). Cheap; runs
    /// no embeddings. Lets the caller decide whether to show a progress UI before starting.
    public func staleEntryCount() -> Int {
        let signature = engine.model.identifier
        let mem = memories.values.filter { $0.embeddingModelID != signature && !$0.content.isEmpty }.count
        let task = taskSummaries.values.filter { $0.embeddingModelID != signature && !$0.embeddingSourceText.isEmpty }.count
        return mem + task
    }

    public func reembedStaleEntries() async -> (memories: Int, taskSummaries: Int) {
        let signature = engine.model.identifier
        let start = Date()
        var memCount = 0, taskCount = 0

        for id in memories.filter({ $0.value.embeddingModelID != signature }).map(\.key) {
            guard let entry = memories[id], entry.embeddingModelID != signature, !entry.content.isEmpty else { continue }
            do {
                let vector = try await engine.embed(entry.content)
                try Self.validate(embedding: vector)
                // Re-read post-suspension (actor reentrancy): skip if deleted or content changed.
                guard let cur = memories[id], cur.content == entry.content else { continue }
                memories[id] = MemoryEntry(
                    id: cur.id, content: cur.content, embedding: vector, source: cur.source,
                    tags: cur.tags, sourceTaskID: cur.sourceTaskID, createdAt: cur.createdAt,
                    lastRetrievedAt: cur.lastRetrievedAt, retrievalCount: cur.retrievalCount,
                    lastUpdatedAt: cur.lastUpdatedAt, lastUpdatedBy: cur.lastUpdatedBy,
                    embeddingModelID: signature
                )
                memCount += 1
            } catch {
                memoryStoreLogger.error("reembedStaleEntries: memory \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        for id in taskSummaries.filter({ $0.value.embeddingModelID != signature }).map(\.key) {
            guard let entry = taskSummaries[id], entry.embeddingModelID != signature,
                  !entry.embeddingSourceText.isEmpty else { continue }
            do {
                let vector = try await engine.embed(entry.embeddingSourceText)
                try Self.validate(embedding: vector)
                guard let cur = taskSummaries[id], cur.embeddingSourceText == entry.embeddingSourceText else { continue }
                taskSummaries[id] = TaskSummaryEntry(
                    id: cur.id, title: cur.title, summary: cur.summary,
                    embeddingSourceText: cur.embeddingSourceText, embedding: vector, status: cur.status,
                    taskCreatedAt: cur.taskCreatedAt, createdAt: cur.createdAt,
                    embeddingModelID: signature
                )
                taskCount += 1
            } catch {
                memoryStoreLogger.error("reembedStaleEntries: task summary \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        if memCount > 0 || taskCount > 0 {
            let elapsed = Date().timeIntervalSince(start)
            let perDoc = elapsed * 1000 / Double(max(1, memCount + taskCount))
            memoryStoreLogger.notice("reembedStaleEntries: re-embedded \(memCount, privacy: .public) memories + \(taskCount, privacy: .public) task summaries to model \(signature, privacy: .public) in \(String(format: "%.1f", elapsed), privacy: .public)s (\(String(format: "%.0f", perDoc), privacy: .public) ms/doc)")
            onChange?()
        }
        return (memCount, taskCount)
    }

    /// All task summaries, newest first.
    public func allTaskSummaries() -> [TaskSummaryEntry] {
        taskSummaries.values.sorted { $0.createdAt > $1.createdAt }
    }

    /// Total number of stored task summaries.
    public var taskSummaryCount: Int { taskSummaries.count }

    // MARK: - Search scoring

    /// `k` constant for Reciprocal Rank Fusion. The standard literature value is 60 —
    /// it dampens the influence of any single ranking source so high ranks dominate
    /// without completely shutting out lower-ranked items.
    private static let rrfK: Double = 60

    /// Default noise floor on `MAX(semantic, text)` used by all search entry points.
    /// A document must clear this on at least one signal to be considered. Tuned for
    /// Qwen3 cosines (typical unrelated-text scores sit well below 0.10) — matches the
    /// thresholds the per-corpus searches already used and lets RRF do the actual
    /// ordering instead of relying on a high hardcoded gate.
    public static let defaultSearchThreshold: Double = 0.10

    /// Absolute cosine relevance gates for context INJECTION — distinct from `defaultSearchThreshold`,
    /// which is only a noise floor on `max(semantic, text)`. A candidate is injected only if its
    /// semantic cosine clears the pool's gate. This is what suppresses the "always inject the top-K"
    /// behavior that fires context on unrelated/no-answer queries. Gating is on COSINE, not lexical:
    /// the retrieval eval showed keyword presence ≠ relevance (it re-introduces false injects), while
    /// the embedding cosine separates gold from noise. Values are from the prompt-sweep eval, measured
    /// WITH the per-pool instructions below (which shift cosines): task gold≈0.72/FP≈0.64, memory
    /// gold≈0.68/FP≈0.51. Tunable via `RetrievalEvalRunner`.
    public static let taskInjectionCosineGate: Double = 0.62
    public static let memoryInjectionCosineGate: Double = 0.58

    /// Per-pool Qwen3 retrieval instructions, applied query-side at the context-injection sites
    /// (CreateTaskTool, Smith's auto-context). The long task framing measured best for prior-task
    /// retrieval (rec@10 0.95→0.97, MRR +0.02); the short memory framing is ≈ tied with a longer one,
    /// so we keep it simple. Document embeddings stay raw. Picked via the prompt-sweep eval.
    public static let taskRetrievalInstruction = "Given a software engineering task, retrieve earlier tasks that are related, similar, or could inform how to carry it out."
    public static let memoryRetrievalInstruction = "Return related memories"

    /// Common English stopwords stripped from query tokens before text scoring.
    private static let englishStopwords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "is", "are", "was", "were", "be", "been", "being",
        "of", "in", "on", "at", "to", "for", "with", "from", "by", "as", "into", "out", "up", "down",
        "over", "under", "between", "through", "about",
        "this", "that", "these", "those", "it", "its",
        "what", "which", "who", "whom", "whose", "when", "where", "why", "how",
        "do", "does", "did", "done", "doing",
        "can", "could", "would", "should", "will", "may", "might", "must", "shall",
        "i", "me", "my", "mine", "you", "your", "yours", "we", "us", "our", "ours",
        "they", "them", "their", "theirs", "he", "she", "him", "her", "his", "hers",
        "if", "then", "than", "so", "no", "not", "yes", "too", "very", "just",
        "have", "has", "had", "having",
        "any", "all", "some", "each", "every", "both", "few", "more", "most", "other", "such",
        "only", "own", "same"
    ]

    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                if current.count >= 2 { tokens.append(current) }
                current = ""
            }
        }
        if current.count >= 2 { tokens.append(current) }
        return tokens
    }

    static func queryTokenSet(from query: String) -> Set<String> {
        Set(tokenize(query).filter { !englishStopwords.contains($0) })
    }

    /// Wraps a query in the Qwen3 instruction format when an instruction is given; returns the bare
    /// query otherwise. Applied per-pool, query-side only, so memories and task summaries can be
    /// retrieved under different task framings (the document embeddings stay raw).
    static func instructed(_ instruction: String?, _ query: String) -> String {
        guard let instruction, !instruction.isEmpty else { return query }
        return "Instruct: \(instruction)\nQuery: \(query)"
    }

    private static func textScore(queryTokens: Set<String>, document: String) -> Double {
        guard !queryTokens.isEmpty else { return 0.0 }
        let documentTokens = Set(tokenize(document))
        let matched = queryTokens.intersection(documentTokens)
        return Double(matched.count) / Double(queryTokens.count)
    }

    private static func reciprocalRankFusion(
        semanticScores: [Double],
        textScores: [Double]
    ) -> [Double] {
        precondition(semanticScores.count == textScores.count)
        let count = semanticScores.count
        guard count > 0 else { return [] }

        let semanticRanks = ranksFromScores(semanticScores)
        let textRanks = ranksFromScores(textScores)

        var rrf = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let sRank = Double(semanticRanks[i])
            let lRank = Double(textRanks[i])
            rrf[i] = 1.0 / (rrfK + sRank) + 1.0 / (rrfK + lRank)
        }
        return rrf
    }

    private static func ranksFromScores(_ scores: [Double]) -> [Int] {
        let count = scores.count
        guard count > 0 else { return [] }
        let sortedIndices = (0..<count).sorted { scores[$0] > scores[$1] }
        var ranks = [Int](repeating: 0, count: count)
        var lastScore: Double = .nan
        var lastRank = 0
        for (position, originalIdx) in sortedIndices.enumerated() {
            let score = scores[originalIdx]
            let rank: Int
            if score == lastScore {
                rank = lastRank
            } else {
                rank = position + 1
                lastScore = score
                lastRank = rank
            }
            ranks[originalIdx] = rank
        }
        return ranks
    }

    /// Validates a freshly produced embedding before it's persisted or compared.
    /// Throws `MemoryStoreError` so callers see a real failure instead of silently
    /// storing a vector that disables semantic search (empty) or breaks sort
    /// order (NaN/inf propagating through cosine).
    static func validate(embedding: [Float]) throws {
        if embedding.isEmpty { throw MemoryStoreError.emptyEmbedding }
        for value in embedding where !value.isFinite {
            throw MemoryStoreError.nonFiniteEmbedding
        }
    }

    // MARK: - Search

    /// Searches memories using Reciprocal Rank Fusion of semantic similarity and keyword
    /// overlap. The `threshold` parameter is a noise floor on `MAX(semantic, text)`.
    public func searchMemories(
        query: String,
        limit: Int = 5,
        threshold: Double = 0.10
    ) async throws -> [MemorySearchResult] {
        let start = Date()
        let queryVector = try await engine.embed(query)
        try Self.validate(embedding: queryVector)
        let queryTokens = Self.queryTokenSet(from: query)
        let results = searchMemoriesInternal(
            queryVector: queryVector,
            queryTokens: queryTokens,
            limit: limit,
            threshold: threshold
        )
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        memoryStoreLogger.debug("searchMemories: \(results.count, privacy: .public) results from \(self.memories.count, privacy: .public) memories in \(ms, privacy: .public)ms (query: \(query.prefix(60), privacy: .public))")
        return results
    }

    private func searchMemoriesInternal(
        queryVector: [Float],
        queryTokens: Set<String>,
        limit: Int,
        threshold: Double,
        cosineGate: Double? = nil
    ) -> [MemorySearchResult] {
        var entryRefs: [MemoryEntry] = []
        var semanticScores: [Double] = []
        var textScores: [Double] = []
        for entry in memories.values {
            let semantic: Double
            if entry.embedding.count == queryVector.count, !entry.embedding.isEmpty {
                semantic = Double(VectorMath.dotProduct(queryVector, entry.embedding))
            } else {
                semantic = 0
            }
            let text = Self.textScore(queryTokens: queryTokens, document: entry.content)
            if max(semantic, text) >= threshold {
                entryRefs.append(entry)
                semanticScores.append(semantic)
                textScores.append(text)
            }
        }

        guard !entryRefs.isEmpty else { return [] }

        let rrfScores = Self.reciprocalRankFusion(
            semanticScores: semanticScores,
            textScores: textScores
        )

        var results: [MemorySearchResult] = []
        results.reserveCapacity(entryRefs.count)
        for i in 0..<entryRefs.count {
            results.append(MemorySearchResult(
                memory: entryRefs[i],
                similarity: semanticScores[i],
                textScore: textScores[i],
                rrfScore: rrfScores[i]
            ))
        }
        results.sort { $0.rrfScore > $1.rrfScore }
        // Optional injection cosine gate: keep only candidates whose semantic cosine clears the bar,
        // then take the top-`limit` by RRF. nil ⇒ ungated (browse / explicit-search paths).
        let gated = cosineGate.map { gate in results.filter { $0.similarity >= gate } } ?? results
        return Array(gated.prefix(limit))
    }

    public func searchTaskSummaries(
        query: String,
        limit: Int = 5,
        threshold: Double = 0.10
    ) async throws -> [TaskSummarySearchResult] {
        let start = Date()
        let queryVector = try await engine.embed(query)
        try Self.validate(embedding: queryVector)
        let queryTokens = Self.queryTokenSet(from: query)
        let results = searchTaskSummariesInternal(
            queryVector: queryVector,
            queryTokens: queryTokens,
            limit: limit,
            threshold: threshold
        )
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        memoryStoreLogger.debug("searchTaskSummaries: \(results.count, privacy: .public) results from \(self.taskSummaries.count, privacy: .public) summaries in \(ms, privacy: .public)ms (query: \(query.prefix(60), privacy: .public))")
        return results
    }

    private func searchTaskSummariesInternal(
        queryVector: [Float],
        queryTokens: Set<String>,
        limit: Int,
        threshold: Double,
        cosineGate: Double? = nil
    ) -> [TaskSummarySearchResult] {
        var entryRefs: [TaskSummaryEntry] = []
        var semanticScores: [Double] = []
        var textScores: [Double] = []
        for entry in taskSummaries.values {
            let semantic: Double
            if entry.embedding.count == queryVector.count, !entry.embedding.isEmpty {
                semantic = Double(VectorMath.dotProduct(queryVector, entry.embedding))
            } else {
                semantic = 0
            }
            let text = Self.textScore(queryTokens: queryTokens, document: entry.embeddingSourceText)
            if max(semantic, text) >= threshold {
                entryRefs.append(entry)
                semanticScores.append(semantic)
                textScores.append(text)
            }
        }

        guard !entryRefs.isEmpty else { return [] }

        let rrfScores = Self.reciprocalRankFusion(
            semanticScores: semanticScores,
            textScores: textScores
        )

        var results: [TaskSummarySearchResult] = []
        results.reserveCapacity(entryRefs.count)
        for i in 0..<entryRefs.count {
            results.append(TaskSummarySearchResult(
                summary: entryRefs[i],
                similarity: semanticScores[i],
                textScore: textScores[i],
                rrfScore: rrfScores[i]
            ))
        }
        results.sort { $0.rrfScore > $1.rrfScore }
        // Optional injection cosine gate: keep only candidates whose semantic cosine clears the bar,
        // then take the top-`limit` by RRF. nil ⇒ ungated (browse / explicit-search paths).
        let gated = cosineGate.map { gate in results.filter { $0.similarity >= gate } } ?? results
        return Array(gated.prefix(limit))
    }

    /// Searches memories and task summaries, each against its own (optionally instruction-prefixed)
    /// query embedding, and returns the per-pool top-K. Qwen3 instruction prefixes are query-side, so
    /// each pool needs its own embedding — which is why this delegates to the per-pool searches
    /// instead of sharing one vector. RRF is fused within each pool; the optional cosine gates apply
    /// the injection relevance floor; `threshold` is the candidate noise floor on `max(semantic, text)`.
    public func searchAll(
        query: String,
        memoryLimit: Int = 3,
        taskLimit: Int = 3,
        threshold: Double = MemoryStore.defaultSearchThreshold,
        memoryCosineGate: Double? = nil,
        taskCosineGate: Double? = nil,
        memoryInstruction: String? = nil,
        taskInstruction: String? = nil
    ) async throws -> SemanticSearchResults {
        let start = Date()
        // Each pool gets its own (optionally instruction-prefixed) query embedding. Reuse the
        // memory vector for tasks when the prefixed queries are identical — the common (no-prefix
        // or same-prefix) case — so we don't pay for a second embed needlessly.
        let memoryQuery = Self.instructed(memoryInstruction, query)
        let taskQuery = Self.instructed(taskInstruction, query)
        let memoryVector = try await engine.embed(memoryQuery)
        try Self.validate(embedding: memoryVector)
        let taskVector: [Float]
        if taskQuery == memoryQuery {
            taskVector = memoryVector
        } else {
            taskVector = try await engine.embed(taskQuery)
            try Self.validate(embedding: taskVector)
        }

        let memoryResults = searchMemoriesInternal(
            queryVector: memoryVector,
            queryTokens: Self.queryTokenSet(from: memoryQuery),
            limit: memoryLimit,
            threshold: threshold,
            cosineGate: memoryCosineGate
        )
        let taskResults = searchTaskSummariesInternal(
            queryVector: taskVector,
            queryTokens: Self.queryTokenSet(from: taskQuery),
            limit: taskLimit,
            threshold: threshold,
            cosineGate: taskCosineGate
        )

        // Retrieval-stat bumps for the memories we actually return. Marked dirty (not flushed) so we
        // don't re-serialize the embedding-bearing corpus on every read; persistRetrievalStatsIfNeeded()
        // flushes once at termination. Genuine corpus mutations still fire onChange?() immediately.
        let retrievedAt = Date()
        var trackedAnyRetrieval = false
        for result in memoryResults {
            if var stored = memories[result.memory.id] {
                stored.lastRetrievedAt = retrievedAt
                stored.retrievalCount += 1
                memories[result.memory.id] = stored
                trackedAnyRetrieval = true
            }
        }
        if trackedAnyRetrieval { retrievalStatsDirty = true }

        let ms = Int(Date().timeIntervalSince(start) * 1000)
        memoryStoreLogger.debug("searchAll: \(memoryResults.count, privacy: .public) memories + \(taskResults.count, privacy: .public) tasks in \(ms, privacy: .public)ms (query: \(query.prefix(60), privacy: .public))")
        return SemanticSearchResults(memories: memoryResults, taskSummaries: taskResults)
    }

    // MARK: - Persistence Support

    /// Restores memories and task summaries from persisted data (e.g., on app launch).
    public func restore(memories: [MemoryEntry], taskSummaries: [TaskSummaryEntry]) {
        for memory in memories {
            self.memories[memory.id] = memory
        }
        for summary in taskSummaries {
            self.taskSummaries[summary.id] = summary
        }
    }

    /// Removes all memories and task summaries.
    public func clear() {
        memories.removeAll()
        taskSummaries.removeAll()
        onChange?()
    }
}
