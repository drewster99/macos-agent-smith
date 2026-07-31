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
    /// A batched embed returned a different number of vectors than queries handed to it.
    /// Vectors are matched to queries positionally, so a count mismatch means we can no
    /// longer trust WHICH query any vector belongs to — failing beats searching a corpus
    /// with another pool's query vector.
    case batchEmbeddingCountMismatch(expected: Int, received: Int)
    /// A pool was scheduled for search but its query vector is missing from the batch result.
    /// Only reachable through a keying bug in `embedDistinct`; it earns an error rather than a
    /// fallback because returning `[]` would be indistinguishable from a genuine "nothing
    /// matched", quietly reporting an empty corpus we never actually scored.
    case missingMemoryQueryEmbedding
    case missingTaskQueryEmbedding

    var description: String {
        switch self {
        case .emptyEmbedding: return "Embedding backend returned an empty vector"
        case .nonFiniteEmbedding: return "Embedding backend returned a non-finite vector (NaN/inf)"
        case let .batchEmbeddingCountMismatch(expected, received):
            return "Batch embed returned \(received) vectors for \(expected) queries"
        case .missingMemoryQueryEmbedding: return "Batch embed result is missing the memory query vector"
        case .missingTaskQueryEmbedding: return "Batch embed result is missing the task query vector"
        }
    }
}

/// Combined search results from both memory and task summary corpora.
public struct SemanticSearchResults: Sendable {
    public let memories: [MemorySearchResult]
    public let taskSummaries: [TaskSummarySearchResult]

    /// True when both result sets are empty.
    public var isEmpty: Bool { memories.isEmpty && taskSummaries.isEmpty }

