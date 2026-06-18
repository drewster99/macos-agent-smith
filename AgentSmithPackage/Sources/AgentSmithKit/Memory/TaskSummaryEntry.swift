import Foundation

/// An LLM-generated summary of a completed or failed task, embedded for semantic search.
///
/// `embedding` is a single L2-normalized `[Float]` vector; legacy on-disk shapes
/// (`[[Double]]`, `[Double]`) decode to an empty array and disable the semantic-similarity
/// contribution for that summary rather than failing the whole-array decode in persistence.
/// `embeddingSourceText` falls back to the empty string if absent in a legacy record.
public struct TaskSummaryEntry: Codable, Identifiable, Sendable {
    /// Matches the `AgentTask.id` this summary was generated from.
    public let id: UUID
    /// The task's title at completion time.
    public let title: String
    /// LLM-generated summary covering problem, outcome, and approach.
    public let summary: String
    /// Composite text used for generating the embedding vector.
    /// Includes title, description, summary, result, commentary, and updates.
    public let embeddingSourceText: String
    /// Single L2-normalized embedding vector for `embeddingSourceText`.
    public let embedding: [Float]
    /// Whether the task completed successfully or failed.
    public let status: AgentTask.Status
    /// When the *task* was originally created (taken from `AgentTask.createdAt`).
    /// This is the date users care about — the moment they asked for the work to be done.
    public let taskCreatedAt: Date
    /// When the *summary* was generated (after the task ran). Distinct from `taskCreatedAt`
    /// because a long-running task can be created days before its summary is written.
    public let createdAt: Date

    /// The embedding model/scheme signature (`SemanticSearchEngine.model.identifier`) that produced
    /// `embedding`. `nil` for summaries saved before this field existed; a mismatch with the current
    /// engine identifier on load means the vector is stale and gets re-embedded.
    public let embeddingModelID: String?

    public init(
        id: UUID,
        title: String,
        summary: String,
        embeddingSourceText: String,
        embedding: [Float],
        status: AgentTask.Status,
        taskCreatedAt: Date,
        createdAt: Date = Date(),
        embeddingModelID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.embeddingSourceText = embeddingSourceText
        self.embedding = embedding
        self.status = status
        self.taskCreatedAt = taskCreatedAt
        self.createdAt = createdAt
        self.embeddingModelID = embeddingModelID
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, summary, embeddingSourceText, embedding, status, taskCreatedAt, createdAt, embeddingModelID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        summary = try c.decode(String.self, forKey: .summary)
        embeddingSourceText = try c.decodeIfPresent(String.self, forKey: .embeddingSourceText) ?? ""
        embedding = (try? c.decode([Float].self, forKey: .embedding)) ?? []
        status = try c.decode(AgentTask.Status.self, forKey: .status)
        taskCreatedAt = try c.decode(Date.self, forKey: .taskCreatedAt)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        embeddingModelID = try c.decodeIfPresent(String.self, forKey: .embeddingModelID)
    }
}
