import AppKit
import ImageIO
import AgentSmithKit
import os

nonisolated private let imageCacheLogger = Logger(subsystem: "com.agentsmith", category: "ImageCache")

/// Tiered image cache with efficient thumbnail generation via ImageIO.
/// RAM cache for all tiers; disk cache (JPEG) for chip and small thumbnails
/// stored in the system Caches directory so the OS can reclaim space.
@MainActor
final class ImageCache {
    /// Shared singleton used by all views.
    static let shared = ImageCache()

    /// The maximum pixel dimension for each display tier.
    enum Tier: String, CaseIterable, Sendable {
        case chip   = "chip"    // 32pt square matte in the input bar
        case small  = "small"   // ~120pt for user-sent message images
        case medium = "medium"  // ~400pt for received message images
        case full   = "full"    // original resolution

        var maxPixelDimension: CGFloat {
            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            switch self {
            case .chip:   return 32 * scale
            case .small:  return 120 * scale
            case .medium: return 400 * scale
            case .full:   return 0  // no downscaling
            }
        }
    }

    // MARK: - RAM cache

    /// Key: "<attachmentID>-<tier>" -> NSImage
    private let ramCache = NSCache<NSString, NSImage>()

    // MARK: - Disk cache

    private let thumbnailDirectory: URL

    /// Maximum total size of the disk thumbnail cache (100 MB).
    private nonisolated static let maxDiskCacheBytes: UInt64 = 100 * 1024 * 1024

    // MARK: - Init

    private init() {
        let baseDir: URL
        if let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            baseDir = cachesDir
        } else {
            baseDir = FileManager.default.temporaryDirectory
            imageCacheLogger.error("Caches directory unavailable; falling back to temporaryDirectory for the thumbnail cache")
        }
        thumbnailDirectory = baseDir
            .appendingPathComponent("AgentSmith", isDirectory: true)
            .appendingPathComponent("thumbnails", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: thumbnailDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            imageCacheLogger.error("Failed to create thumbnail cache directory: \(error.localizedDescription, privacy: .public)")
        }

