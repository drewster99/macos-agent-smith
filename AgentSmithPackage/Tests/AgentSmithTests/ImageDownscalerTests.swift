import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import AgentSmithKit

/// Tests for `ImageDownscaler`. Covers the four branches:
/// 1. Fast path (already small + provider-friendly) — bytes returned unchanged.
/// 2. Force re-encode (HEIC etc., decoded to JPEG even when small).
/// 3. Resize path (large image decoded and downscaled).
/// 4. Decode failure (invalid bytes) — returns input unchanged with a logged error.
@Suite("ImageDownscaler")
struct ImageDownscalerTests {

    // MARK: Helpers

    /// Builds a synthetic PNG of a given pixel size. All-red, no alpha.
    private func makePNG(width: Int, height: Int) throws -> Data {
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: bitmapInfo
        ) else {
            throw NSError(domain: "test", code: 1)
        }
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = ctx.makeImage() else {
            throw NSError(domain: "test", code: 2)
        }
        let buf = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(buf, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "test", code: 3)
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "test", code: 4)
        }
        return buf as Data
    }

    /// Reads pixel dimensions out of image bytes. Returns nil if the bytes can't be parsed
    /// as an image.
    private func dimensions(of data: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        let w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        guard w > 0, h > 0 else { return nil }
        return (w, h)
    }

    // MARK: Fast path

    @Test("small PNG passes through unchanged")
    func smallPNGFastPath() throws {
        let data = try makePNG(width: 200, height: 150)
        let result = ImageDownscaler.downscale(data, sourceMimeType: "image/png")
        #expect(result.mimeType == "image/png")
        // Same byte count = same buffer (no decode/re-encode).
        #expect(result.data.count == data.count)
    }

    @Test("small JPEG passes through unchanged")
    func smallJPEGFastPath() throws {
        // Make a PNG, then encode it as JPEG via CG to get JPEG bytes.
        let png = try makePNG(width: 100, height: 100)
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            Issue.record("could not decode test PNG")
            return
        }
        let buf = NSMutableData()
        let dest = CGImageDestinationCreateWithData(buf, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(dest)
        let jpegData = buf as Data

        let result = ImageDownscaler.downscale(jpegData, sourceMimeType: "image/jpeg")
        #expect(result.mimeType == "image/jpeg")
        #expect(result.data.count == jpegData.count)
    }

    // MARK: Resize path

    @Test("large PNG downscales to <= maxLongEdge on the long edge")
    func largePNGDownscales() throws {
        let data = try makePNG(width: 4096, height: 3072)
        let result = ImageDownscaler.downscale(data, maxLongEdge: 1024, sourceMimeType: "image/png")
        #expect(result.mimeType == "image/png")
        guard let dims = dimensions(of: result.data) else {
            Issue.record("could not read dims of downscaled output")
            return
        }
        #expect(max(dims.0, dims.1) <= 1024)
        // Output should be smaller than input — sanity check.
        #expect(result.data.count < data.count)
    }

    @Test("downscale preserves aspect ratio approximately")
    func aspectPreserved() throws {
        let data = try makePNG(width: 4000, height: 1000) // 4:1
        let result = ImageDownscaler.downscale(data, maxLongEdge: 1024, sourceMimeType: "image/png")
        guard let dims = dimensions(of: result.data) else {
            Issue.record("could not read dims")
            return
        }
        let aspect = Double(dims.0) / Double(dims.1)
        #expect(abs(aspect - 4.0) < 0.05)
    }

    // MARK: Force re-encode

    @Test("HEIC mime always goes through decode/encode (never fast-path)")
    func heicForceReencode() throws {
        // We don't have synthetic HEIC bytes handy. Take a JPEG and pretend its mime is
        // HEIC — the downscaler should still treat it as must-reencode and try to decode.
        // CG will handle JPEG-via-HEIC-mime gracefully because decode is mime-agnostic.
        let png = try makePNG(width: 100, height: 100)
        let result = ImageDownscaler.downscale(png, sourceMimeType: "image/heic")
        // Output should be JPEG because mustReencode forces JPEG output for unknown
        // source mimes — the fast path was skipped.
        #expect(result.mimeType == "image/jpeg")
    }

    // MARK: Decode failure

    @Test("invalid bytes return original data with original mime")
    func decodeFailureReturnsOriginal() {
        let bogus = Data([0x00, 0x01, 0x02, 0x03, 0x04])
        let result = ImageDownscaler.downscale(bogus, sourceMimeType: "image/svg+xml")
        // SVG can't be decoded by CG — fast path skipped (readDimensions nil),
        // CGImageSourceCreateWithData fails, fallback returns the original.
        #expect(result.mimeType == "image/svg+xml")
        #expect(result.data == bogus)
    }

    // MARK: isProviderInjectable

    @Test("provider-injectable predicate accepts JPEG/PNG/GIF/WebP only")
    func injectableSet() {
        #expect(ImageDownscaler.isProviderInjectable(mimeType: "image/jpeg"))
        #expect(ImageDownscaler.isProviderInjectable(mimeType: "image/png"))
        #expect(ImageDownscaler.isProviderInjectable(mimeType: "image/gif"))
        #expect(ImageDownscaler.isProviderInjectable(mimeType: "image/webp"))
        #expect(!ImageDownscaler.isProviderInjectable(mimeType: "image/svg+xml"))
        #expect(!ImageDownscaler.isProviderInjectable(mimeType: "image/heic"))
        #expect(!ImageDownscaler.isProviderInjectable(mimeType: "image/tiff"))
        #expect(!ImageDownscaler.isProviderInjectable(mimeType: "application/pdf"))
    }

    @Test("predicate is case-insensitive")
    func caseInsensitive() {
        #expect(ImageDownscaler.isProviderInjectable(mimeType: "IMAGE/JPEG"))
        #expect(ImageDownscaler.isProviderInjectable(mimeType: "Image/Png"))
    }
}
