import Foundation

/// Writes content to a file. Blocks writes to sensitive system and credential paths.
struct FileWriteTool: AgentTool {
    let name = "file_write"
    let toolDescription = "Write content to a file at the given absolute path. Creates new files freely. To overwrite an existing file, you must have read it first with file_read. Requires absolute paths (starting with / or ~/). Blocks writes to sensitive system paths and hard-linked files."

    public func description(for role: AgentRole) -> String {
        switch role {
        case .brown:
            return toolDescription + " " +
                   BrownBehavior.approvalGateNote(outcome: "a success confirmation") +
                   BrownBehavior.terminationWarning
        default:
            return toolDescription
        }
    }

    let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "path": .dictionary([
                "type": .string("string"),
                "description": .string("Fully qualified (absolute) file path to write. Must start with /.")
            ]),
            "content": .dictionary([
                "type": .string("string"),
                "description": .string("The content to write to the file.")
            ])
        ]),
        "required": .array([.string("path"), .string("content")])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .brown
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard case .string(let rawPath) = arguments["path"] else {
            throw ToolCallError.missingRequiredArgument("path")
        }
        let path = PathNormalization.normalize(rawPath)
        guard case .string(let content) = arguments["content"] else {
            throw ToolCallError.missingRequiredArgument("content")
        }

        guard path.hasPrefix("/") else {
            return .failure("BLOCKED: Path must be absolute (start with /). Got: \(path)")
        }

        let url = URL(fileURLWithPath: path)
        let resolvedURL = url.resolvingSymlinksInPath()

        if let rejection = Self.checkPathRestriction(resolvedPath: resolvedURL.path) {
            return .failure(rejection)
        }
        let fm = FileManager.default
        let resolvedPath = resolvedURL.path

        // Existing files require a prior file_read to prevent blind overwrites.
        if fm.fileExists(atPath: resolvedPath) {
            guard context.hasFileBeenRead(path) || context.hasFileBeenRead(resolvedPath) else {
                return .failure("Error: File already exists at '\(path)'. You must read it with `file_read` before overwriting.")
            }
        }

        // Check for hard links — if the target file exists and has multiple hard links,
        // writing to it could silently modify data reachable from other paths.
        if fm.fileExists(atPath: resolvedPath) {
            do {
                let attrs = try fm.attributesOfItem(atPath: resolvedPath)
                if let linkCount = attrs[.referenceCount] as? Int, linkCount > 1 {
                    return .failure("BLOCKED: File '\(path)' has \(linkCount) hard links. Writing would affect all linked paths.")
                }
            } catch {
                return .failure("Error checking file attributes: \(error.localizedDescription)")
            }
        }

        do {
            let parentDir = resolvedURL.deletingLastPathComponent()
            try fm.createDirectory(
                at: parentDir,
                withIntermediateDirectories: true
            )
            try content.write(to: resolvedURL, atomically: true, encoding: .utf8)

            // Report if the path traversed symlinks so the caller knows where the file actually landed.
            if resolvedURL.path != url.standardized.path {
                return .success("File written successfully: \(path) (resolved to \(resolvedURL.path) via symlink)")
            }
            return .success("File written successfully: \(path)")
        } catch {
            return .failure("Error writing file: \(error.localizedDescription)")
        }
    }

    /// Returns an error message if the resolved path is restricted, or nil if allowed.
    /// The caller must pass a fully resolved path (symlinks already resolved).
    static func checkPathRestriction(resolvedPath resolved: String) -> String? {
        let home = NSHomeDirectory()

        // Block system directories. Entries must be bare (no trailing slash): isSubpath
        // appends its own separator, so a trailing slash here would prevent the directory
        // itself and its children from matching — opening these trees to writes.
        let systemPrefixes = [
            "/etc", "/System", "/Library", "/usr", "/bin", "/sbin",
            "/var", "/private/etc", "/private/var", "/dev"
        ]
        for prefix in systemPrefixes {
            if PathNormalization.isSubpath(resolved, ofOrEqualTo: prefix) {
                return "BLOCKED: Cannot write to system path '\(resolved)'"
            }
        }

        // Block sensitive credential/config directories in home.
        // Boundary-aware match so `~/.sshbackup` is not over-blocked as if under `~/.ssh`.
        let sensitiveDirs = [".ssh", ".gnupg", ".aws", ".config/gcloud", ".kube", ".docker"]
        for dir in sensitiveDirs {
            let dirPath = (home as NSString).appendingPathComponent(dir)
            if PathNormalization.isSubpath(resolved, ofOrEqualTo: dirPath) {
                return "BLOCKED: Cannot write to sensitive directory '\(resolved)'"
            }
        }

        // Block shell config files in home
        let shellConfigs = [
            ".zshrc", ".bashrc", ".bash_profile", ".profile",
            ".zprofile", ".zshenv", ".zlogout", ".bash_logout"
        ]
        for config in shellConfigs {
            let configPath = (home as NSString).appendingPathComponent(config)
            if resolved.lowercased() == configPath.lowercased() {
                return "BLOCKED: Cannot write to shell configuration file '\(resolved)'"
            }
        }

        return nil
    }
}