        // Evict oldest thumbnails if the cache exceeds the size limit.
        Task.detached(priority: .utility) { [thumbnailDirectory] in
            Self.evictIfNeeded(directory: thumbnailDirectory)
        }
    }

    // MARK: - Public API

    /// Returns an image for the given attachment and tier.
    /// Checks the RAM cache synchronously first; on miss, loads from disk or
    /// generates a thumbnail off the main thread.
    ///
    /// `bytesLoader` is a closure that resolves the attachment's bytes from disk when the
    /// in-memory `Attachment.data` is nil. Production callers wire this to the session's
    /// `PersistenceManager.loadAttachmentData(id:filename:)`. When omitted, only attachments
    /// with eagerly-loaded `.data` are renderable — the session-restored case (where the
    /// metadata is in memory but the bytes are on disk) returns nil. UI callers should
    /// prefer the loader form so missing bytes don't silently render as blank space.
    func image(
        for attachment: Attachment,
        tier: Tier,
        bytesLoader: (@Sendable (UUID, String) async -> Data?)? = nil
    ) async -> NSImage? {
        let cacheKey = NSString(string: "\(attachment.id.uuidString)-\(tier.rawValue)")

        // 1. RAM cache hit (synchronous, no I/O)
        if let cached = ramCache.object(forKey: cacheKey) {
            return cached
        }

        // 2. Heavy work off main actor: disk lookup, source read, thumbnail gen.
        // Captured locals (Sendable) so the detached task isn't bridged to MainActor.
        let maxDimension = tier.maxPixelDimension
        let diskURL = (tier == .chip || tier == .small)
            ? diskCacheURL(attachmentID: attachment.id, tier: tier)
            : nil
        let attachmentData = attachment.data
        let isFull = tier == .full
        let attachmentID = attachment.id
        let attachmentFilename = attachment.filename

        let result: NSImage? = await Task.detached(priority: .userInitiated) {
            // Disk cache hit (chip and small only) short-circuits before any source-byte
            // load — important because chip/small are the hot path in the channel
            // transcript and reloading 200KB images on every scroll is wasteful.
            if let url = diskURL,
               FileManager.default.fileExists(atPath: url.path),
               let diskImage = NSImage(contentsOf: url) {
                return diskImage
            }

            // Source bytes: in-memory first, then via the session-aware loader. The
            // loader is @Sendable + async; PersistenceManager is an actor so its own
            // isolation handles thread-safety.
            let sourceData: Data?
            if let attachmentData {
                sourceData = attachmentData
            } else if let bytesLoader {
                sourceData = await bytesLoader(attachmentID, attachmentFilename)
            } else {
                sourceData = nil
            }

            guard let sourceData else {
                imageCacheLogger.error("ImageCache: attachment \(attachmentID.uuidString, privacy: .public) bytes unavailable (filename=\(attachmentFilename, privacy: .public)) — UI will render placeholder")
                return nil
            }

            if isFull {
                return NSImage(data: sourceData)
            } else {
                return Self.generateThumbnail(from: sourceData, maxDimension: maxDimension)
            }
        }.value

        guard let image = result else { return nil }

        ramCache.setObject(image, forKey: cacheKey)

        // 3. Persist chip and small to disk in the background
        if let url = diskURL {
            Task.detached(priority: .utility) {
                Self.writeToDisk(image: image, url: url)
            }
        }

        return image
    }

    /// Returns the image only if it is already in the RAM cache (no I/O).
    func cachedImage(for attachment: Attachment, tier: Tier) -> NSImage? {
        let cacheKey = NSString(string: "\(attachment.id.uuidString)-\(tier.rawValue)")
        return ramCache.object(forKey: cacheKey)
    }

    /// Pre-warms the cache for a set of attachments at a given tier.
    /// Yields between items so the UI remains responsive.
    func preload(_ attachments: [Attachment], tier: Tier) async {
        for attachment in attachments where attachment.isImage {
            _ = await image(for: attachment, tier: tier)
            await Task.yield()
        }
    }

    // MARK: - Thumbnail generation via ImageIO

    /// Efficiently generates a downsampled thumbnail without decoding the full image.
    /// This method is nonisolated so it can run on a background thread.
    private nonisolated static func generateThumbnail(
        from data: Data,
        maxDimension: CGFloat
    ) -> NSImage? {
        guard maxDimension > 0 else { return nil }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }

        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }

    // MARK: - Disk persistence

    private func diskCacheURL(attachmentID: UUID, tier: Tier) -> URL {
        thumbnailDirectory.appendingPathComponent("\(attachmentID.uuidString)-\(tier.rawValue).jpg")
    }

    /// Writes a thumbnail to disk as JPEG (much smaller than PNG for photographic content).
    private nonisolated static func writeToDisk(image: NSImage, url: URL) {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(
                  using: .jpeg,
                  properties: [.compressionFactor: 0.8]
              )
        else { return }
        do {
            try jpegData.write(to: url, options: .atomic)
        } catch {
            imageCacheLogger.error("Failed to write thumbnail to disk: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Cache eviction

    /// Deletes the oldest thumbnails until total size is under `maxDiskCacheBytes`.
    private nonisolated static func evictIfNeeded(directory: URL) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return }

        struct CacheEntry {
            let url: URL
            let size: UInt64
            let modified: Date
        }

        var entries: [CacheEntry] = []
        var totalSize: UInt64 = 0

        for case let fileURL as URL in enumerator {
            let values: URLResourceValues
            do {
                values = try fileURL.resourceValues(
                    forKeys: [.fileSizeKey, .contentModificationDateKey]
                )
            } catch {
                imageCacheLogger.error("Failed to read cache entry metadata: \(error.localizedDescription, privacy: .public)")
                continue
            }
            let size = UInt64(values.fileSize ?? 0)
            let modified = values.contentModificationDate ?? .distantPast
            entries.append(CacheEntry(url: fileURL, size: size, modified: modified))
            totalSize += size
        }

        guard totalSize > maxDiskCacheBytes else { return }

        // Sort oldest first
        entries.sort { $0.modified < $1.modified }

        for entry in entries {
            guard totalSize > maxDiskCacheBytes else { break }
            do {
                try fm.removeItem(at: entry.url)
                totalSize -= entry.size
            } catch {
                imageCacheLogger.error("Failed to evict cached thumbnail: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
