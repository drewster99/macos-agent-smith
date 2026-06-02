import Foundation
import os

private let logger = Logger(subsystem: "AgentSmithKit", category: "MCPProcessEnvironment")

/// Builds the environment for a launched MCP subprocess.
///
/// A GUI app launched from Finder inherits a minimal `PATH` that usually omits
/// Homebrew (`/opt/homebrew/bin`, `/usr/local/bin`) and Node/`npx` install
/// locations, so commands like `npx`/`uvx`/`node` fail to launch. This resolves a
/// login-shell `PATH` once (cached) and merges it with the inherited environment
/// and the server's Keychain-resolved secret env values.
enum MCPProcessEnvironment {
    /// Cached login-shell PATH. Computed lazily on first use; the login shell is
    /// invoked at most once per process.
    private static let cachedLoginPATH = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// Common locations to guarantee on PATH even if the login shell lookup fails.
    private static let fallbackPaths = [
        "/opt/homebrew/bin", "/opt/homebrew/sbin",
        "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"
    ]

    static func childEnvironment(for config: MCPServerConfig, secretStore: MCPSecretStore) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = mergedPATH(existing: env["PATH"])
        // Keep non-interactive: never block a launched server on a credential prompt.
        env["GIT_TERMINAL_PROMPT"] = "0"

        for name in config.envVarNames {
            if let value = secretStore.secret(account: MCPSecretStore.envAccount(serverID: config.id, name: name)) {
                env[name] = value
            }
        }
        return env
    }

    /// Resolves the launch argv, substituting Keychain values for any positions the
    /// user flagged as secret.
    static func resolvedArgs(for config: MCPServerConfig, secretStore: MCPSecretStore) -> [String] {
        var args = config.args
        for index in config.secretArgIndices where index >= 0 && index < args.count {
            if let value = secretStore.secret(account: MCPSecretStore.argAccount(serverID: config.id, index: index)) {
                args[index] = value
            }
        }
        return args
    }

    private static func mergedPATH(existing: String?) -> String {
        var components: [String] = []
        var seen = Set<String>()
        func add(_ path: String) {
            guard !path.isEmpty, !seen.contains(path) else { return }
            seen.insert(path)
            components.append(path)
        }
        loginShellPATH()?.split(separator: ":").forEach { add(String($0)) }
        existing?.split(separator: ":").forEach { add(String($0)) }
        fallbackPaths.forEach { add($0) }
        return components.joined(separator: ":")
    }

    private static func loginShellPATH() -> String? {
        if let cached = cachedLoginPATH.withLock({ $0 }) { return cached.isEmpty ? nil : cached }

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let resolved = queryLoginShellPATH(shell: shell) ?? ""
        cachedLoginPATH.withLock { $0 = resolved }
        return resolved.isEmpty ? nil : resolved
    }

    private static func queryLoginShellPATH(shell: String) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: shell)
        // Login + command: sources the user's profile so Homebrew/node shims land on PATH.
        process.arguments = ["-lc", "printf '%s' \"$PATH\""]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            logger.warning("Login-shell PATH query failed to launch: \(String(describing: error), privacy: .public)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        return path
    }
}
