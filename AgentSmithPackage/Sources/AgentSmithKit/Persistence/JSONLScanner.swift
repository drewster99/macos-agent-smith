import Foundation

/// The result of one forward pass over a JSONL file.
struct JSONLScan: Sendable, Equatable {
    /// Non-empty line count — identical to what
    /// `data.split(separator: 0x0A, omittingEmptySubsequences: true).count` would return.
    let lineCount: Int
    /// Absolute byte offset at which the last `tailLimit` non-empty lines begin. Zero when the file
    /// holds no more lines than the limit.
    let tailOffset: Int
    /// One past the last byte this pass observed.
    ///
    /// A tail read MUST be clamped to this. The log is appended to while it is read, so a tail read
    /// that runs to end-of-file can return MORE lines than `lineCount` counted — and the caller
    /// compares those two (`hasRestoredHistory = tail.count >= total`). Latching that true disables
    /// transcript trimming and hides the Restore-history button, which is the one direction of this
    /// race that does visible damage.
    let scanEnd: Int
}

/// Counts and locates lines in a JSONL file without materializing it.
///
/// `channel_log.jsonl` reaches hundreds of megabytes — 357 MB / 97,867 lines on the machine this
/// was written for. Reading it whole to count newlines cost about 1.0 s and a 345 MB allocation,
/// and it happened TWICE per launch: once for the 5,000-message transcript tail, and once for a
/// caller that wanted the last 32 messages. The chunked scan below costs about 0.03 s and 2.6 MB.
///
/// ONE forward pass, not a count followed by a backward seek. The two-pass version is faster still,
/// but the count and the tail would then describe different states of a file that is being appended
/// to — and `hasRestoredHistory` compares exactly those two numbers.
enum JSONLScanner {

    /// Default read size. Measured identical to 4 MiB on the real file, and keeps the scan's
    /// resident footprint at a couple of megabytes.
    static let defaultChunkSize = 1 << 20

    /// Scans `url`, returning the non-empty line count and where the last `tailLimit` lines start.
    ///
    /// Equivalence with `split(separator: 0x0A, omittingEmptySubsequences: true)` is the contract,
    /// and it is subtler than counting newlines: `split` counts maximal NON-EMPTY runs, so a blank
    /// line contributes nothing, and a final line with no trailing newline still counts. Counting
    /// `0x0A` bytes instead would change `lineCount`, hence `hasRestoredHistory`, hence whether the
    /// resident transcript is trimmed.
    static func scan(url: URL, tailLimit: Int, chunkSize: Int = defaultChunkSize) throws -> JSONLScan {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        // Offsets of the last `tailLimit` line starts, kept in a ring so memory is bounded by the
        // limit (about 40 KB for 5,000) rather than by the file's line count.
        var ring = [Int](repeating: 0, count: max(tailLimit, 1))
        var lineCount = 0
        var openRun = false        // a non-empty run is open across the current position
        var openRunStart = 0       // ABSOLUTE offset where that run began
        var fileOffset = 0         // ABSOLUTE offset of the current chunk's first byte

        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            let chunkCount = chunk.count
            chunk.withUnsafeBytes { raw in
                guard var base = raw.baseAddress else { return }
                var remaining = chunkCount
                while remaining > 0, let hit = memchr(base, 0x0A, remaining) {
                    let segmentLength = UnsafeRawPointer(hit) - base
                    // Absolute, and computed BEFORE `remaining` is decremented for this segment.
                    // A chunk-relative offset here is the bug that makes every recorded tail
                    // position point into the first chunk — invisible in any single-chunk fixture.
                    let segmentStart = fileOffset + (chunkCount - remaining)
                    if segmentLength > 0 || openRun {
                        ring[lineCount % ring.count] = openRun ? openRunStart : segmentStart
                        lineCount += 1
                    }
                    openRun = false
                    base = UnsafeRawPointer(hit) + 1
                    remaining -= (segmentLength + 1)
                }
                if remaining > 0, !openRun {
                    openRun = true
                    openRunStart = fileOffset + (chunkCount - remaining)
                }
            }
            fileOffset += chunkCount
        }

        // A final line with no trailing newline is still a line to `split`.
        if openRun {
            ring[lineCount % ring.count] = openRunStart
            lineCount += 1
        }

        let tailOffset = (tailLimit <= 0 || lineCount <= tailLimit) ? 0 : ring[lineCount % ring.count]
        return JSONLScan(lineCount: lineCount, tailOffset: tailOffset, scanEnd: fileOffset)
    }

    /// Reads `url` from `offset` up to (but not past) `scanEnd`, so a concurrent append cannot make
    /// the returned bytes describe a newer file than the count they'll be compared against.
    static func readRange(url: URL, from offset: Int, upTo scanEnd: Int) throws -> Data {
        guard scanEnd > offset else { return Data() }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: scanEnd - offset) ?? Data()
    }

    /// Reads roughly the last `byteCount` bytes, starting at the first line boundary inside that
    /// window so the first line returned is never a fragment.
    ///
    /// For a caller that wants the last handful of messages and does NOT need a total. Skipping the
    /// count is what takes the cost from a full-file pass to a single small read — the recovery
    /// caller that wanted 32 messages was paying 1.0 s and 345 MB for them.
    static func readTailBytes(url: URL, byteCount: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = Int(try handle.seekToEnd())
        let start = max(0, size - byteCount)
        try handle.seek(toOffset: UInt64(start))
        let data = try handle.readToEnd() ?? Data()
        // At offset 0 the first line is whole by definition; otherwise drop the partial head.
        guard start > 0, let firstNewline = data.firstIndex(of: 0x0A) else { return data }
        return data.subdata(in: data.index(after: firstNewline)..<data.endIndex)
    }
}

extension DataProtocol where Self.Index == Int {
    /// Whether `needle` appears in this collection. Used as the task-transcript prefilter, where a
    /// hit only means "worth decoding" — never "matches".
    func contains(subsequence needle: Data) -> Bool {
        guard !needle.isEmpty, count >= needle.count else { return false }
        let first = needle[needle.startIndex]
        var index = startIndex
        let last = endIndex - needle.count
        while index <= last {
            if self[index] == first {
                var matched = true
                for offset in 1..<needle.count where self[index + offset] != needle[needle.startIndex + offset] {
                    matched = false
                    break
                }
                if matched { return true }
            }
            index += 1
        }
        return false
    }
}
