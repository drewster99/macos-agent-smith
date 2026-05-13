import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import os

private let downscalerLogger = Logger(subsystem: "com.agentsmith", category: "ImageDownscaler")

/// Downsamples image bytes to a maximum long-edge dimension before they go to an LLM.
/// Used by the seed-Brown briefing path and `view_attachment` so that user-attached
/// photos don't burn 4K worth of vision tokens when the question is "what country is
/// this flag." Output preserves the input MIME family (PNG → PNG, JPEG → JPEG) except
/// HEIC/HEIF/TIFF/BMP, which are re-encoded to JPEG because not every provider accepts
/// those formats in their image content blocks.
///
/// - Operates synchronously on bytes; no filesystem touch. Caller is responsible for
///   loading the original Data and persisting any downscaled variant.
/// - If the source is already smaller than `maxLongEdge` AND already in a
///   provider-friendly format, the original Data is returned unchanged (cheap fast path).
/// - On any decode/encode failure the original Data is returned, with the error logged.
///   Better to ship the unscaled original than to silently drop the user's attachment.
enum ImageDownscaler {

    /// Default long-edge dimension in pixels. 1024 hits Anthropic's ~1568px sweet spot
    /// without going overboard, and matches OpenAI's ~768x2000 patch budget without
    /// exceeding the multi-patch threshold. Configurable per call.
    static let defaultMaxLongEdge: Int = 1024

    /// MIME types that need re-encoding because at least one major provider rejects them.
    /// Anthropic accepts only image/jpeg, image/png, image/gif, image/webp; OpenAI similar.
    /// HEIC/HEIF/TIFF/BMP get re-encoded to JPEG; everything else stays in its native format.
    private static let mustReencodeMimeTypes: Set<String> = [
        "image/heic",
        "image/heif",
        "image/tiff",
        "image/bmp",
        "image/x-bmp"
    ]

    /// MIME types every major vision-capable provider accepts in image content blocks.
    /// Used by `isProviderInjectable` so callers know whether the bytes/mime returned by
    /// `downscale(...)` are safe to put into an `image` content block. Anything outside
    /// this set should fall back to a markdown-link reference rather than risking a
    /// tool/API rejection.
    static let providerInjectableMimeTypes: Set<String> = [
        "image/jpeg",
        "image/png",
        "image/gif",
        "image/webp"
    ]

    /// Returns true when the given mime type is in `providerInjectableMimeTypes`. The
    /// canonical check before injecting bytes into an LLM image content block.
    static func isProviderInjectable(mimeType: String) -> Bool {
        providerInjectableMimeTypes.contains(mimeType.lowercased())
    }

    /// Returns the (possibly resized) image bytes plus the resulting MIME type.
    ///
    /// - Parameters:
    ///   - data: original image bytes
    ///   - maxLongEdge: maximum long-edge dimension in pixels; pass nil to skip resize
    ///     and only handle the format-conversion fast path
    ///   - sourceMimeType: best-known MIME for the source (used to pick the output
    ///     encoder and to detect whether a re-encode is required)
    /// - Returns: `(Data, String)` where the first element is the encoded bytes and the
    ///   second is the MIME type those bytes are encoded as. On any error returns
    ///   `(data, sourceMimeType)` so the caller still has something to ship.
    static func downscale(
        _ data: Data,
        maxLongEdge: Int? = defaultMaxLongEdge,
        sourceMimeType: String
    ) -> (data: Data, mimeType: String) {
        // Fast path: image is small enough AND in a provider-friendly format → no work.
        let mustReencode = mustReencodeMimeTypes.contains(sourceMimeType.lowercased())
        if !mustReencode, let maxLongEdge {
            if let dims = readDimensions(from: data), max(dims.width, dims.height) <= maxLongEdge {
                return (data, sourceMimeType)
            }
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            downscalerLogger.error("CGImageSource creation failed for \(sourceMimeType, privacy: .public); returning original bytes")
            return (data, sourceMimeType)
        }

        // Decode an image at the requested size using the thumbnail API. CG handles
        // EXIF rotation automatically when kCGImageSourceCreateThumbnailWithTransform is set,
        // and ALWAYS produces an image (the transform option enables fallback to full decode).
        let cgImage: CGImage?
        if let maxLongEdge {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxLongEdge
            ]
            cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary)
        } else {
            cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }

        guard let cgImage else {
            downscalerLogger.error("CGImage decode failed for \(sourceMimeType, privacy: .public); returning original bytes")
            return (data, sourceMimeType)
        }

        // Pick output encoder. PNG stays PNG (preserves transparency for app icons,
        // diagrams). JPEG and unknown sources go to JPEG (smaller, universal). HEIC/TIFF/BMP
        // are forced to JPEG because providers reject them.
        let (outputUTI, outputMime, outputOptions): (CFString, String, [CFString: Any]) = {
            let lower = sourceMimeType.lowercased()
            if lower == "image/png" {
                return (UTType.png.identifier as CFString, "image/png", [:])
            }
            if lower == "image/gif" {
                // GIF stays GIF only at the format-conversion fast path; once decoded,
                // re-encoding GIF is rarely worth it (loses animation). For downscaled
                // output we ship JPEG. Animation is not common in user attachments.
                return (UTType.jpeg.identifier as CFString, "image/jpeg",
                        [kCGImageDestinationLossyCompressionQuality: 0.85])
            }
            if lower == "image/webp" {
                return (UTType.webP.identifier as CFString, "image/webp",
                        [kCGImageDestinationLossyCompressionQuality: 0.85])
            }
            // Default: JPEG. Covers JPEG, HEIC, HEIF, TIFF, BMP, and any unknown.
            return (UTType.jpeg.identifier as CFString, "image/jpeg",
                    [kCGImageDestinationLossyCompressionQuality: 0.85])
        }()

        let outputData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            outputData, outputUTI, 1, nil
        ) else {
            downscalerLogger.error("CGImageDestination creation failed for \(outputMime, privacy: .public); returning original bytes")
            return (data, sourceMimeType)
        }
        CGImageDestinationAddImage(destination, cgImage, outputOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            downscalerLogger.error("CGImageDestination finalize failed for \(outputMime, privacy: .public); returning original bytes")
            return (data, sourceMimeType)
        }

        return (outputData as Data, outputMime)
    }

    /// Reads pixel dimensions from image bytes without decoding the full image. Returns
    /// nil if the source can't be parsed. Used by the fast path to skip resize work
    /// when the image is already small enough.
    private static func readDimensions(from data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        let width = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let height = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }
}
