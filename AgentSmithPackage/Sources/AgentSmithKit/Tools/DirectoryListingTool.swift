import Foundation

/// Single-directory listing: every entry in `path` with its type, size, and modification time.
/// No recursion, no prune-list — a flat listing shows what's actually there, including
/// `node_modules` / `.git` (subject only to `show_hidden_files` and the optional `filter`).
///
/// Use `directory_tree` for a recursive shape view, or `glob` to find files by pattern.
struct DirectoryListingTool: AgentTool {
    let name = "directory_listing"

    var toolDescription: String {
        "List the entries in `path` — every file and folder at that one level, with type, size, and mtime. No recursion. Optional basename glob `filter` (e.g. `*.swift`), `sort` (mtime/name), `limit` (default 50, max 200), `offset` (for paging past the cap), and `show_hidden_files` (default false). Use `directory_tree` for a recursive shape view, or `glob` to find files by pattern."
    }

    public func description(for role: AgentRole) -> String {
        switch role {
        case .brown:
            return toolDescription + " " + BrownBehavior.approvalGateNote(outcome: "the directory listing")
        default:
            return toolDescription
        }
    }

    let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "path": .dictionary([
                "type": .string("string"),
                "description": .string("Absolute or ~-prefixed directory to list.")
            ]),
            "filter": .dictionary([
                "type": .string("string"),
                "description": .string("Optional glob matched against the *basename* of each entry (e.g. `*.swift`, `test*`, `*.{ts,tsx}`).")
            ]),
            "sort": .dictionary([
                "type": .string("string"),
                "description": .string("\"mtime\" (default, newest first) or \"name\" (alphabetical)."),
                "enum": .array([.string("mtime"), .string("name")])
            ]),
            "limit": .dictionary([
                "type": .string("integer"),
                "description": .string("Max entries to return. Default 50, max 200.")
            ]),
            "offset": .dictionary([
                "type": .string("integer"),
                "description": .string("Skip the first N entries. Use to page past `limit`. Default 0.")
            ]),
            "show_hidden_files": .dictionary([
                "type": .string("boolean"),
                "description": .string("When true, include entries whose name starts with '.'. Default false.")
            ])
        ]),
        "required": .array([.string("path")])
    ]

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .brown
    }

    var executionTimeout: Duration { .seconds(120) }

    private static let defaultLimit = 50
    private static let maxAllowedLimit = 200

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard case .string(let rawPath) = arguments["path"] else {
            throw ToolCallError.missingRequiredArgument("path")
        }
        let filterGlob: String? = {
            if case .string(let s) = arguments["filter"], !s.isEmpty { return s }
            return nil
        }()
        let sortBy: SortKey = {
            if case .string(let s) = arguments["sort"], s == "name" { return .name }
            return .mtime
        }()
        let limit: Int = {
            let raw: Int
            if case .int(let v) = arguments["limit"] { raw = v }
            else if case .double(let v) = arguments["limit"] { raw = Int(v) }
            else { raw = Self.defaultLimit }
            return max(1, min(raw, Self.maxAllowedLimit))
        }()
        let offset: Int = {
            let raw: Int
            if case .int(let v) = arguments["offset"] { raw = v }
            else if case .double(let v) = arguments["offset"] { raw = Int(v) }
            else { raw = 0 }
            return max(0, raw)
        }()
        let showHidden: Bool = {
            if case .bool(let b) = arguments["show_hidden_files"] { return b }
            return false
        }()

        let expanded = (rawPath as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            return .failure("`path` must be absolute (start with / or ~/). Got: \(rawPath)")
        }
        let resolvedBase = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedBase, isDirectory: &isDir), isDir.boolValue else {
            return .failure("Directory does not exist: \(expanded)")
        }

        // Compile filter glob once.
        let filterRegex: NSRegularExpression?
        if let filterGlob {
            do {
                filterRegex = try NSRegularExpression(pattern: "^\(GlobTool.globToRegex(filterGlob))$")
            } catch {
                return .failure("Invalid `filter` glob '\(filterGlob)': \(error.localizedDescription)")
            }
        } else {
            filterRegex = nil
        }

        // Read the directory (no recursion).
        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: resolvedBase),
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey, .fileSizeKey],
            options: options
        ) else {
            return .failure("Unable to read directory: \(expanded)")
        }

        var rows: [EntryRow] = []
        rows.reserveCapacity(entries.count)
        for entry in entries {
            let name = entry.lastPathComponent
            if let filterRegex {
                let r = NSRange(name.startIndex..<name.endIndex, in: name)
                guard filterRegex.firstMatch(in: name, range: r) != nil else { continue }
            }
            let values: URLResourceValues
            do {
                values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey, .fileSizeKey])
            } catch { continue }
            let kind: EntryKind
            if values.isDirectory == true { kind = .directory }
            else if values.isRegularFile == true { kind = .file }
            else { kind = .other }
            rows.append(EntryRow(
                name: name,
                kind: kind,
                size: values.fileSize ?? 0,
                mtime: values.contentModificationDate ?? Date.distantPast
            ))
        }

        // Sort: dirs first within the chosen sort.
        rows.sort { a, b in
            if a.kind.isDir != b.kind.isDir {
                return a.kind.isDir
            }
            switch sortBy {
            case .mtime:
                return a.mtime > b.mtime
            case .name:
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }

        let total = rows.count
        let dirsTotal = rows.lazy.filter(\.kind.isDir).count
        let filesTotal = rows.lazy.filter { $0.kind == .file }.count

        // Empty / filter-empty / offset past end.
        if total == 0 {
            if filterGlob != nil {
                return .success("\(resolvedBase)/ has no entries matching '\(filterGlob ?? "")'.")
            }
            return .success("\(resolvedBase)/ is empty.")
        }
        if offset >= total {
            return .success("\(resolvedBase)/ has only \(total) \(total == 1 ? "entry" : "entries") (offset \(offset) is past the end). Use a smaller `offset`.")
        }

        let upper = min(offset + limit, total)
        let page = Array(rows[offset..<upper])

        var lines: [String] = []
        let filterSuffix = filterGlob.map { " matching '\($0)'" } ?? ""
        let sortStr = (sortBy == .mtime) ? "mtime (newest first)" : "name"
        lines.append("Contents of \(resolvedBase)/  —  \(total) \(total == 1 ? "entry" : "entries")\(filterSuffix) (\(dirsTotal) dirs, \(filesTotal) files), showing \(offset + 1)–\(upper), sorted by \(sortStr):")
        for row in page {
            lines.append("  " + formatRow(row))
        }
        if upper < total {
            let remaining = total - upper
            lines.append("[\(remaining) more \(remaining == 1 ? "entry" : "entries") not shown — call directory_listing again with offset=\(upper)\(filterGlob == nil ? ", or pass a `filter`" : "").]")
        }
        return .success(lines.joined(separator: "\n"))
    }

    // MARK: - Row rendering

    private enum SortKey { case mtime, name }

    private enum EntryKind: Equatable {
        case file, directory, other
        var isDir: Bool { self == .directory }
        var glyph: String {
            switch self {
            case .file: "f"
            case .directory: "d"
            case .other: "?"
            }
        }
    }

    private struct EntryRow {
        let name: String
        let kind: EntryKind
        let size: Int
        let mtime: Date
    }

    private static let mtimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = TimeZone.current
        return f
    }()

    private func formatRow(_ row: EntryRow) -> String {
        let glyph = row.kind.glyph
        let size = (row.kind == .file) ? formatSize(row.size) : "-"
        let mtime = Self.mtimeFormatter.string(from: row.mtime)
        let nameSuffix = row.kind == .directory ? "/" : ""
        return "\(glyph)  \(size.padding(toLength: 7, withPad: " ", startingAt: 0))  \(mtime)  \(row.name)\(nameSuffix)"
    }

    private func formatSize(_ bytes: Int) -> String {
        let units = ["B", "K", "M", "G", "T"]
        var size = Double(bytes)
        var unit = 0
        while size >= 1024 && unit < units.count - 1 {
            size /= 1024
            unit += 1
        }
        if unit == 0 {
            return "\(Int(size))\(units[unit])"
        }
        if size >= 100 {
            return String(format: "%.0f%@", size, units[unit])
        }
        return String(format: "%.1f%@", size, units[unit])
    }
}
