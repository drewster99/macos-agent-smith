import Foundation

/// A piece of knowledge saved by an agent or the user for future semantic retrieval.
///
/// `embedding` is a single L2-normalized `[Float]` vector. Older on-disk JSON used either
/// `[[Double]]` (multi-vector) or `[Double]` (single-double) shapes — those decode to an
/// empty `[Float]` here, which `MemoryStore` treats as "fall back to keyword-only scoring."
/// This is preferable to throwing `typeMismatch`, which would abort the whole-array decode
/// in persistence and lose every memory in the corpus.
public struct MemoryEntry: Codable, Identifiable, Sendable {
    public let id: UUID
    /// The textual content of the memory.
    public let content: String
    /// Single L2-normalized embedding vector for the memory's content.
    public let embedding: [Float]
    /// Who created this memory.
    public let source: Source
    /// Optional categorization tags.
    public let tags: [String]
    /// The task that was active when this memory was saved, if any.
    public let sourceTaskID: UUID?
    /// When this memory was originally saved.
    public let createdAt: Date

    /// Set the most recent time an agent-driven search retrieved this memory and used it
    /// (i.e. it appeared in `searchAll` results consumed by a tool or auto-context inject).
    /// `nil` if the memory has never been retrieved by an agent. Browsing in the Memory
    /// editor does NOT update this field.
    public var lastRetrievedAt: Date?

    /// Total number of times an agent-driven search has retrieved this memory. Same scoping
    /// as `lastRetrievedAt` — editor browsing does not increment this.
    public var retrievalCount: Int

    /// Set the most recent time the memory's content or tags were edited. `nil` if the
    /// memory has never been modified since creation.
    public var lastUpdatedAt: Date?

    /// Who performed the most recent edit. `nil` if never edited.
    public var lastUpdatedBy: UpdateSource?

    /// The embedding model/scheme signature (`SemanticSearchEngine.model.identifier`) that produced
    /// `embedding`. `nil` for entries saved before this field existed. On load, an entry whose value
    /// differs from the current engine identifier is stale and gets re-embedded.
    public var embeddingModelID: String?

    /// Text used for BOTH the semantic embedding and the lexical (keyword) search document: the
    /// content plus the tag words, so a query can match a memory by its tags as well as its content.
    /// Tags are appended as plain words (no "Tags:" label) so the tokenizer sees the tag terms
    /// without injecting a noise token that every tagged memory would then share.
    public var embeddingSourceText: String {
        Self.embeddingSourceText(content: content, tags: tags)
    }

    /// Free-function form so callers can build the embedding input before an entry exists.
    public static func embeddingSourceText(content: String, tags: [String]) -> String {
        tags.isEmpty ? content : content + "\n" + tags.joined(separator: " ")
    }

    /// Who originated the memory at save time.
    public enum Source: String, Codable, Sendable {
        case user
        case smith
        case brown
    }

    /// Who performed an edit on an existing memory.
    public enum UpdateSource: String, Codable, Sendable {
        /// Edited by the user via the Memory editor.
        case user
        /// Edited automatically by the system — currently only via `SaveMemoryTool` consolidation.
        case system
    }

    public init(
        id: UUID = UUID(),
        content: String,
        embedding: [Float],
        source: Source,
        tags: [String] = [],
        sourceTaskID: UUID? = nil,
        createdAt: Date = Date(),
        lastRetrievedAt: Date? = nil,
        retrievalCount: Int = 0,
        lastUpdatedAt: Date? = nil,
        lastUpdatedBy: UpdateSource? = nil,
        embeddingModelID: String? = nil
    ) {
        self.id = id
        self.content = content
        self.embedding = embedding
        self.source = source
        self.tags = tags
        self.sourceTaskID = sourceTaskID
        self.createdAt = createdAt
        self.lastRetrievedAt = lastRetrievedAt
        self.retrievalCount = retrievalCount
        self.lastUpdatedAt = lastUpdatedAt
        self.lastUpdatedBy = lastUpdatedBy
        self.embeddingModelID = embeddingModelID
    }

    private enum CodingKeys: String, CodingKey {
        case id, content, embedding, source, tags, sourceTaskID, createdAt
        case lastRetrievedAt, retrievalCount, lastUpdatedAt, lastUpdatedBy, embeddingModelID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        content = try c.decode(String.self, forKey: .content)
        embedding = Self.decodeEmbedding(container: c)
        source = try c.decode(Source.self, forKey: .source)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        sourceTaskID = try c.decodeIfPresent(UUID.self, forKey: .sourceTaskID)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastRetrievedAt = try c.decodeIfPresent(Date.self, forKey: .lastRetrievedAt)
        retrievalCount = try c.decodeIfPresent(Int.self, forKey: .retrievalCount) ?? 0
        lastUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .lastUpdatedAt)
        lastUpdatedBy = try c.decodeIfPresent(UpdateSource.self, forKey: .lastUpdatedBy)
        embeddingModelID = try c.decodeIfPresent(String.self, forKey: .embeddingModelID)
    }

    /// Decodes `embedding`, tolerating legacy `[[Double]]` (multi-vector) and `[Double]`
    /// (single-vector double) shapes by returning an empty `[Float]`. Empty embeddings
    /// disable the semantic-similarity contribution for the entry but keep keyword search
    /// intact — much better than throwing a typeMismatch and losing the entry entirely.
    private static func decodeEmbedding(container c: KeyedDecodingContainer<CodingKeys>) -> [Float] {
        (try? c.decode([Float].self, forKey: .embedding)) ?? []
    }
}
