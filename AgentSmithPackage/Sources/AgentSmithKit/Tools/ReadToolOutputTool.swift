import Foundation

/// Reads back, in pages, a tool result that was too large for the model's context and was saved
/// by `ToolResultCap`.
///
/// Saved output is addressed by HANDLE, not by path, and a caller reaches only its own
/// `ToolContext.spilledToolOutputs` store — so reading it is not a filesystem read and is not
/// judged against a task's path rules. See `docs/plans/SpilledToolOutputByHandle.md`.
struct ReadToolOutputTool: AgentTool {
    static let toolName = "read_tool_output"

    let name = ReadToolOutputTool.toolName
    let toolDescription = """
        Read the full output of an earlier tool call whose result was too large and was truncated to \
        a preview. The truncated result names a `handle`; pass it here. Lines are returned in `cat -n` \
        format (line number, two spaces, text). \
        \
        Page with `startingLineNum` and `maxLines`. To see only some lines, pass `pattern` (a regular \
        expression): only matching lines are returned, and `maxLines` then counts matching lines. \
        When more remains, the result ends with the `startingLineNum` to pass next — keep `handle` \
        and `pattern` the same to continue. A line longer than \(ReadToolOutputTool.maxLineCharacters) \
        characters is split into consecutive numbered lines, and `pattern` is matched within each. \
        \
        The handle only works here: saved output is not a file, so do not look for it with \
        file_read, grep or glob.
        """

    let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "handle": .dictionary([
                "type": .string("string"),
                "description": .string("The handle named in the truncated tool result.")
            ]),
            "startingLineNum": .dictionary([
                "type": .string("integer"),
                "description": .string("1-based line number to start from. Defaults to 1. With `pattern`, the line to start searching from.")
            ]),
            "maxLines": .dictionary([
                "type": .string("integer"),
                "description": .string("Most lines to return (with `pattern`: most matching lines). Defaults to \(ReadToolOutputTool.defaultMaxLines).")
            ]),
            "pattern": .dictionary([
                "type": .string("string"),
                "description": .string("Optional regular expression. When given, only lines that match are returned.")
            ])
        ]),
        "required": .array([.string("handle")])
    ]

    /// Lines returned when the caller names no count.
    static let defaultMaxLines = 200
    /// Longest line returned as one line; anything longer is split, so a result that is a single
    /// enormous line (minified JSON) can still be paged and searched.
    static let maxLineCharacters = 2_000
    /// Ceiling on one response's line text. Kept well under `ToolResultCap.maxCharacters` so that
    /// reading saved output can never itself be truncated and saved again.
    static let maxResponseCharacters = 30_000

    init() {}

    func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .brown || context.agentRole == .smith || context.agentRole == .validator
    }

    func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        let handle: UUID
        switch ToolArguments.optionalUUID(arguments, "handle") {
        case .absent:
            throw ToolCallError.missingRequiredArgument("handle")
        case .malformed(let raw):
            return .failure("\"\(raw)\" is not a saved-output handle. Pass the handle exactly as the truncated tool result gave it.")
        case .value(let parsed):
            handle = parsed
        }

        let pattern: NSRegularExpression?
        if let rawPattern = ToolArguments.optionalString(arguments, "pattern") {
            do {
                pattern = try NSRegularExpression(pattern: rawPattern)
            } catch {
                return .failure("Invalid regular expression \"\(rawPattern)\": \(error.localizedDescription)")
            }
        } else {
            pattern = nil
        }

        let saved: String?
        do {
            saved = try context.spilledToolOutputs.output(forHandle: handle)
        } catch {
            return .failure("The saved output for handle \(handle.uuidString) could not be read: \(error.localizedDescription)")
        }
        guard let saved else {
            return .failure("No saved output for handle \(handle.uuidString). It was not saved by this task, or it has been cleared. Run the original tool call again with a narrower request.")
        }

        return try Self.page(
            of: saved,
            handle: handle,
            startingLine: max(1, ToolArguments.optionalInt(arguments, "startingLineNum") ?? 1),
            maxLines: max(1, ToolArguments.optionalInt(arguments, "maxLines") ?? Self.defaultMaxLines),
            pattern: pattern
        )
    }

    /// One page of `savedOutput`: up to `maxLines` lines from `startingLine` on — or, with
    /// `pattern`, up to `maxLines` MATCHING lines found from `startingLine` on. A page that stops
    /// before the end names the line to resume from, which is what lets filtered output be paged
    /// the same way as unfiltered output.
    static func page(
        of savedOutput: String,
        handle: UUID,
        startingLine: Int,
        maxLines: Int,
        pattern: NSRegularExpression?
    ) throws -> ToolExecutionResult {
        let lines = numberedLines(of: savedOutput)
        guard startingLine <= lines.count else {
            return .failure("startingLineNum \(startingLine) is past the end: the saved output has \(lines.count) lines.")
        }

        var rendered: [String] = []
        var renderedCharacters = 0
        // The 1-based line a following call resumes from; nil once the end has been reached.
        var resumeLine: Int?
        for index in (startingLine - 1)..<lines.count {
            if index % 1_000 == 0 { try Task.checkCancellation() }
            let line = lines[index]
            if let pattern {
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                guard pattern.firstMatch(in: line, options: [], range: range) != nil else { continue }
            }
            // The first line always goes out, so a page can never be empty for lack of room.
            if rendered.count == maxLines
                || (!rendered.isEmpty && renderedCharacters + line.count > maxResponseCharacters) {
                resumeLine = index + 1
                break
            }
            rendered.append(String(format: "%6d  ", index + 1) + line)
            renderedCharacters += line.count
        }

        let lastLineCovered = (resumeLine ?? lines.count + 1) - 1
        let span = "lines \(startingLine)–\(lastLineCovered) of \(lines.count)"
        let header = pattern == nil
            ? "[Saved tool output \(handle.uuidString): \(span)]"
            : "[Saved tool output \(handle.uuidString): \(rendered.count) matching line(s) in \(span)]"
        let footer: String
        if let resumeLine {
            let unchanged = pattern == nil ? "the same handle" : "the same handle and pattern"
            footer = "[More remains. Call \(toolName) again with \(unchanged) and startingLineNum: \(resumeLine)]"
        } else {
            footer = "[End of saved output]"
        }
        return .success(([header] + rendered + [footer]).joined(separator: "\n"))
    }

    /// `savedOutput` as the lines this tool numbers: split at line breaks, then any line longer
    /// than `maxLineCharacters` split into pieces of that length.
    static func numberedLines(of savedOutput: String) -> [String] {
        var rawLines = savedOutput.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        // Text ending in a line break has no line after it.
        if rawLines.count > 1, rawLines.last?.isEmpty == true { rawLines.removeLast() }

        var lines: [String] = []
        lines.reserveCapacity(rawLines.count)
        for rawLine in rawLines {
            // Walks forward one piece at a time and never measures the whole remainder, so a single
            // enormous line costs time proportional to its length rather than to its length squared.
            var pieceStart = rawLine.startIndex
            while let pieceEnd = rawLine.index(pieceStart, offsetBy: maxLineCharacters, limitedBy: rawLine.endIndex),
                  pieceEnd < rawLine.endIndex {
                lines.append(String(rawLine[pieceStart..<pieceEnd]))
                pieceStart = pieceEnd
            }
            lines.append(String(rawLine[pieceStart...]))
        }
        return lines
    }
}
