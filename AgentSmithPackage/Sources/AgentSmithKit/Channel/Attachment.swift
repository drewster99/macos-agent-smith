import Foundation

/// A file attachment on a channel message. Supports any media type.
/// File data is stored separately on disk; only metadata is persisted in the message JSON.
///
/// Bytes live in the per-session attachments directory managed by `PersistenceManager`.
/// Use `AttachmentRegistry.resolve(_:)` to look up an attachment by ID and lazy-load its
/// bytes — that's the only correct path. The previous static `loadPersistedData(id:filename:)`
/// helper was removed because it pointed at a legacy global directory that no longer
/// receives writes (per-session migration retired the global path).
public struct Attachment: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var filename: String
    public var mimeType: String
    public var byteCount: Int

    /// In-memory file data. Excluded from Codable — persisted separately by PersistenceManager.
    public var data: Data?

    private enum CodingKeys: String, CodingKey {
        case id, filename, mimeType, byteCount
    }

    public init(
        id: UUID = UUID(),
        filename: String,
        mimeType: String,
        byteCount: Int,
        data: Data? = nil
    ) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.data = data
    }

    /// Whether the LLM can process this as an image.
    public var isImage: Bool {
        mimeType.hasPrefix("image/")
    }

    /// Whether the LLM can process this as a PDF document.
    public var isPDF: Bool {
        mimeType == "application/pdf"
    }

    /// Human-readable file size.
    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }
}
