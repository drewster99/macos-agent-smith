import Foundation

/// Parses the standard `{ "mcpServers": { … } }` configuration blob that vendors
/// publish for Claude Desktop / Cursor and turns it into ``MCPServerConfig`` values.
///
/// Every `env` value found in the blob is treated as a secret and written to the
/// Keychain via ``MCPSecretStore`` (only the variable *names* are retained in the
/// returned config). Server names are made unique against `existingNames` and
/// within the imported batch so they remain valid as tool-name prefixes.
public enum MCPConfigImport {
    public struct Outcome: Sendable {
        public var configs: [MCPServerConfig]
        public var warnings: [String]
    }

    private struct Blob: Decodable { let mcpServers: [String: Entry] }
    private struct Entry: Decodable {
        let command: String?
        let args: [String]?
        let env: [String: String]?
        let cwd: String?
        let workingDirectory: String?
    }

    public enum ImportError: Error, Sendable, CustomStringConvertible {
        case invalidJSON(String)
        case noServers

        public var description: String {
            switch self {
            case .invalidJSON(let detail): return "Could not parse JSON: \(detail)"
            case .noServers: return "No \"mcpServers\" object found in the pasted JSON."
            }
        }
    }

    /// Parses `json`, persisting secrets to `secretStore`. Returns the new configs
    /// plus any non-fatal warnings (e.g. entries skipped for missing a command).
    public static func parse(
        json: String,
        existingNames: Set<String>,
        secretStore: any MCPSecretWriting
    ) throws -> Outcome {
        guard let data = json.data(using: .utf8) else {
            throw ImportError.invalidJSON("not valid UTF-8")
        }
        let blob: Blob
        do {
            blob = try JSONDecoder().decode(Blob.self, from: data)
        } catch {
            throw ImportError.invalidJSON(String(describing: error))
        }
        guard !blob.mcpServers.isEmpty else { throw ImportError.noServers }

        var taken = existingNames
        var configs: [MCPServerConfig] = []
        var warnings: [String] = []

        // Stable ordering so repeated imports are deterministic.
        for rawName in blob.mcpServers.keys.sorted() {
            guard let entry = blob.mcpServers[rawName] else { continue }
            guard let command = entry.command, !command.isEmpty else {
                warnings.append("Skipped \"\(rawName)\": no \"command\" specified.")
                continue
            }
            let uniqueName = makeUnique(rawName, taken: taken)
            taken.insert(uniqueName)

            let id = UUID()
            var envNames: [String] = []
            for (key, value) in (entry.env ?? [:]).sorted(by: { $0.key < $1.key }) {
                do {
                    try secretStore.save(value, account: MCPSecretStore.envAccount(serverID: id, name: key))
                    envNames.append(key)
                } catch {
                    warnings.append("Could not store secret env \"\(key)\" for \"\(uniqueName)\" in Keychain.")
                }
            }

            configs.append(MCPServerConfig(
                id: id,
                name: uniqueName,
                enabled: true,
                command: command,
                args: entry.args ?? [],
                workingDirectory: entry.workingDirectory ?? entry.cwd,
                envVarNames: envNames,
                secretArgIndices: [],
                disabledTools: []
            ))
        }

        if configs.isEmpty { throw ImportError.noServers }
        return Outcome(configs: configs, warnings: warnings)
    }

    private static func makeUnique(_ base: String, taken: Set<String>) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "server" : trimmed
        if !taken.contains(name) { return name }
        var n = 2
        while taken.contains("\(name) \(n)") { n += 1 }
        return "\(name) \(n)"
    }
}
