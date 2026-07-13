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

        // Both paths need the parent directory to exist first.
        do {
            try fm.createDirectory(at: resolvedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return .failure("Error creating parent directory: \(error.localizedDescription)")
        }

        let hasRead = context.hasFileBeenRead(path) || context.hasFileBeenRead(resolvedPath)

        if hasRead {
            // Brown has seen this file's contents, so overwriting is authorized — there's no gate
            // to race here. Keep the hard-link guard, then an atomic replace (crash-safe temp +
            // rename).
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
                try content.write(to: resolvedURL, atomically: true, encoding: .utf8)
            } catch {
                return .failure("Error writing file: \(error.localizedDescription)")
            }
        } else {
            // Not read → this must be a NEW file. Create it EXCLUSIVELY so the "read before
            // overwrite" gate can't be bypassed by a TOCTOU race: the old `fileExists` check and
            // the subsequent write were separate, so a file appearing in between got clobbered.
            // `O_CREAT | O_EXCL` fails atomically if the path already exists — no window.
            let fd = open(resolvedPath, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            if fd == -1 {
                if errno == EEXIST {
                    return .failure("Error: File already exists at '\(path)'. You must read it with `file_read` before overwriting.")
                }
                return .failure("Error creating file '\(path)': \(String(cString: strerror(errno)))")
            }
            defer { close(fd) }
            let data = Data(content.utf8)
            let wrote: Bool = data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return true }  // empty content → empty file
                var offset = 0
                while offset < raw.count {
                    let n = write(fd, base + offset, raw.count - offset)
                    if n > 0 { offset += n }
                    else if n == -1 && errno == EINTR { continue }
                    else { return false }
                }
                return true
            }
            if !wrote {
                let message = String(cString: strerror(errno))
                try? fm.removeItem(atPath: resolvedPath)  // don't leave a partial new file behind
                return .failure("Error writing file '\(path)': \(message)")
            }
        }

        // Report if the path traversed symlinks so the caller knows where the file actually landed.
        if resolvedURL.path != url.standardized.path {
            return .success("File written successfully: \(path) (resolved to \(resolvedURL.path) via symlink)")
        }
        return .success("File written successfully: \(path)")
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
