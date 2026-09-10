import Foundation
import Testing
@testable import AgentSmithKit

/// `JSONLScanner` replaced reading the whole transcript to count its lines. Its contract is EXACT
/// equivalence with `data.split(separator: 0x0A, omittingEmptySubsequences: true)`, because the
/// count it produces feeds `hasRestoredHistory = tail.count >= total` — which gates whether the
/// resident transcript keeps being trimmed and whether the Restore-history button appears.
///
/// The two things easiest to get wrong here, both pinned below:
///   - counting NEWLINES instead of non-empty RUNS (differs on any blank line, and the real corpus
///     happens to have none — so a kernel with this bug measures perfectly and ships broken);
///   - recording CHUNK-relative line offsets instead of absolute ones, which is invisible in every
///     fixture smaller than one chunk.
@Suite("JSONL scanner")
struct JSONLScannerTests {

    private func withTempFile(_ contents: Data, _ body: (URL) throws -> Void) throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("jsonl-scan-\(UUID().uuidString).jsonl")
        try contents.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    /// The oracle the scanner must match.
    private func oracleCount(_ data: Data) -> Int {
        data.split(separator: 0x0A, omittingEmptySubsequences: true).count
    }

    private static let edgeCases: [String] = [
        "",                       // empty file
        "a",                      // single line, no trailing newline
        "a\n",                    // single line, trailing newline
        "\n",                     // a lone newline: zero non-empty runs
        "\n\n",                   // consecutive newlines
        "a\n\nb\n",               // blank line BETWEEN records — where newline-counting diverges
        "\na\n",                  // leading newline
        "a\n\n",                  // trailing blank
        "a\nb",                   // no trailing newline after the last record
        "\n\n\n",                 // all newlines
        "a\nb\nc\nd\ne\n"         // ordinary
    ]

