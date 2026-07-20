import Foundation

/// Shared handling for oversized tool results. Keeps a small head preview inline and spills the
/// FULL text to an overflow file, which the agent/validator reads back in slices (file_read paging
/// or grep). Used by BOTH the agent run loop (`AgentActor`) and the evaluation runner
/// (`EvaluationRunner`) so tool output is capped identically everywhere.
enum ToolResultCap {
    /// Results larger than this overflow to a file instead of entering the model's context whole.
    static let maxCharacters = 50_000
    /// Small head preview shown inline when a result overflows (the full text lives in the file).
    static let previewCharacters = 2_000
    /// Overflow directory under the OS temp dir — not credential-restricted, so `file_read` can read
    /// it back; OS-managed cleanup.
    static let overflowDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgentSmith-tool-output", isDirectory: true)

    /// Returns `result` unchanged when it fits. Otherwise writes the FULL result to an overflow file
    /// and returns a small head preview plus a pointer to that file with slice-read instructions —
    /// so the omitted tail is recoverable rather than lost. Best-effort: falls back to a plain
    /// truncation marker if the file can't be written.
    ///
    /// Note the reader must page it: a `file_read` result runs back through THIS same cap, so a
    /// whole-file read would re-truncate; small `maxLines` ranges (or grep) stay under the limit.
    static func cap(_ result: String) -> String {
        guard result.count > maxCharacters else { return result }
        let preview = String(result.prefix(previewCharacters))
        do {
            try FileManager.default.createDirectory(at: overflowDirectory, withIntermediateDirectories: true)
            let fileURL = overflowDirectory.appendingPathComponent("tool-output-\(UUID().uuidString).txt")
            try result.write(to: fileURL, atomically: true, encoding: .utf8)
            return """
                [HEAD PREVIEW — first \(previewCharacters) of \(result.count) characters. This is NOT the full output.]
                \(preview)
                […truncated. FULL output (\(result.count) chars) saved to:
                \(fileURL.path)
                Read it in SMALL slices — file_read with startingLineNum + a modest maxLines, or grep the file for what you need. Do NOT read it whole: a file_read result over \(maxCharacters) chars is itself re-truncated the same way.]
                """
        } catch {
            let remaining = result.count - previewCharacters
            return preview + "\n\n[Output truncated to \(previewCharacters) chars; the full output could not be saved to disk (\(error.localizedDescription)) — \(remaining) characters omitted.]"
        }
    }
}
