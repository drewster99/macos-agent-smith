import Foundation
import os

private let attachmentRegistryLogger = Logger(subsystem: "com.agentsmith", category: "AttachmentRegistry")

/// Per-session lookup of every `Attachment` the system has seen — by ID. Populated when:
///
/// 1. The user sends a message with attachments (`OrchestrationRuntime.sendUserMessage`).
/// 2. A task is created or updated with attachments (via the registry-aware tools).
/// 3. Brown ingests a local file by path (`ingestFile(path:)`).
///
/// Tools resolve raw `attachment_ids` strings from LLM tool-call arguments back to live
/// `Attachment` records via `resolve(_:)`. The registry also lazy-loads file bytes from the
/// per-session attachments directory when an `Attachment.data` field is nil — important
/// when an attachment is referenced by a Brown spawned in a fresh process for a resumed
/// task and the bytes weren't carried in memory.
///
/// **Persistence model.** Bytes are stored per-session under
/// `AppSupport/AgentSmith/sessions/<sessionID>/attachments/<id>_<filename>`. `Attachment`
/// itself excludes `data` from Codable, so persisted task records carry only metadata —
/// the registry rehydrates the bytes on demand.
actor AttachmentRegistry {
    /// Closure that loads attachment bytes from the per-session disk store. Provided by
    /// the runtime so the registry doesn't have to know about `PersistenceManager` directly
    /// (keeps `AgentSmithKit` testable in isolation). Async because the underlying
    /// PersistenceManager is an actor.
    private let loader: @Sendable (UUID, String) async -> Data?
    /// Closure that persists attachment bytes to the per-session disk store. Same rationale.
    private let saver: @Sendable (Attachment) async throws -> Void
    /// Closure that returns the canonical on-disk URL for an attachment (whether or not
    /// the file exists). Used by `urlFor(_:)` to build `file://` references for LLM-facing
    /// markdown links. Optional — when nil, `urlFor(_:)` returns nil and callers should
    /// degrade gracefully.
    private let urlProvider: (@Sendable (UUID, String) async -> URL?)?
    /// Default maximum byte count for a file ingested via `ingestFile(path:)`. Used when
    /// no explicit cap has been wired through the runtime. Matches the soft cap used on
    /// the user-side attachment picker.
    static let defaultMaxIngestBytes = 25 * 1024 * 1024

    /// Per-file ingestion cap. Defaults to `defaultMaxIngestBytes` but can be overridden
    /// via `setMaxIngestBytes(_:)` to surface the user's Settings preference. Files larger
    /// than this are rejected before bytes hit memory.
    private var maxIngestBytes: Int = defaultMaxIngestBytes

    private var byID: [UUID: Attachment] = [:]

    init(
        loader: @escaping @Sendable (UUID, String) async -> Data?,
        saver: @escaping @Sendable (Attachment) async throws -> Void,
        urlProvider: (@Sendable (UUID, String) async -> URL?)? = nil
    ) {
        self.loader = loader
        self.saver = saver
        self.urlProvider = urlProvider
    }

    /// Returns the canonical on-disk URL for an attachment, if a URL provider was
    /// configured at registry construction. Used by the briefing builder to surface
    /// `file://` references. Nil if no provider is wired (tests, in-memory contexts).
    func urlFor(_ attachment: Attachment) async -> URL? {
        await urlProvider?(attachment.id, attachment.filename)
    }

    /// Overrides the per-file ingest cap. Called by the runtime when the app layer's
    /// settings (`SharedAppState.maxAttachmentBytesPerFile`) change. Defaults are kept
    /// generous; callers tightening the cap should pass a sensible floor.
    func setMaxIngestBytes(_ bytes: Int) {
        maxIngestBytes = max(0, bytes)
    }

    /// Returns the active per-file cap. Surfaced for tool-side aggregate-budget
    /// enforcement so `attachment_paths` can pre-validate before kicking off a slow
    /// ingest pipeline.
    func currentMaxIngestBytes() -> Int { maxIngestBytes }

    /// Registers an attachment so subsequent lookups by `id` return it. Idempotent — if
    /// the same ID is already known, the existing record wins (so a later registration
    /// without bytes doesn't overwrite a cached record that already has them).
    func register(_ attachment: Attachment) {
        if let existing = byID[attachment.id], existing.data != nil, attachment.data == nil {
            return
        }
        byID[attachment.id] = attachment
    }

    /// Bulk-register a list of attachments.
    func register(contentsOf attachments: [Attachment]) {
        for attachment in attachments { register(attachment) }
    }

    /// Returns the attachment with the given ID, lazy-loading its file bytes if needed.
    /// Returns nil when the ID is unknown OR the file bytes are missing on disk.
    func resolve(_ id: UUID) async -> Attachment? {
        guard var attachment = byID[id] else { return nil }
        if attachment.data == nil {
            attachment.data = await loader(attachment.id, attachment.filename)
            byID[id] = attachment
        }
        return attachment
    }

    /// Resolves a list of UUID strings to `[Attachment]`, dropping any unknown / unloadable
    /// IDs. Returns the resolved set plus any rejected ID strings (for tool error messages).
    func resolve(idStrings: [String]) async -> (resolved: [Attachment], rejected: [String]) {
        var ok: [Attachment] = []
        var rejected: [String] = []
        for raw in idStrings {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let uuid = UUID(uuidString: trimmed), let attachment = await resolve(uuid) else {
                rejected.append(raw)
                continue
            }
            ok.append(attachment)
        }
        return (ok, rejected)
    }

    /// Reads a file from disk, mints a fresh `Attachment` with a new ID, persists the bytes
    /// to the per-session attachments dir, and registers it. Used by Brown's `task_update`
    /// and `task_complete` to attach freshly-produced output files.
    ///
    /// On failure, returns an `IngestError` describing why — the caller surfaces the
    /// reason as a tool result so the LLM can correct.
    func ingestFile(path: String) async -> Result<Attachment, IngestError> {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .failure(.fileNotFound(path))
        }
        if isDirectory.boolValue {
            return .failure(.isDirectory(path))
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        if size > maxIngestBytes {
            return .failure(.tooLarge(path: path, size: size, max: maxIngestBytes))
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .failure(.readFailed(path: path, message: error.localizedDescription))
        }

        let mimeType = Self.mimeType(forPathExtension: url.pathExtension)
        let attachment = Attachment(
            filename: url.lastPathComponent,
            mimeType: mimeType,
            byteCount: data.count,
            data: data
        )

        do {
            try await saver(attachment)
        } catch {
            attachmentRegistryLogger.error("ingestFile saver failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .failure(.persistFailed(path: path, message: error.localizedDescription))
        }

        register(attachment)
        return .success(attachment)
    }

    /// Best-effort MIME type from the file extension. Falls back to
    /// `application/octet-stream` so the attachment is still valid (Smith/Brown's view code
    /// can render it as a generic file). Image/PDF MIME types are detected so the LLM
    /// pipeline injects them as image/document content rather than text refs.
    static func mimeType(forPathExtension ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        case "pdf": return "application/pdf"
        case "txt", "log": return "text/plain"
        case "md", "markdown": return "text/markdown"
        case "json": return "application/json"
        case "csv": return "text/csv"
        case "html", "htm": return "text/html"
        case "xml": return "application/xml"
        case "zip": return "application/zip"
        default: return "application/octet-stream"
        }
    }

    enum IngestError: Error, Sendable, Equatable {
        case fileNotFound(String)
        case isDirectory(String)
        case tooLarge(path: String, size: Int, max: Int)
        case readFailed(path: String, message: String)
        case persistFailed(path: String, message: String)

        var description: String {
            switch self {
            case .fileNotFound(let p):
                return "File not found: \(p)"
            case .isDirectory(let p):
                return "Path is a directory, not a file: \(p)"
            case .tooLarge(let p, let s, let m):
                return "File too large to attach (\(p): \(s) bytes; max \(m) bytes)."
            case .readFailed(let p, let m):
                return "Failed to read \(p): \(m)"
            case .persistFailed(let p, let m):
                return "Failed to persist \(p) into the per-session attachments directory: \(m)"
            }
        }
    }
}
