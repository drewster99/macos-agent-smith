import Foundation

/// User-facing configuration for a single local (stdio) MCP server.
///
/// This struct is persisted to `mcp_servers.json` and therefore holds **no secret
/// values**. Secret env values and secret command-line arguments live in the
/// Keychain (see ``MCPSecretStore``); this struct only records their *names*
/// (`envVarNames`) and *positions* (`secretArgIndices`). At launch,
/// ``MCPClientHost`` resolves those secrets and reconstructs the real environment
/// and argv.
public struct MCPServerConfig: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID

    /// Unique, user-visible name. Used to build the `mcp__<name>__<tool>` prefix
    /// exposed to the LLM, so it must be unique across configured servers.
    public var name: String

    /// Whether this server is active. A disabled server is never launched and, if
    /// already running, is torn down (its subprocess terminated) when the change
    /// is applied.
    public var enabled: Bool

    /// Executable to launch, e.g. `npx`, `node`, `uvx`, or an absolute path.
    public var command: String

    /// Arguments passed to `command`. For positions listed in `secretArgIndices`
    /// the stored value is a placeholder; the real value is resolved from the
    /// Keychain at launch.
    public var args: [String]

    /// Optional working directory for the subprocess.
    public var workingDirectory: String?

    /// Names of environment variables to inject into the subprocess. The values
    /// are stored in the Keychain (account `<id>/env/<NAME>`), never here.
    public var envVarNames: [String]

    /// Indices into `args` whose values are secret and stored in the Keychain
    /// (account `<id>/arg/<index>`). Reconstructed into argv at launch.
    public var secretArgIndices: Set<Int>

    /// Raw (unprefixed) tool names the user has disabled for this server. Disabled
    /// tools are hidden from Brown even when the server advertises them.
    public var disabledTools: Set<String>

    public init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        command: String,
        args: [String] = [],
        workingDirectory: String? = nil,
        envVarNames: [String] = [],
        secretArgIndices: Set<Int> = [],
        disabledTools: Set<String> = []
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.command = command
        self.args = args
        self.workingDirectory = workingDirectory
        self.envVarNames = envVarNames
        self.secretArgIndices = secretArgIndices
        self.disabledTools = disabledTools
    }

    /// Decodes tolerantly so that older or hand-edited `mcp_servers.json` files
    /// missing newer fields still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try c.decode(String.self, forKey: .name)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.command = try c.decode(String.self, forKey: .command)
        self.args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        self.workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory)
        self.envVarNames = try c.decodeIfPresent([String].self, forKey: .envVarNames) ?? []
        self.secretArgIndices = try c.decodeIfPresent(Set<Int>.self, forKey: .secretArgIndices) ?? []
        self.disabledTools = try c.decodeIfPresent(Set<String>.self, forKey: .disabledTools) ?? []
    }
}
