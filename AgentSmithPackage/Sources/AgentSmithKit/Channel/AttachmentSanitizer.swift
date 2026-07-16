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

    /// Re-encodes an image dropping the metadata sub-dictionaries that can carry an injection payload
    /// (EXIF / GPS / IPTC / TIFF free-text / maker notes; XMP rides a separate `CGImageMetadata`
    /// object that a plain `AddImage` never copies, so it is dropped implicitly). STRUCTURAL
    /// properties — orientation, dimensions, colour, and each format's frame-timing / loop-count
    /// dictionaries — are carried forward, so a multi-frame image (animated GIF / APNG / HEICS /
    /// multi-page TIFF) keeps every frame and its timing rather than being flattened. Returns the
    /// original bytes if the data isn't a decodable image or the format can't be re-encoded.
    static func stripImageMetadata(_ data: Data) -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) else {
            return data
        }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0 else { return data }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type, frameCount, nil) else {
            return data
        }
        // Container-level structural properties (e.g. a GIF's loop count) minus the metadata dicts.
        if let container = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] {
            CGImageDestinationSetProperties(destination, withoutMetadata(container) as CFDictionary)
        }
        for index in 0..<frameCount {
            guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil) else { return data }
            let frameProperties = (CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]) ?? [:]
            CGImageDestinationAddImage(destination, frame, withoutMetadata(frameProperties) as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination), output.length > 0 else {
            return data
        }
        return output as Data
    }

    /// Sub-dictionaries that hold free-text / camera / location metadata — the passive injection
    /// channels. Removed before re-encode; every other (structural) key is kept.
    /// `nonisolated(unsafe)`: an immutable array of compile-time-constant ImageIO CFString globals.
    private nonisolated(unsafe) static let metadataDictionaryKeys: [CFString] = [
        kCGImagePropertyExifDictionary,
        kCGImagePropertyExifAuxDictionary,
        kCGImagePropertyGPSDictionary,
        kCGImagePropertyIPTCDictionary,
        kCGImagePropertyTIFFDictionary,
        kCGImagePropertyMakerAppleDictionary,
        kCGImagePropertyMakerCanonDictionary,
        kCGImagePropertyMakerNikonDictionary,
        kCGImagePropertyMakerMinoltaDictionary,
        kCGImagePropertyMakerFujiDictionary,
        kCGImagePropertyMakerOlympusDictionary,
        kCGImagePropertyMakerPentaxDictionary,
        kCGImageProperty8BIMDictionary,
        kCGImagePropertyDNGDictionary,
        kCGImagePropertyCIFFDictionary
    ]

    private static func withoutMetadata(_ properties: [CFString: Any]) -> [CFString: Any] {
        var cleaned = properties
        for key in metadataDictionaryKeys {
            cleaned.removeValue(forKey: key)
        }
        return cleaned
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
