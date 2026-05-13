import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Reads file contents with line numbers, pagination, and content-type awareness.
///
/// Text files are returned with `cat -n` style line numbering.
/// PDF files are read via PDFKit with optional page ranges.
/// Image and binary files return metadata only.
struct FileReadTool: AgentTool {
    let name = "file_read"
    let toolDescription = "Read the contents of a file. Text files are returned with line numbers in `cat -n` format, which means each line of text starts with a line number, padded on the left to 6 characters, followed by two spaces, and then the line's content. Supports PDF files via a pages parameter. Returns metadata ONLY for images and binary files. Before invoking `file_read`, consider if there are other files you will wish to read as well. If so, read them all in parallel by issuing multiple `file_read` calls in a single response."

    public func description(for role: AgentRole) -> String {
        switch role {
        case .brown:
            return toolDescription + " " +
                   BrownBehavior.approvalGateNote(outcome: "the file contents")
        default:
            return toolDescription
        }
    }

    let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "path": .dictionary([
                "type": .string("string"),
                "description": .string("File path to read (absolute or ~/relative).")
            ]),
            "offset": .dictionary([
                "type": .string("integer"),
                "description": .string("1-based line number to start reading from. Defaults to 1 (beginning of file). Only applies to text files.")
            ]),
            "limit": .dictionary([
                "type": .string("integer"),
                "description": .string("Maximum number of lines to return. Defaults to 2500. Only applies to text files.")
            ]),
            "pages": .dictionary([
                "type": .string("string"),
                "description": .string("Page range for PDF files (e.g. '1-5', '3', '10-20'). Required for PDFs over 10 pages.")
            ])
        ]),
        "required": .array([.string("path")])
    ]

    /// Maximum characters in total output to prevent context overflow.
    static let maxCharacters = 250_000
    /// Default number of lines to return when no limit is specified.
    private static let defaultLineLimit = 2500
    /// PDFs with more pages than this require an explicit pages parameter.
    private static let maxAutoPages = 10

    public init() {}

    /// Normalizes a path string before filesystem lookup. See `PathNormalization.normalize`.
    static func normalizePath(_ raw: String) -> String {
        PathNormalization.normalize(raw)
    }

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .brown || context.agentRole == .smith || context.agentRole == .jones
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard case .string(let rawPath) = arguments["path"] else {
            throw ToolCallError.missingRequiredArgument("path")
        }
        let path = Self.normalizePath(rawPath)

        if let rejection = Self.checkPathRestriction(path) {
            return .failure(rejection)
        }

        let url = URL(fileURLWithPath: path)
        let resolvedPath = url.resolvingSymlinksInPath().path

        // Record this file as read for file_write gating.
        // Only Brown's reads count — Smith and Jones reads must not gate Brown's file_write.
        if context.agentRole == .brown {
            context.recordFileRead(resolvedPath)
            context.recordFileRead(path)
        }

        // Detect content type.
        let contentType = Self.detectContentType(at: resolvedPath)

        let raw: String
        switch contentType {
        case .pdf:
            let pagesParam: String?
            if case .string(let p) = arguments["pages"] { pagesParam = p } else { pagesParam = nil }
            raw = Self.readPDF(at: url, pages: pagesParam)

        case .image:
            raw = Self.imageMetadata(at: resolvedPath, originalPath: path)

        case .text:
            let offset: Int
            if case .int(let o) = arguments["offset"] { offset = max(1, o) } else { offset = 1 }
            let limit: Int
            if case .int(let l) = arguments["limit"] { limit = max(1, l) } else { limit = Self.defaultLineLimit }
            raw = Self.readText(at: url, resolvedPath: resolvedPath, offset: offset, limit: limit)

        case .binary:
            raw = Self.binaryMetadata(at: resolvedPath, originalPath: path)
        }
        return Self.classify(raw)
    }

    /// Wraps a helper-function result in `.success` / `.failure`. Helper outputs that signal a
    /// domain-level failure all begin with one of `Error`, `BLOCKED`, or the "specify a pages
    /// parameter" prompt — keep this list in sync with the helpers if their format changes.
    static func classify(_ output: String) -> ToolExecutionResult {
        let trimmed = output.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("Error") || trimmed.hasPrefix("BLOCKED")
            || trimmed.hasPrefix("PDF has ") {
            return .failure(output)
        }
        return .success(output)
    }

    // MARK: - Content Type Detection

    private enum FileContentType {
        case text, pdf, image, binary
    }

    private static func detectContentType(at path: String) -> FileContentType {
        // Check by extension first for common types UTType might not recognize.
        let ext = (path as NSString).pathExtension.lowercased()

        if ext == "pdf" { return .pdf }
        if ext == "svg" { return .text } // SVG is XML text, not a raster image.

        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "webp", "heic", "heif", "ico"]
        if imageExtensions.contains(ext) { return .image }

        // Use UTType for more nuanced detection.
        if let utType = UTType(filenameExtension: ext) {
            if utType.conforms(to: .pdf) { return .pdf }
            if utType.conforms(to: .image) { return .image }
            if utType.conforms(to: .text) || utType.conforms(to: .sourceCode)
                || utType.conforms(to: .script) || utType.conforms(to: .propertyList)
                || utType.conforms(to: .json) || utType.conforms(to: .xml) {
                return .text
            }
        }

        // Common text extensions UTType may not cover.
        let textExtensions: Set<String> = [
            "swift", "m", "h", "c", "cpp", "cc", "cxx", "rs", "go", "java", "kt", "kts",
            "py", "rb", "js", "jsx", "ts", "tsx", "mjs", "cjs", "vue", "svelte",
            "html", "htm", "css", "scss", "sass", "less",
            "json", "yaml", "yml", "toml", "ini", "cfg", "conf",
            "xml", "svg", "plist", "entitlements", "pbxproj", "xcscheme", "xcworkspacedata",
            "md", "markdown", "txt", "rst", "tex", "csv", "tsv", "log",
            "sh", "bash", "zsh", "fish", "ps1", "bat", "cmd",
            "sql", "graphql", "gql", "proto",
            "r", "R", "jl", "lua", "pl", "pm", "ex", "exs", "erl", "hrl",
            "hs", "lhs", "ml", "mli", "clj", "cljs", "el", "lisp", "scm",
            "cmake", "gradle", "sbt",
            "gitignore", "gitattributes", "editorconfig", "eslintrc", "prettierrc",
            "lock", "resolved"
        ]
        if textExtensions.contains(ext) { return .text }

        // No extension or unknown — try reading as UTF-8 to detect.
        // Check the first 8KB for null bytes (binary indicator).
        if let handle = FileHandle(forReadingAtPath: path) {
            defer { try? handle.close() }
            let sample = handle.readData(ofLength: 8192)
            if sample.contains(0) {
                return .binary
            }
            return .text
        }

        return .binary
    }

    // MARK: - Text Reading

    private static func readText(at url: URL, resolvedPath: String, offset: Int, limit: Int) -> String {
        // Check file size before reading.
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: resolvedPath)
            if let fileSize = attrs[.size] as? UInt64, fileSize > maxCharacters {
                return "Error: File is too large to read (\(fileSize) bytes, maximum is \(maxCharacters))."
            }
        } catch {
            return "Error checking file size: \(error.localizedDescription)"
        }

        let content: String
        do {
            content = try String(contentsOf: url, encoding: .utf8)
        } catch {
            return "Error reading file: \(error.localizedDescription)"
        }

        guard content.count <= maxCharacters else {
            return "Error: File is too large to read (\(content.count) characters, maximum is \(maxCharacters))."
        }

        let allLines = content.components(separatedBy: "\n")
        let totalLines = allLines.count

        // Apply offset (1-based) and limit.
        let startIndex = offset - 1 // convert to 0-based
        guard startIndex < totalLines else {
            return "Error: offset \(offset) is beyond the end of the file (\(totalLines) lines)."
        }

        let endIndex = min(startIndex + limit, totalLines)
        let selectedLines = allLines[startIndex..<endIndex]

        // Format as cat -n: 6-char right-justified line number + two spaces + content.
        var output = ""
        output.reserveCapacity(selectedLines.count * 80)
        for (idx, line) in selectedLines.enumerated() {
            let lineNumber = startIndex + idx + 1 // back to 1-based
            output += String(format: "%6d  %@\n", lineNumber, line)
        }

        // Truncate output if it exceeds the character cap.
        if output.count > maxCharacters {
            let truncatedIndex = output.index(output.startIndex, offsetBy: maxCharacters)
            output = String(output[..<truncatedIndex])
            output += "\n\n[Output truncated at \(maxCharacters) characters]"
        }

        // Append a note if the file has more lines.
        let shownEnd = startIndex + selectedLines.count
        if shownEnd < totalLines {
            output += "\n[File has \(totalLines) total lines. Showing lines \(offset) through \(shownEnd).]"
        }

        return output
    }

    // MARK: - PDF Reading

    private static func readPDF(at url: URL, pages: String?) -> String {
        guard let document = PDFDocument(url: url) else {
            return "Error: Unable to open PDF file."
        }

        let pageCount = document.pageCount
        guard pageCount > 0 else {
            return "Error: PDF has no pages."
        }

        // Determine which pages to read.
        let pageIndices: [Int]
        if let pages {
            guard let parsed = parsePageRange(pages, totalPages: pageCount) else {
                return "Error: Invalid pages parameter '\(pages)'. Use formats like '1-5', '3', or '10-20'. PDF has \(pageCount) pages."
            }
            pageIndices = parsed
        } else if pageCount > maxAutoPages {
            return "PDF has \(pageCount) pages. Specify a pages parameter (e.g. pages='1-5') to read specific pages."
        } else {
            pageIndices = Array(0..<pageCount)
        }

        var output = ""
        for idx in pageIndices {
            guard let page = document.page(at: idx) else { continue }
            let pageText = page.string ?? "(no text content)"
            output += "--- Page \(idx + 1) ---\n\(pageText)\n\n"
        }

        if output.count > maxCharacters {
            let truncatedIndex = output.index(output.startIndex, offsetBy: maxCharacters)
            output = String(output[..<truncatedIndex])
            output += "\n\n[Output truncated at \(maxCharacters) characters]"
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parses a page range string like "1-5", "3", "10-20" into 0-based indices.
    private static func parsePageRange(_ range: String, totalPages: Int) -> [Int]? {
        let trimmed = range.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: "-", maxSplits: 1)

        guard let startStr = parts.first, let start = Int(startStr), start >= 1 else {
            return nil
        }

        let end: Int
        if parts.count == 2 {
            guard let e = Int(parts[1]), e >= start else { return nil }
            end = min(e, totalPages)
        } else {
            end = start
        }

        guard start <= totalPages else { return nil }

        return Array((start - 1)..<end) // convert to 0-based
    }

    // MARK: - Image Metadata

    private static func imageMetadata(at path: String, originalPath: String) -> String {
        let fm = FileManager.default
        let size: UInt64
        do {
            let attrs = try fm.attributesOfItem(atPath: path)
            size = attrs[.size] as? UInt64 ?? 0
        } catch {
            return "Error checking file: \(error.localizedDescription)"
        }

        let filename = (originalPath as NSString).lastPathComponent
        let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        return "Image file: \(filename) (\(sizeStr)). Image content cannot be displayed as text."
    }

    // MARK: - Binary Metadata

    private static func binaryMetadata(at path: String, originalPath: String) -> String {
        let fm = FileManager.default
        let size: UInt64
        do {
            let attrs = try fm.attributesOfItem(atPath: path)
            size = attrs[.size] as? UInt64 ?? 0
        } catch {
            return "Error checking file: \(error.localizedDescription)"
        }

        let filename = (originalPath as NSString).lastPathComponent
        let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        return "Binary file: \(filename) (\(sizeStr)). Cannot read as text."
    }

    // MARK: - Path Restrictions

    /// Returns an error message if the path is restricted, or nil if allowed.
    static func checkPathRestriction(_ path: String) -> String? {
        // Resolve relative paths AND symlinks so neither "../../../.ssh" nor symlink indirection can bypass checks
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let home = NSHomeDirectory()

        // Block sensitive credential directories.
        // Lowercase both sides: APFS is case-insensitive so /Users/FOO/.SSH bypasses a case-sensitive check.
        let sensitiveDirs = [".ssh", ".gnupg", ".aws", ".config/gcloud", ".kube", ".docker"]
        for dir in sensitiveDirs {
            let dirPath = (home as NSString).appendingPathComponent(dir)
            if resolved.lowercased().hasPrefix(dirPath.lowercased()) {
                return "BLOCKED: Cannot read sensitive credential path '\(path)'"
            }
        }

        // Block system credential files
        let systemCredentials = ["/etc/shadow", "/etc/master.passwd", "/private/etc/master.passwd"]
        for cred in systemCredentials {
            if resolved.lowercased() == cred.lowercased() || resolved.lowercased().hasPrefix(cred.lowercased()) {
                return "BLOCKED: Cannot read system credential file '\(path)'"
            }
        }

        return nil
    }

    // MARK: - Shared Read (for SecurityEvaluator)

    /// Reads a text file and returns its content with line numbers.
    /// Used by both the tool's execute method and SecurityEvaluator's Jones file reads.
    static func readFileContent(at path: String, offset: Int = 1, limit: Int = defaultLineLimit) -> String {
        if let rejection = checkPathRestriction(path) {
            return rejection
        }

        let url = URL(fileURLWithPath: path)
        let resolvedPath = url.resolvingSymlinksInPath().path
        let contentType = detectContentType(at: resolvedPath)

        switch contentType {
        case .text:
            return readText(at: url, resolvedPath: resolvedPath, offset: offset, limit: limit)
        case .pdf:
            return readPDF(at: url, pages: nil)
        case .image:
            return imageMetadata(at: resolvedPath, originalPath: path)
        case .binary:
            return binaryMetadata(at: resolvedPath, originalPath: path)
        }
    }
}
