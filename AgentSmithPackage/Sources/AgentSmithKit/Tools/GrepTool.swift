import Foundation

/// Search file contents using regex patterns.
///
/// Supports glob-based file filtering and two output modes:
/// matching file paths only, or matching lines with file:line_number:content format.
struct GrepTool: AgentTool {
    let name = "grep"
    let toolDescription = "Search file contents for lines matching a regex `pattern`. `path` may be a directory (searched recursively) OR a single file. Returns matching file paths by default, or matching lines in file:line:content format. Supports glob-based file filtering when searching a directory. Use instead of grep or rg bash commands for content search. Result limits are caller-configurable: `max_file_count` (default \(GrepTool.defaultMaxFileMatches)), `max_line_count` (default \(GrepTool.defaultMaxContentLines)), `max_file_size_mb` (default \(GrepTool.defaultMaxFileSizeMB)); files over the size limit are skipped and their count is reported so matches are never silently missed."

    public func description(for role: AgentRole) -> String {
        switch role {
        case .brown:
            return toolDescription + " " +
                   BrownBehavior.approvalGateNote(outcome: "matching file paths or content lines")
        default:
            return toolDescription
        }
    }

    let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "pattern": .dictionary([
                "type": .string("string"),
                "description": .string("Regex pattern to search for in file contents (e.g. \"TODO\", \"func\\\\s+\\\\w+\", \"import.*Foundation\").")
            ]),
            "path": .dictionary([
                "type": .string("string"),
                "description": .string("Absolute directory path to search in. Must start with / or ~/.")
            ]),
            "glob": .dictionary([
                "type": .string("string"),
                "description": .string("Optional glob pattern to filter which files to search (e.g. \"*.swift\", \"*.{ts,tsx}\"). Patterns without / match against filename only. Patterns with / match against the relative path from the search directory.")
            ]),
            "output_mode": .dictionary([
                "type": .string("string"),
                "description": .string("Output format: \"files_with_matches\" (default) returns only file paths containing matches. \"content\" returns matching lines as file:line_number:content."),
                "enum": .array([.string("files_with_matches"), .string("content")])
            ]),
            "max_file_count": .dictionary([
                "type": .string("integer"),
                "description": .string("Max number of matching files to return (default \(GrepTool.defaultMaxFileMatches)).")
            ]),
            "max_line_count": .dictionary([
                "type": .string("integer"),
                "description": .string("Max number of matching content lines to return in \"content\" mode (default \(GrepTool.defaultMaxContentLines)).")
            ]),
            "max_file_size_mb": .dictionary([
                "type": .string("integer"),
                "description": .string("Skip files larger than this many megabytes (default \(GrepTool.defaultMaxFileSizeMB)). Any skipped files are reported in the result, so matches are never silently missed — raise this to search larger files.")
            ])
        ]),
        "required": .array([.string("pattern"), .string("path")])
    ]

    /// Default cap on matching files returned; caller override: `max_file_count`.
    private static let defaultMaxFileMatches = 2500
    /// Default cap on matching content lines returned; caller override: `max_line_count`.
    private static let defaultMaxContentLines = 10_000
    /// Default per-file size ceiling in megabytes; caller override: `max_file_size_mb`. Files
    /// larger than this are skipped, and the skip COUNT is reported — never a silent miss.
    private static let defaultMaxFileSizeMB = 16

    /// Parses an optional positive-integer argument, flooring at 1, falling back when absent/invalid.
    private static func positiveInt(_ raw: AnyCodable?, or fallback: Int) -> Int {
        switch raw {
        case .int(let v): return max(1, v)
        case .double(let v): return max(1, Int(v))
        default: return fallback
        }
    }

    public init() {}

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard case .string(let pattern) = arguments["pattern"] else {
            throw ToolCallError.missingRequiredArgument("pattern")
        }
        guard case .string(let rawPath) = arguments["path"] else {
            throw ToolCallError.missingRequiredArgument("path")
        }
        let path = (rawPath as NSString).expandingTildeInPath

        guard path.hasPrefix("/") else {
            return .failure("Error: path must be absolute (start with /). Got: \(path)")
        }

        // Compile the search regex.
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern)
        } catch {
            return .failure("Error: Invalid regex pattern '\(pattern)': \(error.localizedDescription)")
        }

        // Parse output mode.
        let contentMode: Bool
        if case .string(let mode) = arguments["output_mode"] {
            guard mode == "files_with_matches" || mode == "content" else {
                return .failure("Error: `output_mode` must be 'files_with_matches' or 'content'. Got: '\(mode)'")
            }
            contentMode = mode == "content"
        } else {
            contentMode = false
        }

        // Caller-configurable limits (all optional; defaults are generous).
        let maxFileMatches = Self.positiveInt(arguments["max_file_count"], or: Self.defaultMaxFileMatches)
        let maxContentLines = Self.positiveInt(arguments["max_line_count"], or: Self.defaultMaxContentLines)
        let maxFileSizeMB = Self.positiveInt(arguments["max_file_size_mb"], or: Self.defaultMaxFileSizeMB)
        let maxFileSizeBytes = UInt64(maxFileSizeMB) * 1024 * 1024

        // Compile glob filter if provided.
        let globRegex: NSRegularExpression?
        let globMatchesBasename: Bool
        if case .string(let globPattern) = arguments["glob"] {
            guard !globPattern.contains("..") else {
                return .failure("Error: Glob pattern must not contain '..' (path traversal).")
            }
            do {
                let regexPattern = GlobTool.globToRegex(globPattern)
                globRegex = try NSRegularExpression(pattern: "^\(regexPattern)$")
            } catch {
                return .failure("Error: Invalid glob pattern '\(globPattern)': \(error.localizedDescription)")
            }
            // Patterns without / match against basename only (like ripgrep).
            globMatchesBasename = !globPattern.contains("/")
        } else {
            globRegex = nil
            globMatchesBasename = true
        }

        let fm = FileManager.default
        let baseURL = URL(fileURLWithPath: path)
        let resolvedBase = baseURL.resolvingSymlinksInPath().path

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: resolvedBase, isDirectory: &isDir) else {
            return .failure("Error: Path does not exist: \(path)")
        }

        // `path` may be a directory (recursive enumeration) or a single file (one-element list).
        // Single-file searches still go through the same per-URL filter pipeline below so glob
        // filtering and the size/binary skips behave identically in both modes.
        let allURLs: [URL]
        if isDir.boolValue {
            guard let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: resolvedBase),
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else {
                return .failure("Error: Unable to enumerate directory: \(path)")
            }
            // Collect URLs synchronously to avoid async-context restrictions on NSDirectoryEnumerator.
            var collected: [URL] = []
            while let obj = enumerator.nextObject() {
                if let fileURL = obj as? URL {
                    collected.append(fileURL)
                }
            }
            allURLs = collected
        } else {
            allURLs = [URL(fileURLWithPath: resolvedBase)]
        }

        var matchingFiles: [String] = []
        var contentLines: [String] = []
        var truncated = false
        var oversizedSkipped = 0

        for fileURL in allURLs {
            // Stop if we've hit the file limit.
            if matchingFiles.count >= maxFileMatches {
                truncated = true
                break
            }
            if contentMode && contentLines.count >= maxContentLines {
                truncated = true
                break
            }

            let resourceValues: URLResourceValues
            do {
                resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            } catch {
                continue
            }
            guard resourceValues.isRegularFile == true else { continue }

            // Skip oversized files — but COUNT them so the skip is reported, never silent.
            if let fileSize = resourceValues.fileSize, UInt64(fileSize) > maxFileSizeBytes {
                oversizedSkipped += 1
                continue
            }

            let resolvedFile = fileURL.resolvingSymlinksInPath().path

            // Security: ensure resolved path stays under (or equals) the base. The equality
            // case covers single-file mode where `path` *is* the file being searched.
            guard resolvedFile.hasPrefix(resolvedBase + "/") || resolvedFile == resolvedBase else {
                continue
            }

            // Block sensitive credential paths.
            if FileReadTool.checkPathRestriction(resolvedFile) != nil {
                continue
            }

            // Apply glob filter.
            if let globRegex {
                let matchTarget: String
                if globMatchesBasename {
                    matchTarget = fileURL.lastPathComponent
                } else {
                    // Match against relative path from search root.
                    matchTarget = String(resolvedFile.dropFirst(resolvedBase.count + 1))
                }
                let range = NSRange(matchTarget.startIndex..<matchTarget.endIndex, in: matchTarget)
                if globRegex.firstMatch(in: matchTarget, range: range) == nil {
                    continue
                }
            }

            // Read file contents. Skip files that fail to decode as UTF-8 (binary).
            guard let content = try? String(contentsOf: URL(fileURLWithPath: resolvedFile), encoding: .utf8) else {
                continue
            }

            if contentMode {
                // Line-by-line search with line numbers.
                let lines = content.components(separatedBy: "\n")
                var fileHasMatch = false
                for (idx, line) in lines.enumerated() {
                    let lineRange = NSRange(line.startIndex..<line.endIndex, in: line)
                    if regex.firstMatch(in: line, range: lineRange) != nil {
                        if contentLines.count < maxContentLines {
                            contentLines.append("\(resolvedFile):\(idx + 1):\(line)")
                        } else {
                            truncated = true
                        }
                        fileHasMatch = true
                    }
                }
                if fileHasMatch {
                    matchingFiles.append(resolvedFile)
                }
            } else {
                // files_with_matches mode: just check if there's any match.
                let fullRange = NSRange(content.startIndex..<content.endIndex, in: content)
                if regex.firstMatch(in: content, range: fullRange) != nil {
                    matchingFiles.append(resolvedFile)
                }
            }
        }

        // Oversized files that were skipped are surfaced (never a silent miss) — a match could
        // live in one of them; the caller can raise `max_file_size_mb` to include them.
        let skipNote = oversizedSkipped > 0
            ? "\n\n[\(oversizedSkipped) file(s) skipped for exceeding the \(maxFileSizeMB) MB size limit — raise `max_file_size_mb` to search them]"
            : ""

        // Format output. "no matches" is a successful empty result, not a failure.
        if contentMode {
            if contentLines.isEmpty {
                return .success("No matches found for pattern '\(pattern)' in \(path)." + skipNote)
            }
            var output = contentLines.joined(separator: "\n")
            if truncated {
                output += "\n\n[Results truncated: \(contentLines.count) lines from \(matchingFiles.count) files shown — raise `max_line_count`]"
            }
            return .success(output + skipNote)
        } else {
            if matchingFiles.isEmpty {
                return .success("No files matched pattern '\(pattern)' in \(path)." + skipNote)
            }
            var output = matchingFiles.joined(separator: "\n")
            if truncated {
                output += "\n\n[Results truncated: showing \(maxFileMatches) of potentially more matches — raise `max_file_count`]"
            }
            return .success(output + skipNote)
        }
    }
}
