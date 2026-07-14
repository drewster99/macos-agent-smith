import Foundation

/// Bounded "shape of a directory" view: a box-drawing tree of *directories only*, depth-limited,
/// with VCS/build/dependency dirs and other opaque packages pruned. Per-leaf annotations tell the
/// LLM why a node wasn't expanded — depth limit, prune-list, or simply "no subdirs (N files)".
///
/// Gives the LLM cheap structural awareness before it picks a `path` for `glob`. For listing files
/// in a specific directory, use `directory_listing`.
struct DirectoryTreeTool: AgentTool {
    let name = "directory_tree"

    var toolDescription: String {
        "Show the directory structure (folders only) under `path`, as a box-drawing tree to `max_depth` (default 3, max 6). " + FilesystemSearch.pruneSummary + " Annotates each non-expanded leaf with a file count, `(pruned ...)`, or `(raise max_depth to expand)`. Use `directory_listing` to see files in a specific directory, or `glob` to find files by pattern."
    }

    public func description(for role: AgentRole) -> String {
        switch role {
        case .brown:
            return toolDescription + " " + BrownBehavior.approvalGateNote(outcome: "a directory tree")
        default:
            return toolDescription
        }
    }

    let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "path": .dictionary([
                "type": .string("string"),
                "description": .string("Absolute or ~-prefixed directory to render. Resolving exactly to ~/$HOME or a system root like / or /System is refused as too broad.")
            ]),
            "max_depth": .dictionary([
                "type": .string("integer"),
                "description": .string("Maximum recursion depth. Default 3, clamped to [1, 6]. Depth 1 = immediate subdirectories only.")
            ])
        ]),
        "required": .array([.string("path")])
    ]

    var executionTimeout: Duration { .seconds(30) }

    /// Fixed internal budgets — `max_depth` is the natural bound; these are runaway guards.
    private static let walkDeadlineSeconds: Double = 10
    private static let maxEntriesScanned: Int = 20_000
    private static let defaultMaxDepth: Int = 3
    private static let maxAllowedDepth: Int = 6

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard case .string(let rawPath) = arguments["path"] else {
            throw ToolCallError.missingRequiredArgument("path")
        }
        let maxDepth: Int
        if case .int(let v) = arguments["max_depth"] {
            maxDepth = max(1, min(v, Self.maxAllowedDepth))
        } else if case .double(let v) = arguments["max_depth"] {
            maxDepth = max(1, min(Int(v), Self.maxAllowedDepth))
        } else {
            maxDepth = Self.defaultMaxDepth
        }

        let expanded = (rawPath as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            return .failure("`path` must be absolute (start with / or ~/). Got: \(rawPath)")
        }
        let resolvedBase = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
        if FilesystemSearch.isOverlyBroadRoot(resolvedBase) {
            return .failure("Refusing to render '\(expanded)' — that root is far too broad. Pass a specific project or subdirectory.")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedBase, isDirectory: &isDir), isDir.boolValue else {
            return .failure("Directory does not exist: \(expanded)")
        }

        let homePruneSet = FilesystemSearch.homePruneAbsolutePaths(forBase: resolvedBase)
        let deadline = Date().addingTimeInterval(Self.walkDeadlineSeconds)
        var lines: [String] = []
        lines.append(resolvedBase + "/")
        var entriesScanned = 0
        var truncated: TruncationReason? = nil

        // Recurse — directories only.
        let topSubdirs = subdirectories(of: resolvedBase, homePruneSet: homePruneSet)
        for (i, child) in topSubdirs.enumerated() {
            if let reason = checkBudget(scanned: entriesScanned, deadline: deadline) {
                truncated = reason
                break
            }
            entriesScanned += 1
            let isLast = (i == topSubdirs.count - 1)
            renderSubtree(
                dir: child, base: resolvedBase, prefix: "", isLast: isLast, depth: 1, maxDepth: maxDepth,
                homePruneSet: homePruneSet, deadline: deadline,
                entriesScanned: &entriesScanned, truncated: &truncated, lines: &lines
            )
            if truncated != nil { break }
        }

        if let reason = truncated {
            lines.append("[Truncated: \(reason.message) — pass a narrower `path`.]")
        }
        lines.append("")
        lines.append("Use `directory_listing` to see files in a specific directory, or `glob` to find files by pattern.")

        return .success(lines.joined(separator: "\n"))
    }

    // MARK: - Rendering

    private enum TruncationReason {
        case timeLimit
        case scanLimit
        case cancelled

        var message: String {
            switch self {
            case .timeLimit: "exceeded \(Int(DirectoryTreeTool.walkDeadlineSeconds))s walk budget"
            case .scanLimit: "scan cap of \(DirectoryTreeTool.maxEntriesScanned) directory visits reached"
            case .cancelled: "cancelled (agent-level timeout)"
            }
        }
    }

    private static func fileCountPhrase(_ n: Int) -> String {
        n == 1 ? "1 file" : "\(n) files"
    }
    private static func subdirCountPhrase(_ n: Int) -> String {
        n == 1 ? "1 subdir" : "\(n) subdirs"
    }

    private func checkBudget(scanned: Int, deadline: Date) -> TruncationReason? {
        if scanned > Self.maxEntriesScanned { return .scanLimit }
        if Task.isCancelled { return .cancelled }
        if Date() >= deadline { return .timeLimit }
        return nil
    }

    private func renderSubtree(
        dir: URL, base: String, prefix: String, isLast: Bool, depth: Int, maxDepth: Int,
        homePruneSet: Set<String>, deadline: Date,
        entriesScanned: inout Int, truncated: inout TruncationReason?, lines: inout [String]
    ) {
        let connector = isLast ? "└── " : "├── "
        let nextPrefix = prefix + (isLast ? "    " : "│   ")
        let name = dir.lastPathComponent
        let dirLineBase = prefix + connector + name + "/"

        // Symlink-escape guard: if this entry resolves outside the tree root, don't
        // descend into (or count) a foreign subtree.
        let resolved = dir.resolvingSymlinksInPath().path
        guard resolved == base || resolved.hasPrefix(base + "/") else {
            lines.append(dirLineBase + "  (skipped — symlink outside the tree root)")
            return
        }

        // Pruned directory: render with `(pruned)` annotation, don't descend.
        let absPath = dir.path
        if FilesystemSearch.shouldPruneDirectory(absolutePath: absPath, name: name, homePruneSet: homePruneSet) {
            lines.append(dirLineBase + "  (pruned — build/cache/VCS/package dir)")
            return
        }

        // Read this dir's contents once so we can annotate it cheaply (file count, subdir count).
        let counts = directoryCounts(at: dir)

        // Depth-limit frontier: render with `(raise max_depth to expand)` annotation if there's more.
        if depth >= maxDepth {
            if counts.subdirs > 0 {
                lines.append(dirLineBase + "  (\(Self.fileCountPhrase(counts.files)), \(Self.subdirCountPhrase(counts.subdirs)) — raise max_depth to expand)")
            } else if counts.files > 0 {
                lines.append(dirLineBase + "  (\(Self.fileCountPhrase(counts.files)))")
            } else {
                lines.append(dirLineBase + "  (empty)")
            }
            return
        }

        // True leaf (no subdirs to descend into): annotate with the file count.
        if counts.subdirs == 0 {
            if counts.files > 0 {
                lines.append(dirLineBase + "  (\(Self.fileCountPhrase(counts.files)))")
            } else {
                lines.append(dirLineBase + "  (empty)")
            }
            return
        }

        // Expand: render the line plain (its children will appear below), then recurse.
        lines.append(dirLineBase)
        let subs = subdirectories(of: absPath, homePruneSet: homePruneSet)
        for (i, child) in subs.enumerated() {
            if let reason = checkBudget(scanned: entriesScanned, deadline: deadline) {
                truncated = reason
                return
            }
            entriesScanned += 1
            let childIsLast = (i == subs.count - 1)
            renderSubtree(
                dir: child, base: base, prefix: nextPrefix, isLast: childIsLast, depth: depth + 1, maxDepth: maxDepth,
                homePruneSet: homePruneSet, deadline: deadline,
                entriesScanned: &entriesScanned, truncated: &truncated, lines: &lines
            )
            if truncated != nil { return }
        }
    }

    // MARK: - Filesystem helpers

    /// Returns the immediate subdirectories of `path`, sorted by name. Hidden dotdirs are skipped
    /// except for `.git` (which we annotate as pruned but still surface so the LLM sees it exists).
    private func subdirectories(of path: String, homePruneSet: Set<String>) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var dirs: [URL] = []
        // Re-include `.git` even though it's hidden — we want to show it (as pruned) so the LLM
        // sees the repo's existence at a glance.
        if let gitURL = explicitGitURL(at: path) {
            dirs.append(gitURL)
        }
        for entry in entries {
            let values: URLResourceValues
            do {
                values = try entry.resourceValues(forKeys: [.isDirectoryKey])
            } catch { continue }
            if values.isDirectory == true {
                dirs.append(entry)
            }
        }
        dirs.sort { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        return dirs
    }

    /// Returns `~/some/dir/.git` as a URL iff it exists. Used so `.git` shows up alongside the
    /// hidden-skipping enumerator results without enabling all dotdirs.
    private func explicitGitURL(at parent: String) -> URL? {
        let gitPath = parent + "/.git"
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: gitPath)
    }

    /// File/subdir counts in a single directory listing — cheap enough to call per displayed node.
    /// Hidden dotfiles are *not* counted (`.skipsHiddenFiles`), matching the tree's enumeration —
    /// except `.git`, which `subdirectories(of:)` re-includes as a (pruned) child, so it's counted
    /// here too to keep a node's `(N subdirs)` annotation consistent with the children rendered
    /// beneath it.
    private func directoryCounts(at dir: URL) -> (files: Int, subdirs: Int) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return (0, 0) }
        var files = 0
        var subdirs = 0
        for e in entries {
            let v: URLResourceValues
            do {
                v = try e.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            } catch { continue }
            if v.isRegularFile == true {
                files += 1
            } else if v.isDirectory == true {
                subdirs += 1
            }
        }
        if explicitGitURL(at: dir.path) != nil { subdirs += 1 }
        return (files, subdirs)
    }
}
