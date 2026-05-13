import Foundation

/// Search file contents using regex patterns.
///
/// Supports glob-based file filtering and two output modes:
/// matching file paths only, or matching lines with file:line_number:content format.
struct GrepTool: AgentTool {
    let name = "grep"
    let toolDescription = "Search file contents for lines matching a regex `pattern`. `path` may be a directory (searched recursively) OR a single file. Returns matching file paths by default, or matching lines in file:line:content format. Supports glob-based file filtering when searching a directory. Use instead of grep or rg bash commands for content search."

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
            ])
        ]),
        "required": .array([.string("pattern"), .string("path")])
    ]

    /// Maximum number of matching files to return.
    private static let maxFileMatches = 500
    /// Maximum number of content lines to return in content mode.
    private static let maxContentLines = 1000
    /// Skip files larger than this (likely binary or generated).
    private static let maxFileSize: UInt64 = 1_000_000

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .brown
    }

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

        for fileURL in allURLs {
            // Stop if we've hit the file limit.
            if matchingFiles.count >= Self.maxFileMatches {
                truncated = true
                break
            }
            if contentMode && contentLines.count >= Self.maxContentLines {
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

            // Skip oversized files.
            if let fileSize = resourceValues.fileSize, UInt64(fileSize) > Self.maxFileSize {
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
                        if contentLines.count < Self.maxContentLines {
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

        // Format output. "no matches" is a successful empty result, not a failure.
        if contentMode {
            if contentLines.isEmpty {
                return .success("No matches found for pattern '\(pattern)' in \(path).")
            }
            var output = contentLines.joined(separator: "\n")
            if truncated {
                output += "\n\n[Results truncated: \(contentLines.count) lines from \(matchingFiles.count) files shown]"
            }
            return .success(output)
        } else {
            if matchingFiles.isEmpty {
                return .success("No files matched pattern '\(pattern)' in \(path).")
            }
            var output = matchingFiles.joined(separator: "\n")
            if truncated {
                output += "\n\n[Results truncated: showing \(Self.maxFileMatches) of potentially more matches]"
            }
            return .success(output)
        }
    }
}
