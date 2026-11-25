import Foundation

/// Shared handling for oversized tool results. Keeps a small head preview inline and spills the
/// FULL text to the caller's `SpilledToolOutputStore`, which the agent/validator reads back in
/// pages through `read_tool_output`. Used by BOTH the agent run loop (`AgentActor`) and the
/// evaluation runner (`EvaluationRunner`) so tool output is capped identically everywhere.
enum ToolResultCap {
    /// Results larger than this spill instead of entering the model's context whole.
    static let maxCharacters = 50_000
    /// Small head preview shown inline when a result spills (the full text is in the store).
    static let previewCharacters = 2_000

    /// Returns `result` unchanged when it fits. Otherwise saves the FULL result to `store` and
    /// returns a small head preview plus the handle that reads it back — so the omitted tail is
    /// recoverable rather than lost. Best-effort: falls back to a plain truncation marker if the
    /// result can't be saved.
    ///
    /// The returned text names the handle and never a path: an agent given a path reads it with the
    /// filesystem tools, which the Security Agent judges against the task's path rules.
    static func cap(_ result: String, spillingInto store: SpilledToolOutputStore) -> String {
        guard result.count > maxCharacters else { return result }
        let preview = String(result.prefix(previewCharacters))
        do {
            let handle = try store.save(result)
            return """
                [HEAD PREVIEW — first \(previewCharacters) of \(result.count) characters. This is NOT the full output.]
                \(preview)
                […truncated. The FULL output (\(result.count) chars) is saved under handle \(handle.uuidString).
                Read it with \(ReadToolOutputTool.toolName): pass that handle, and page with startingLineNum + maxLines or pass pattern to see only matching lines. It is not a file you can open with the file tools.]
                """
        } catch {
            let remaining = result.count - previewCharacters
            return preview + "\n\n[Output truncated to \(previewCharacters) chars; the full output could not be saved to disk (\(error.localizedDescription)) — \(remaining) characters omitted.]"
        }
    }
}
