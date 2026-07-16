import Foundation
import ImageIO
import PDFKit
import os

/// Strips passive injection channels from attachment bytes at INGEST time (once), before they are
/// persisted to the pool and later sent to any model: an image's EXIF/GPS/IPTC/XMP metadata and a
/// PDF's document-info dictionary. A prompt-injection payload ("ignore prior instructions…") hidden
/// in EXIF or a PDF `/Title` never reaches the LLM. Fail-safe: any decode/re-encode failure returns
/// the ORIGINAL bytes unchanged, so this is never worse than not sanitizing.
///
/// This closes only the METADATA channel. Injection in an image's visible PIXELS or a PDF's body
/// text is out of scope here — that is the Security-side content-inspection path and, ultimately,
/// the full path-safety pass (see ROADMAP).
enum AttachmentSanitizer {
    private static let logger = Logger(subsystem: "AgentSmithKit", category: "AttachmentSanitizer")

    /// Returns sanitized bytes for a known image/PDF mime type, or the original bytes for any other
    /// type (or on any failure).
    static func sanitize(_ data: Data, mimeType: String) -> Data {
        guard !data.isEmpty else { return data }
        let lower = mimeType.lowercased()
        if lower.hasPrefix("image/") {
            return stripImageMetadata(data)
        }
        if lower == "application/pdf" {
            return stripPDFMetadata(data)
        }
        return data
    }

    /// Drops ALL image metadata (EXIF / GPS / IPTC / XMP / TIFF) by decoding the pixels and
    /// re-encoding them with no properties dictionary. A lossless `CopyImageSource` copy only
    /// removes the XMP container, leaving EXIF/TIFF (where a payload can hide) intact — so a real
    /// re-encode is required. For JPEG this is a high-quality (0.95) re-compression that is visually
    /// negligible; PNG and other lossless formats stay lossless. Returns the original bytes if the
    /// data isn't a decodable image.
    static func stripImageMetadata(_ data: Data) -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return data
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else {
            return data
        }
        // No properties beyond compression quality → the encoder writes only the pixels, so every
        // metadata dictionary is dropped.
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length > 0 else {
            return data
        }
        return output as Data
    }

    /// Clears a PDF's document-info dictionary (Title / Author / Subject / Keywords / Creator /
    /// Producer), where free-text metadata could carry an injection payload. Returns the original
    /// bytes if the data isn't a valid PDF. Does NOT yet flatten embedded JavaScript / annotations —
    /// that deeper sanitization is part of the planned full path-safety pass (see ROADMAP).
    static func stripPDFMetadata(_ data: Data) -> Data {
        guard let document = PDFDocument(data: data) else { return data }
        document.documentAttributes = [:]
        guard let output = document.dataRepresentation(), !output.isEmpty else { return data }
        return output
    }
}