    @Test("Line count matches split() across edge cases at every chunk size")
    func lineCountMatchesOracle() throws {
        for text in Self.edgeCases {
            let data = Data(text.utf8)
            for chunkSize in [1, 2, 3, 4, 5, 7, 8, 1 << 20] {
                try withTempFile(data) { url in
                    let scan = try JSONLScanner.scan(url: url, tailLimit: 3, chunkSize: chunkSize)
                    #expect(
                        scan.lineCount == oracleCount(data),
                        "text=\(text.debugDescription) chunk=\(chunkSize): \(scan.lineCount) != \(oracleCount(data))"
                    )
                    #expect(scan.scanEnd == data.count)
                }
            }
        }
    }

    @Test("A line ending exactly on a chunk boundary is counted once")
    func newlineOnChunkBoundary() throws {
        // "abc\n" is 4 bytes; with chunkSize 4 the newline is the last byte of chunk 0.
        let data = Data("abc\ndef\nghi\n".utf8)
        try withTempFile(data) { url in
            let scan = try JSONLScanner.scan(url: url, tailLimit: 2, chunkSize: 4)
            #expect(scan.lineCount == 3)
        }
    }

    @Test("A line longer than the chunk size is counted once and located correctly")
    func lineLongerThanChunk() throws {
        let long = String(repeating: "x", count: 5000)
        let data = Data("first\n\(long)\nlast\n".utf8)
        try withTempFile(data) { url in
            let scan = try JSONLScanner.scan(url: url, tailLimit: 1, chunkSize: 64)
            #expect(scan.lineCount == 3)
            let tail = try JSONLScanner.readRange(url: url, from: scan.tailOffset, upTo: scan.scanEnd)
            #expect(String(data: tail, encoding: .utf8) == "last\n")
        }
    }

    /// The absolute-offset guard. Every single-chunk fixture passes with chunk-relative offsets, so
    /// the file MUST exceed one chunk for this to mean anything.
    @Test("Tail offsets are absolute, not chunk-relative")
    func tailOffsetsAreAbsolute() throws {
        let lines = (0..<200).map { "line-\($0)" }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        try withTempFile(data) { url in
            // 64-byte chunks over ~1.8 KB — the tail lies many chunks in.
            let scan = try JSONLScanner.scan(url: url, tailLimit: 3, chunkSize: 64)
            #expect(scan.lineCount == 200)
            let tail = try JSONLScanner.readRange(url: url, from: scan.tailOffset, upTo: scan.scanEnd)
            #expect(String(data: tail, encoding: .utf8) == "line-197\nline-198\nline-199\n")
        }
    }

    @Test("The tail offset yields exactly min(count, limit) lines")
    func tailOffsetYieldsRequestedLineCount() throws {
        let lines = (0..<50).map { "l\($0)" }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        for limit in [0, 1, 2, 49, 50, 51, 500] {
            try withTempFile(data) { url in
                let scan = try JSONLScanner.scan(url: url, tailLimit: limit, chunkSize: 32)
                let tail = try JSONLScanner.readRange(url: url, from: scan.tailOffset, upTo: scan.scanEnd)
                let got = tail.split(separator: 0x0A, omittingEmptySubsequences: true).count
                #expect(got == min(max(limit, 0) == 0 ? 50 : limit, 50), "limit=\(limit) got=\(got)")
            }
        }
    }

    @Test("Randomized byte strings agree with split() at every chunk size")
    func fuzzAgainstOracle() throws {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<400 {
            let length = Int.random(in: 0...80, using: &generator)
            // A heavily newline-biased alphabet, so blank runs and boundaries are common.
            var bytes = [UInt8]()
            for _ in 0..<length {
                bytes.append(Bool.random(using: &generator) ? 0x0A : UInt8.random(in: 0x61...0x7A, using: &generator))
            }
            let data = Data(bytes)
            for chunkSize in [1, 3, 8, 1 << 20] {
                try withTempFile(data) { url in
                    let scan = try JSONLScanner.scan(url: url, tailLimit: 4, chunkSize: chunkSize)
                    #expect(
                        scan.lineCount == oracleCount(data),
                        "chunk=\(chunkSize) bytes=\(Array(data)) got \(scan.lineCount) want \(oracleCount(data))"
                    )
                }
            }
        }
    }

    @Test("readTailBytes never returns a partial first line")
    func tailBytesStartOnALineBoundary() throws {
        let lines = (0..<100).map { "record-number-\($0)" }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        try withTempFile(data) { url in
            // A window that lands mid-record.
            let bytes = try JSONLScanner.readTailBytes(url: url, byteCount: 137).data
            let text = String(data: bytes, encoding: .utf8) ?? ""
            for line in text.split(separator: "\n") {
                #expect(line.hasPrefix("record-number-"), "partial line leaked: \(line)")
            }
        }
    }

    @Test("The prefilter finds a needle regardless of position and casing, and reports absence")
    func subsequenceSearch() {
        let haystack = Data(#"{"id":"A","taskID":"DEAD-BEEF"}"#.utf8)
        #expect(haystack.containsCaseInsensitive(Data("DEAD-BEEF".utf8)))
        #expect(haystack.containsCaseInsensitive(Data(#"{"id"#.utf8)))
        #expect(haystack.containsCaseInsensitive(Data("}".utf8)))
        #expect(!haystack.containsCaseInsensitive(Data("CAFE-BABE".utf8)))
        // A slice's indices are offsets into its parent — the search must not assume zero-based.
        let slice = haystack.split(separator: 0x2C).last!
        #expect(slice.containsCaseInsensitive(Data("DEAD-BEEF".utf8)))
        // Casing must not matter in EITHER direction — the haystack or the needle.
        #expect(haystack.containsCaseInsensitive(Data("dead-beef".utf8)))
        #expect(haystack.containsCaseInsensitive(Data("DeAd-BeEf".utf8)))
        #expect(Data("taskID:dEaD-bEeF".utf8).containsCaseInsensitive(Data("DEAD-BEEF".utf8)))
        // And a reachedStart signal is what the widening caller terminates on.
        #expect(!haystack.containsCaseInsensitive(Data("cafe-babe".utf8)))
    }
}