    /// Renders the retrieved memories + prior tasks as a compact labeled block for injection into a
    /// one-shot evaluation prompt (validator / security), or nil when nothing was retrieved. The one
    /// formatter shared by every new retrieval-injection site so they read identically.
    public func formattedForInjection() -> String? {
        if isEmpty { return nil }
        var lines: [String] = []
        if !memories.isEmpty {
            lines.append("Relevant memories:")
            for result in memories { lines.append("- \(result.memory.content)") }
        }
        if !taskSummaries.isEmpty {
            lines.append("Relevant prior tasks:")
            for result in taskSummaries { lines.append("- \(result.summary.title): \(result.summary.summary)") }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

/// Lightweight struct for attaching relevant memories to tasks.
public struct RelevantMemory: Codable, Sendable, Equatable {
    public let content: String
    public let tags: [String]
    public let similarity: Double
    /// The `MemoryEntry` this was copied from, so rendering it into a briefing can be counted
    /// against that memory's `injectionCount`. Optional: tasks persisted before this field
    /// existed decode with `nil` and simply aren't attributable — the copy below still renders,
    /// it just can't be traced back. Also `nil`-safe if the source memory is later deleted.
    public let memoryID: UUID?
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
        lastUpdatedAt: Date? = nil,
        memoryID: UUID? = nil
    ) {
        self.content = content
        self.tags = tags
        self.similarity = similarity
        self.createdAt = createdAt
        self.lastUpdatedAt = lastUpdatedAt
        self.memoryID = memoryID
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

/// A single memory-store query, logged for the inspector's Memory panel — the read-side analog of
/// the Security Agent's `EvaluationRecord`. Captures what was asked, how many hits came back, and
/// how long the round-trip (including the query embedding) took.
public struct MemoryQueryRecord: Sendable, Identifiable, Equatable {
    public let id = UUID()
    /// When the query was issued.
    public let timestamp: Date
    /// The raw query text.
    public let query: String
    /// Number of memory hits returned.
    public let memoryHits: Int
    /// Number of prior-task-summary hits returned (0 for a memories-only search).
    public let taskHits: Int
    /// Wall-clock round-trip time in milliseconds, including the query embedding.
    public let latencyMs: Int
    /// Milliseconds spent producing the query embedding(s). Usually the dominant term — a
    /// corpus scan is arithmetic over cached vectors, an embed is a model forward pass.
    public let embedMs: Int
    /// Milliseconds spent scoring the MEMORY corpus. Zero when memories weren't searched.
    public let memorySearchMs: Int
    /// Milliseconds spent scoring the PRIOR-TASK corpus. Zero when task summaries weren't
    /// searched — which is the normal case for auto-context on a user message.
    public let taskSearchMs: Int
    /// What triggered the query (e.g. "auto-context", "task-context", "search_memory", "system").
    public let source: String

    /// Compact "embed 180ms · mem-scan 34ms · task-scan 0ms" phase split, for the inspector's
    /// Memory card. Phases that didn't run are still printed: a ZERO is the informative part —
    /// it's how you tell a corpus that was SKIPPED from one that was scored and matched nothing.
    public var phaseBreakdown: String {
        "embed \(embedMs)ms · mem-scan \(memorySearchMs)ms · task-scan \(taskSearchMs)ms"
    }

    public init(
        timestamp: Date,
        query: String,
        memoryHits: Int,
        taskHits: Int,
        latencyMs: Int,
        embedMs: Int = 0,
        memorySearchMs: Int = 0,
        taskSearchMs: Int = 0,
        source: String
    ) {
        self.timestamp = timestamp
        self.query = query
        self.memoryHits = memoryHits
        self.taskHits = taskHits
        self.latencyMs = latencyMs
        self.embedMs = embedMs
        self.memorySearchMs = memorySearchMs
        self.taskSearchMs = taskSearchMs
        self.source = source
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
    /// Task IDs whose summaries must be excluded from search — the recently-deleted tasks. Kept
    /// as a pushed set (updated by the app layer when the global deleted bucket changes) rather
    /// than recomputed per search, and rather than physically removing the summaries, so undelete
    /// restores searchability for free. See `setExcludedTaskSummaryIDs`.
    private var excludedTaskSummaryIDs: Set<UUID> = []
    private let engine: SemanticSearchEngine
    private var onChange: (@Sendable () -> Void)?
    /// Fired after each `searchMemories` / `searchAll`, carrying the query, hit counts, and latency
    /// for the inspector's Memory log (the read-side analog of the Security Agent's evaluation log).
    private var onQueryRecorded: (@Sendable (MemoryQueryRecord) -> Void)?
    /// Bumps the "memory search" in-flight count for the concurrency meter. Optional so the store
    /// works headless (tests) with no tracker attached.
    private var activityTracker: LiveActivityTracker?
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

    /// Registers a callback fired after each memory-store query with its timing + hit counts.
    public func setOnQueryRecorded(_ handler: @escaping @Sendable (MemoryQueryRecord) -> Void) {
        onQueryRecorded = handler
    }

    /// Attaches the shared live-activity tracker so searches count toward the concurrency meter.
    public func setActivityTracker(_ tracker: LiveActivityTracker) {
        activityTracker = tracker
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

    /// Scheme token folded into a MEMORY's embedding signature. Bump it whenever the TEXT fed to the
    /// embedder changes independently of the model, so existing vectors are detected as stale and
    /// re-embedded. `tags1` = `embeddingSourceText` (content + tags); memories previously embedded
    /// content only. Task summaries deliberately keep the bare model identifier — their embedding
    /// text is unchanged, so this bump must not force them to re-embed.
    private static let memoryEmbeddingScheme = "tags1"

    /// The signature stamped on freshly-embedded MEMORIES (model identifier + scheme token).
    private var memoryEmbeddingSignature: String {
        "\(engine.model.identifier)#\(Self.memoryEmbeddingScheme)"
    }

    /// Saves a new memory, embedding its content + tags as a single L2-normalized vector
    /// using the current `SemanticSearchEngine`.
    @discardableResult
    public func save(
        content: String,
        source: MemoryEntry.Source,
        tags: [String] = [],
        sourceTaskID: UUID? = nil
    ) async throws -> MemoryEntry {
        let vector = try await engine.embed(MemoryEntry.embeddingSourceText(content: content, tags: tags))
        try Self.validate(embedding: vector)
        let entry = MemoryEntry(
            content: content,
            embedding: vector,
            source: source,
            tags: tags,
            sourceTaskID: sourceTaskID,
            embeddingModelID: memoryEmbeddingSignature
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
        // The embedding covers content + tags, so a tag-only edit must re-embed too.
        let reembedded = newContent != preEmbed.content || newTags != preEmbed.tags
        let newEmbedding: [Float]
        if reembedded {
            newEmbedding = try await engine.embed(MemoryEntry.embeddingSourceText(content: newContent, tags: newTags))
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
            lastInjectedAt: current.lastInjectedAt,
            injectionCount: current.injectionCount,
            lastUpdatedAt: Date(),
            lastUpdatedBy: updatedBy,
            embeddingModelID: reembedded ? memoryEmbeddingSignature : current.embeddingModelID
        )
        memories[id] = updated
        onChange?()
        return updated
    }

    /// Deletes a memory by ID.
    @discardableResult
    public func delete(id: UUID) -> Bool {
        guard memories.removeValue(forKey: id) != nil else { return false }
        memoryTokenCache.removeValue(forKey: id)
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
        // The acceptance contract and the worker's plan describe what the task was
        // really about, often more concretely than the description — include their
        // texts. Verdicts/validation results are deliberately EXCLUDED (pass/fail
        // chatter says nothing about the topic), as are tombstoned steps (abandoned
        // plans are retrieval noise).
        if !task.acceptanceCriteria.isEmpty {
            parts.append(task.acceptanceCriteria.map(\.text).joined(separator: " "))
        }
        let activeSteps = task.steps.filter(\.isActive)
        if !activeSteps.isEmpty {
            parts.append(activeSteps.map(\.text).joined(separator: " "))
        }
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

    /// Sets the task IDs whose summaries are excluded from search (the recently-deleted bucket).
    /// Pushed by the app layer whenever the global deleted set changes. Pure read-side filter —
    /// does not mutate the corpus, so it never fires `onChange`.
    public func setExcludedTaskSummaryIDs(_ ids: Set<UUID>) {
        excludedTaskSummaryIDs = ids
    }

    /// Permanently removes a task's summary from the corpus. Called when a task is permanently
    /// deleted (it's gone forever) — distinct from recently-deleted, which only hides the summary.
    public func removeTaskSummary(id: UUID) {
        guard taskSummaries.removeValue(forKey: id) != nil else { return }
        taskSummaryTokenCache.removeValue(forKey: id)
        excludedTaskSummaryIDs.remove(id)
        onChange?()
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
        let memSignature = memoryEmbeddingSignature
        let taskSignature = engine.model.identifier
        let mem = memories.values.filter { $0.embeddingModelID != memSignature && !$0.content.isEmpty }.count
        let task = taskSummaries.values.filter { $0.embeddingModelID != taskSignature && !$0.embeddingSourceText.isEmpty }.count
        return mem + task
    }

    /// Checkpoint cadence: persist progress every this many re-embedded entries so an interrupted
    /// migration resumes from where it left off instead of restarting from scratch each launch.
    private static let reembedCheckpointInterval = 32

    public func reembedStaleEntries() async -> (memories: Int, taskSummaries: Int, failed: Int) {
        let memSignature = memoryEmbeddingSignature
        let taskSignature = engine.model.identifier
        let start = Date()
        var memCount = 0, taskCount = 0, failed = 0
        // Each onChange enqueues a snapshot write of what's been re-embedded so far, so a kill
        // mid-migration doesn't discard completed work.
        func checkpointIfNeeded() {
            if (memCount + taskCount) % Self.reembedCheckpointInterval == 0 { onChange?() }
        }

        for id in memories.filter({ $0.value.embeddingModelID != memSignature }).map(\.key) {
            guard let entry = memories[id], entry.embeddingModelID != memSignature, !entry.content.isEmpty else { continue }
            do {
                let vector = try await engine.embed(entry.embeddingSourceText)
                try Self.validate(embedding: vector)
                // Re-read post-suspension (actor reentrancy): skip if deleted, or content/tags changed
                // (the embedding now depends on tags too, so a concurrent tag edit invalidates it).
                guard let cur = memories[id], cur.content == entry.content, cur.tags == entry.tags else { continue }
                memories[id] = MemoryEntry(
                    id: cur.id, content: cur.content, embedding: vector, source: cur.source,
                    tags: cur.tags, sourceTaskID: cur.sourceTaskID, createdAt: cur.createdAt,
                    lastRetrievedAt: cur.lastRetrievedAt, retrievalCount: cur.retrievalCount,
                    lastInjectedAt: cur.lastInjectedAt, injectionCount: cur.injectionCount,
                    lastUpdatedAt: cur.lastUpdatedAt, lastUpdatedBy: cur.lastUpdatedBy,
                    embeddingModelID: memSignature
                )
                memCount += 1
                checkpointIfNeeded()
            } catch {
                failed += 1
                memoryStoreLogger.error("reembedStaleEntries: memory \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        for id in taskSummaries.filter({ $0.value.embeddingModelID != taskSignature }).map(\.key) {
            guard let entry = taskSummaries[id], entry.embeddingModelID != taskSignature,
                  !entry.embeddingSourceText.isEmpty else { continue }
            do {
                let vector = try await engine.embed(entry.embeddingSourceText)
                try Self.validate(embedding: vector)
                guard let cur = taskSummaries[id], cur.embeddingSourceText == entry.embeddingSourceText else { continue }
                taskSummaries[id] = TaskSummaryEntry(
                    id: cur.id, title: cur.title, summary: cur.summary,
                    embeddingSourceText: cur.embeddingSourceText, embedding: vector, status: cur.status,
                    taskCreatedAt: cur.taskCreatedAt, createdAt: cur.createdAt,
                    embeddingModelID: taskSignature
                )
                taskCount += 1
                checkpointIfNeeded()
            } catch {
                failed += 1
                memoryStoreLogger.error("reembedStaleEntries: task summary \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        if memCount > 0 || taskCount > 0 {
            let elapsed = Date().timeIntervalSince(start)
            let perDoc = elapsed * 1000 / Double(max(1, memCount + taskCount))
            memoryStoreLogger.notice("reembedStaleEntries: re-embedded \(memCount, privacy: .public) memories + \(taskCount, privacy: .public) task summaries (\(failed, privacy: .public) failed) to model \(taskSignature, privacy: .public) in \(String(format: "%.1f", elapsed), privacy: .public)s (\(String(format: "%.0f", perDoc), privacy: .public) ms/doc)")
            onChange?()
        }
        return (memCount, taskCount, failed)
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
    ///
    /// The task gate sits *between* its FP and gold figures (like the memory gate does, 0.58 between
    /// 0.51 and 0.68): 0.62 was *below* the task FP figure (≈0.64), so it admitted more than half of
    /// the strongest false-positive prior tasks. 0.66 trims that FP noise while staying well under
    /// gold≈0.72 so genuinely-relevant prior tasks still inject. Re-confirm with a `RetrievalEvalRunner`
    /// gate sweep if the embedding model or eval corpus changes.
    public static let taskInjectionCosineGate: Double = 0.66
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

    /// BM25's term-saturation and length-normalization parameters, at the literature defaults.
    /// Deliberately NOT tuned to this corpus: without a labeled relevance set, "tuning" would mean
    /// fitting whichever values happen to reduce a proxy metric, which is fitting noise.
    private static let bm25TermSaturation = 1.2
    private static let bm25LengthNormalization = 0.75

    /// Everything a lexical score needs beyond a single document's tokens: how rare each query token
    /// is in the corpus being searched, how long a typical document runs, and which query tokens
    /// each document actually contains.
    ///
    /// Computed per query rather than maintained as a persistent index. Only the QUERY's tokens need
    /// document frequencies, so there is nothing to invalidate — and an inverted index would have to
    /// be kept in step with sixteen mutation sites to save work that measures in single-digit
    /// milliseconds.
    private struct LexicalScoring {
        let inverseDocumentFrequency: [String: Double]
        let totalQueryWeight: Double
        let averageDocumentLength: Double
        /// Query tokens present in each document, positionally aligned with the `documents` argument.
        let matchedTokensPerDocument: [Set<String>]
    }

    private static func lexicalScoring(
        queryTokens: Set<String>,
        documents: [Set<String>]
    ) -> LexicalScoring {
        var documentFrequency: [String: Int] = [:]
        var matchedPerDocument: [Set<String>] = []
        matchedPerDocument.reserveCapacity(documents.count)
        var totalLength = 0

        // ONE intersection per document produces both halves of what scoring needs: the query tokens
        // this document contains, and — accumulated across documents — how many contain each token.
        // Probing every query token against every document instead costs |query| x |corpus| lookups
        // TWICE (once to count, once to score). On a task-context query that is title plus full
        // description, `queryTokens` reaches ~780 distinct tokens, and that shape measured SLOWER
        // than the per-query re-tokenization this cache exists to eliminate. `Set.intersection`
        // walks the smaller set, so this pass is bounded by min(|query|, |document|) instead.
        for tokens in documents {
            let matched = queryTokens.intersection(tokens)
            for token in matched { documentFrequency[token, default: 0] += 1 }
            matchedPerDocument.append(matched)
            totalLength += tokens.count
        }

        let count = Double(documents.count)
        var idf: [String: Double] = [:]
        var total = 0.0
        // Only tokens that occur somewhere in the corpus contribute to the denominator. A query word
        // that appears in no document cannot be matched by any of them, so counting it would scale
        // every score down for the query's vocabulary rather than for the document's content — and
        // BM25's IDF weights a zero-frequency term most heavily of all, so the distortion would be
        // largest exactly where it is least deserved. `documentFrequency` holds precisely the
        // present tokens, so iterating it is the filter.
        for (token, frequency) in documentFrequency {
            let containing = Double(frequency)
            // BM25's IDF, in the +1 form that stays positive even for a token in every document.
            let weight = log(1 + (count - containing + 0.5) / (containing + 0.5))
            idf[token] = weight
            total += weight
        }

        return LexicalScoring(
            inverseDocumentFrequency: idf,
            totalQueryWeight: total,
            averageDocumentLength: documents.isEmpty ? 1 : Double(totalLength) / count,
            matchedTokensPerDocument: matchedPerDocument
        )
    }

    /// Lexical (keyword) half of the hybrid score: how much of the query's *distinctive* vocabulary
    /// this document contains, damped for document length. Range [0, 1].
    ///
    /// This replaced a plain coverage ratio (`matched / queryTokens.count`), which had no notion of
    /// either term rarity or document length. Both omissions pulled the same direction: a long
    /// document contains more distinct tokens, so it matched more of any query, and every match
    /// counted equally whether it was a unique identifier or a word in half the corpus. Measured
    /// over 25 real user queries against the 404-summary corpus, that scored as roughly a length
    /// proxy — Spearman +0.63 against document length, with the top-ranked document typically 9.9x
    /// longer than the corpus median. Weighting by IDF and damping by length takes those to +0.40
    /// and 0.7x, which is the behavior a lexical scorer is supposed to have: it exists to find rare
    /// exact tokens (identifiers, error codes, version numbers) that embeddings blur away.
    ///
    /// Because the document side is a SET, term frequency is always 1 for a matched term, so BM25's
    /// saturation term collapses to a per-document constant that depends only on length. Short
    /// documents matching nearly all of the query's weight can push the product just past 1 (0.14%
    /// of scores on the real corpus, never changing which document ranked first), so the result is
    /// clamped to keep the [0, 1] contract the `threshold` comparison and the UI both assume.
    private static func textScore(
        matchedTokens: Set<String>,
        documentLength: Int,
        scoring: LexicalScoring
    ) -> Double {
        guard scoring.totalQueryWeight > 0, !matchedTokens.isEmpty else { return 0.0 }
        var matchedWeight = 0.0
        for token in matchedTokens {
            matchedWeight += scoring.inverseDocumentFrequency[token] ?? 0
        }
        guard matchedWeight > 0 else { return 0.0 }

        let saturation = Self.bm25TermSaturation
        let normalization = Self.bm25LengthNormalization
        let relativeLength = Double(documentLength) / max(scoring.averageDocumentLength, 1)
        let lengthFactor = (saturation + 1)
            / (1 + saturation * (1 - normalization + normalization * relativeLength))
        return min(1.0, matchedWeight / scoring.totalQueryWeight * lengthFactor)
    }

    // MARK: - Lexical token cache

    /// A document's tokenized form, kept alongside the exact text it was built from.
    ///
    /// Storing the source text is what makes the cache safe: entries are written from sixteen
    /// different places in this file (adds, edits, retrieval-stat bumps, re-embeds, restore), and a
    /// cache invalidated by hand at each of those would eventually be missed by a new one and serve
    /// tokens for text that no longer exists. Validating against the current text instead means a
    /// missed site can only cost a recompute, never a wrong answer.
    private struct CachedTokens {
        let sourceText: String
        let tokens: Set<String>
    }

    private var memoryTokenCache: [UUID: CachedTokens] = [:]
    private var taskSummaryTokenCache: [UUID: CachedTokens] = [:]

    /// Tokens for a memory's lexical document, computing and caching them on first use.
    ///
    /// `textScore` used to tokenize every document on every query — a per-scalar walk over the full
    /// text building a `Set` that was discarded immediately, for a result that cannot change while
    /// the text doesn't. Measured on the real corpus that was 8.5ms for 223 memories and 302ms for
    /// 404 task summaries (4.08 MB of text), against 0.05ms for all 627 dot products combined: the
    /// scan was almost entirely re-tokenization, not vector math.
    private func documentTokens(for entry: MemoryEntry) -> Set<String> {
        let sourceText = entry.embeddingSourceText
        if let cached = memoryTokenCache[entry.id], cached.sourceText == sourceText {
            return cached.tokens
        }
        let tokens = Set(Self.tokenize(sourceText))
        memoryTokenCache[entry.id] = CachedTokens(sourceText: sourceText, tokens: tokens)
        return tokens
    }

    /// Tokens for a task summary's lexical document. See `documentTokens(for:)` above — this is the
    /// corpus where it matters, since summaries are an order of magnitude longer than memories.
    private func documentTokens(for entry: TaskSummaryEntry) -> Set<String> {
        let sourceText = entry.embeddingSourceText
        if let cached = taskSummaryTokenCache[entry.id], cached.sourceText == sourceText {
            return cached.tokens
        }
        let tokens = Set(Self.tokenize(sourceText))
        taskSummaryTokenCache[entry.id] = CachedTokens(sourceText: sourceText, tokens: tokens)
        return tokens
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
        threshold: Double = 0.10,
        source: String = "system"
    ) async throws -> [MemorySearchResult] {
        let tracker = activityTracker
        tracker?.begin(.memorySearch)
        defer { tracker?.end(.memorySearch) }
        let start = Date()
        let embedStart = Date()
        let queryVector = try await engine.embed(query)
        try Self.validate(embedding: queryVector)
        let embedMs = Int(Date().timeIntervalSince(embedStart) * 1000)
        let queryTokens = Self.queryTokenSet(from: query)
        let searchStart = Date()
        let results = searchMemoriesInternal(
            queryVector: queryVector,
            queryTokens: queryTokens,
            limit: limit,
            threshold: threshold
        )
        let memorySearchMs = Int(Date().timeIntervalSince(searchStart) * 1000)
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        // Embed cost is very nearly linear in the number of characters fed to the model, so the
        // length is what makes `embedMs` interpretable. This path embeds the query verbatim — no
        // instruction preamble — so embedded length IS the query length.
        memoryStoreLogger.notice("searchMemories [\(source, privacy: .public)]: \(results.count, privacy: .public) results from \(self.memories.count, privacy: .public) memories in \(ms, privacy: .public)ms (embed \(embedMs, privacy: .public)ms over \(query.count, privacy: .public) chars, memory-scan \(memorySearchMs, privacy: .public)ms) (query: \(query.prefix(60), privacy: .public))")
        onQueryRecorded?(MemoryQueryRecord(
            timestamp: start,
            query: query,
            memoryHits: results.count,
            taskHits: 0,
            latencyMs: ms,
            embedMs: embedMs,
            memorySearchMs: memorySearchMs,
            source: source
        ))
        return results
    }

    /// Records that these memories' text actually entered an agent's LLM context, bumping
    /// `lastInjectedAt` and `injectionCount`. Call at the moment of injection — after the block
    /// is committed to the message, after the relevance floor has run, when the briefing renders
    /// — NOT when a search returns, which is what `retrievalCount` already measures.
    ///
    /// IDs with no matching entry are skipped: a memory can be deleted between the search that
    /// found it and the context that used it, and that is not worth failing a turn over.
    /// Marked dirty rather than flushed, like the retrieval bumps — `persistRetrievalStatsIfNeeded()`
    /// writes both out together at termination rather than re-serializing the embedding-bearing
    /// corpus on every agent turn.
    public func recordInjections(memoryIDs: [UUID], at date: Date = Date()) {
        var trackedAny = false
        for id in memoryIDs {
            guard var stored = memories[id] else { continue }
            stored.lastInjectedAt = date
            stored.injectionCount += 1
            memories[id] = stored
            trackedAny = true
        }
        if trackedAny { retrievalStatsDirty = true }
    }

    /// Embeds the DISTINCT queries in a single batched forward pass and returns them keyed by
    /// query text. Deduplicating matters as much as batching: when two pools share an
    /// instruction prefix (or use none) the prefixed queries are identical, and embedding that
    /// text twice would be pure waste rather than merely a larger batch.
    private func embedDistinct(_ queries: [String]) async throws -> [String: [Float]] {
        var distinct: [String] = []
        for query in queries where !distinct.contains(query) {
            distinct.append(query)
        }
        guard !distinct.isEmpty else { return [:] }

        let vectors = try await engine.embed(batch: distinct)
        guard vectors.count == distinct.count else {
            throw MemoryStoreError.batchEmbeddingCountMismatch(
                expected: distinct.count,
                received: vectors.count
            )
        }
        var byQuery: [String: [Float]] = [:]
        for (query, vector) in zip(distinct, vectors) {
            try Self.validate(embedding: vector)
            byQuery[query] = vector
        }
        return byQuery
    }

    private func searchMemoriesInternal(
        queryVector: [Float],
        queryTokens: Set<String>,
        limit: Int,
        threshold: Double,
        cosineGate: Double? = nil
    ) -> [MemorySearchResult] {
        // A caller asking for zero results is asking us NOT to search this corpus. Scoring
        // every entry and then discarding all of it is pure waste — and `searchAll` skips the
        // matching query embedding on the same condition.
        guard limit > 0 else { return [] }
        // Lexical scoring needs corpus-level context — how rare each query token is, and how long a
        // typical document runs — so gather the cached token sets first and score in a second pass.
        // The extra pass costs |query tokens| x |corpus| set lookups against sets that are already
        // built, which is microseconds.
        var documents: [(entry: MemoryEntry, tokens: Set<String>)] = []
        documents.reserveCapacity(memories.count)
        for entry in memories.values {
            documents.append((entry, documentTokens(for: entry)))
        }
        let scoring = Self.lexicalScoring(queryTokens: queryTokens, documents: documents.map(\.tokens))

        var entryRefs: [MemoryEntry] = []
        var semanticScores: [Double] = []
        var textScores: [Double] = []
        for (index, (entry, tokens)) in documents.enumerated() {
            let semantic: Double
            if entry.embedding.count == queryVector.count, !entry.embedding.isEmpty {
                semantic = Double(VectorMath.dotProduct(queryVector, entry.embedding))
            } else {
                semantic = 0
            }
            let text = Self.textScore(
                matchedTokens: scoring.matchedTokensPerDocument[index],
                documentLength: tokens.count,
                scoring: scoring
            )
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
        threshold: Double = 0.10,
        excludeDeletedTasks: Bool = true,
        source: String = "system"
    ) async throws -> [TaskSummarySearchResult] {
        let tracker = activityTracker
        tracker?.begin(.memorySearch)
        defer { tracker?.end(.memorySearch) }
        let start = Date()
        let embedStart = Date()
        let queryVector = try await engine.embed(query)
        try Self.validate(embedding: queryVector)
        let embedMs = Int(Date().timeIntervalSince(embedStart) * 1000)
        let queryTokens = Self.queryTokenSet(from: query)
        let searchStart = Date()
        let results = searchTaskSummariesInternal(
            queryVector: queryVector,
            queryTokens: queryTokens,
            limit: limit,
            threshold: threshold,
            excludeDeleted: excludeDeletedTasks
        )
        let taskSearchMs = Int(Date().timeIntervalSince(searchStart) * 1000)
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        // See `searchMemories` — length is what makes `embedMs` interpretable, and this path also
        // embeds the query verbatim, so embedded length IS the query length.
        memoryStoreLogger.notice("searchTaskSummaries [\(source, privacy: .public)]: \(results.count, privacy: .public) results from \(self.taskSummaries.count, privacy: .public) summaries in \(ms, privacy: .public)ms (embed \(embedMs, privacy: .public)ms over \(query.count, privacy: .public) chars, task-scan \(taskSearchMs, privacy: .public)ms) (query: \(query.prefix(60), privacy: .public))")
        onQueryRecorded?(MemoryQueryRecord(
            timestamp: start,
            query: query,
            memoryHits: 0,
            taskHits: results.count,
            latencyMs: ms,
            embedMs: embedMs,
            taskSearchMs: taskSearchMs,
            source: source
        ))
        return results
    }

    private func searchTaskSummariesInternal(
        queryVector: [Float],
        queryTokens: Set<String>,
        limit: Int,
        threshold: Double,
        cosineGate: Double? = nil,
        excludeDeleted: Bool = true
    ) -> [TaskSummarySearchResult] {
        // See `searchMemoriesInternal`: limit 0 means "don't search this corpus at all",
        // not "score everything and return none of it".
        guard limit > 0 else { return [] }
        // When `excludeDeleted` is set (the pushed auto-context sites), skip summaries for
        // recently-deleted tasks — kept in the corpus so undelete restores them, but hidden from
        // unrequested context. Explicit `search_memory` pulls pass `excludeDeleted: false` so the
        // agent that asked still sees deleted tasks. The check happens before any vector math, and
        // before the lexical statistics, so rarity and average length describe the corpus actually
        // being searched rather than one the caller can't see.
        var documents: [(entry: TaskSummaryEntry, tokens: Set<String>)] = []
        documents.reserveCapacity(taskSummaries.count)
        for entry in taskSummaries.values where !(excludeDeleted && excludedTaskSummaryIDs.contains(entry.id)) {
            documents.append((entry, documentTokens(for: entry)))
        }
        let scoring = Self.lexicalScoring(queryTokens: queryTokens, documents: documents.map(\.tokens))

        var entryRefs: [TaskSummaryEntry] = []
        var semanticScores: [Double] = []
        var textScores: [Double] = []
        for (index, (entry, tokens)) in documents.enumerated() {
            let semantic: Double
            if entry.embedding.count == queryVector.count, !entry.embedding.isEmpty {
                semantic = Double(VectorMath.dotProduct(queryVector, entry.embedding))
            } else {
                semantic = 0
            }
            let text = Self.textScore(
                matchedTokens: scoring.matchedTokensPerDocument[index],
                documentLength: tokens.count,
                scoring: scoring
            )
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
        taskInstruction: String? = nil,
        excludeDeletedTasks: Bool = true,
        source: String = "system"
    ) async throws -> SemanticSearchResults {
        let tracker = activityTracker
        tracker?.begin(.memorySearch)
        defer { tracker?.end(.memorySearch) }
        let start = Date()
        // Each pool gets its own (optionally instruction-prefixed) query embedding, because the
        // instructions steer an instruction-tuned model toward different neighbourhoods. Both
        // are embedded in ONE batched forward pass rather than two sequential ones: the prefixes
        // still differ and each pool still gets its own vector, we just stop paying twice for it.
        // A pool with a zero limit isn't being searched, so it contributes no query at all.
        let memoryQuery = memoryLimit > 0 ? Self.instructed(memoryInstruction, query) : nil
        let taskQuery = taskLimit > 0 ? Self.instructed(taskInstruction, query) : nil

        let embedStart = Date()
        let vectors = try await embedDistinct([memoryQuery, taskQuery].compactMap { $0 })
        let embedMs = Int(Date().timeIntervalSince(embedStart) * 1000)

        var memoryResults: [MemorySearchResult] = []
        var memorySearchMs = 0
        if let memoryQuery {
            guard let memoryVector = vectors[memoryQuery] else {
                throw MemoryStoreError.missingMemoryQueryEmbedding
            }
            let searchStart = Date()
            memoryResults = searchMemoriesInternal(
                queryVector: memoryVector,
                queryTokens: Self.queryTokenSet(from: memoryQuery),
                limit: memoryLimit,
                threshold: threshold,
                cosineGate: memoryCosineGate
            )
            memorySearchMs = Int(Date().timeIntervalSince(searchStart) * 1000)
        }

        var taskResults: [TaskSummarySearchResult] = []
        var taskSearchMs = 0
        if let taskQuery {
            guard let taskVector = vectors[taskQuery] else {
                throw MemoryStoreError.missingTaskQueryEmbedding
            }
            let searchStart = Date()
            taskResults = searchTaskSummariesInternal(
                queryVector: taskVector,
                queryTokens: Self.queryTokenSet(from: taskQuery),
                limit: taskLimit,
                threshold: threshold,
                cosineGate: taskCosineGate,
                excludeDeleted: excludeDeletedTasks
            )
            taskSearchMs = Int(Date().timeIntervalSince(searchStart) * 1000)
        }

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

        // Embed cost is very nearly linear in the characters fed to the model, so the length is what
        // makes `embedMs` interpretable — and here the RAW query length understates it, typically by
        // about 2x. Each pool wraps the query in its own instruction preamble (`instructed`), and both
        // variants go through one batched forward pass, so the model sees the query roughly twice on
        // a two-pool search and once when a pool is switched off with a zero limit.
        let embeddedVariants = [memoryQuery, taskQuery].compactMap { $0 }
        let embeddedChars = embeddedVariants.reduce(0) { $0 + $1.count }
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        memoryStoreLogger.notice("searchAll [\(source, privacy: .public)]: \(memoryResults.count, privacy: .public) memories + \(taskResults.count, privacy: .public) tasks in \(ms, privacy: .public)ms (embed \(embedMs, privacy: .public)ms over \(embeddedChars, privacy: .public) chars in \(embeddedVariants.count, privacy: .public) variant(s), memory-scan \(memorySearchMs, privacy: .public)ms over \(self.memories.count, privacy: .public), task-scan \(taskSearchMs, privacy: .public)ms over \(self.taskSummaries.count, privacy: .public)) (query: \(query.count, privacy: .public) chars: \(query.prefix(60), privacy: .public))")
        onQueryRecorded?(MemoryQueryRecord(
            timestamp: start,
            query: query,
            memoryHits: memoryResults.count,
            taskHits: taskResults.count,
            latencyMs: ms,
            embedMs: embedMs,
            memorySearchMs: memorySearchMs,
            taskSearchMs: taskSearchMs,
            source: source
        ))
        return SemanticSearchResults(memories: memoryResults, taskSummaries: taskResults)
    }

    // MARK: - Persistence Support

    /// How far a stored vector's length may sit from 1 before it needs rescaling. Comfortably above
    /// Float32 round-off (~1e-7) and far below the ~0.4% bfloat16 error this corrects, so a properly
    /// normalized vector never trips it and a bfloat16-normalized one always does.
    private static let unitLengthTolerance = 1e-5

    /// Rescales `vector` to unit length, or returns nil when it is already unit-length (and so needs
    /// no correction) or has no length to preserve.
    ///
    /// Scoring uses `VectorMath.dotProduct` as a stand-in for cosine, which is only valid when both
    /// operands have length 1. Vectors embedded before the Float32 widening landed in the backend
    /// were normalized in bfloat16 — 7 mantissa bits, ~0.4% relative precision — so their stored
    /// lengths scatter across ±0.4% rather than sitting at 1. The resulting bias is systematic
    /// rather than noise: an entry stored at length 1.004 scores ~0.4% high against EVERY query,
    /// permanently. Accumulating in Double keeps the magnitude itself from being part of the error.
    static func renormalizedIfNeeded(_ vector: [Float]) -> [Float]? {
        let magnitude = (vector.reduce(0.0) { $0 + Double($1) * Double($1) }).squareRoot()
        guard magnitude > 1e-12, abs(magnitude - 1.0) > Self.unitLengthTolerance else { return nil }
        return vector.map { Float(Double($0) / magnitude) }
    }

    /// Restores memories and task summaries from persisted data (e.g., on app launch).
    ///
    /// Rescales any restored embedding that is not unit-length (see `renormalizedIfNeeded`). This
    /// corrects the whole persisted corpus in one pass at launch rather than re-embedding it:
    /// normalization is direction-preserving, so rescaling recovers exactly the unit vector the
    /// backend should have produced. The corrected values are deliberately NOT written back — the
    /// pass is a few hundred thousand float operations, while persisting would rewrite a
    /// multi-megabyte embedding file to change nothing a reader can observe.
    public func restore(memories: [MemoryEntry], taskSummaries: [TaskSummaryEntry]) {
        for memory in memories {
            guard let corrected = Self.renormalizedIfNeeded(memory.embedding) else {
                self.memories[memory.id] = memory
                continue
            }
            self.memories[memory.id] = MemoryEntry(
                id: memory.id, content: memory.content, embedding: corrected, source: memory.source,
                tags: memory.tags, sourceTaskID: memory.sourceTaskID, createdAt: memory.createdAt,
                lastRetrievedAt: memory.lastRetrievedAt, retrievalCount: memory.retrievalCount,
                lastInjectedAt: memory.lastInjectedAt, injectionCount: memory.injectionCount,
                lastUpdatedAt: memory.lastUpdatedAt, lastUpdatedBy: memory.lastUpdatedBy,
                embeddingModelID: memory.embeddingModelID
            )
        }
        for summary in taskSummaries {
            guard let corrected = Self.renormalizedIfNeeded(summary.embedding) else {
                self.taskSummaries[summary.id] = summary
                continue
            }
            self.taskSummaries[summary.id] = TaskSummaryEntry(
                id: summary.id, title: summary.title, summary: summary.summary,
                embeddingSourceText: summary.embeddingSourceText, embedding: corrected,
                status: summary.status, taskCreatedAt: summary.taskCreatedAt,
                createdAt: summary.createdAt, embeddingModelID: summary.embeddingModelID
            )
        }
    }

    /// Removes all memories and task summaries.
    public func clear() {
        memories.removeAll()
        taskSummaries.removeAll()
        memoryTokenCache.removeAll()
        taskSummaryTokenCache.removeAll()
        onChange?()
    }
}
