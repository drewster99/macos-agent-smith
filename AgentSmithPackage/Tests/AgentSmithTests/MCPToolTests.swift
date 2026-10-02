import Testing
import Foundation
import MCP
import SwiftLLMKit
@testable import AgentSmithKit

@Suite("MCP tool naming")
struct MCPToolNamingTests {
    @Test("Prefixes server and tool")
    func basicPrefix() {
        #expect(MCPToolNaming.prefixedName(server: "filesystem", tool: "read_file") == "mcp__filesystem__read_file")
    }

    @Test("Sanitizes disallowed characters to underscores")
    func sanitizes() {
        let name = MCPToolNaming.prefixedName(server: "My Server", tool: "do.it!")
        #expect(name == "mcp__My_Server__do_it")
    }

    @Test("Never blank components")
    func neverBlank() {
        let name = MCPToolNaming.prefixedName(server: "***", tool: "@@@")
        #expect(name == "mcp__x__x")
    }

    @Test("Caps total length at the provider limit")
    func lengthCap() {
        let longTool = String(repeating: "a", count: 200)
        let name = MCPToolNaming.prefixedName(server: "srv", tool: longTool)
        #expect(name.count <= MCPToolNaming.maxNameLength)
        #expect(name.hasPrefix("mcp__srv__"))
    }

    @Test("Disambiguation does not mask a server's real tool names")
    func disambiguationReservesCurrentServerToolNames() {
        var usedNames = Set<String>()
        _ = MCPClientHost.assignPrefixedToolNames(
            serverName: "My Server",
            toolNames: ["foo"],
            usedNames: &usedNames
        )

        let secondServer = MCPClientHost.assignPrefixedToolNames(
            serverName: "My_Server",
            toolNames: ["foo", "foo_2"],
            usedNames: &usedNames
        )

        #expect(secondServer == ["mcp__My_Server__foo_3", "mcp__My_Server__foo_2"])
    }

    /// `components(of:)` is the exact inverse of `prefixedName` — the transcript filter groups MCP
    /// tools by server with it — including sanitized names, single underscores and dashes in
    /// either part, and the disambiguation suffix `assignPrefixedToolNames` appends.
    @Test func componentsInvertPrefixedName() {
        let cases: [(server: String, tool: String)] = [
            ("mac-control", "menu_pick"), ("My Server", "do.it!"), ("filesystem", "read_file"),
            ("a_b", "c_d_e"), ("***", "@@@")
        ]
        for (server, tool) in cases {
            let parts = MCPToolNaming.components(of: MCPToolNaming.prefixedName(server: server, tool: tool))
            #expect(parts?.server == MCPToolNaming.sanitizeComponent(server))
            #expect(parts?.tool == MCPToolNaming.sanitizeComponent(tool))
        }
        #expect(MCPToolNaming.components(of: "mcp__My_Server__foo_3")?.tool == "foo_3")
        #expect(MCPToolNaming.components(of: "mcp__My_Server__foo_3")?.server == "My_Server")
        let long = MCPToolNaming.prefixedName(server: "srv", tool: String(repeating: "t", count: 200))
        #expect(MCPToolNaming.components(of: long)?.server == "srv")
    }

    @Test func componentsRejectNamesThatAreNotOurs() {
        #expect(MCPToolNaming.components(of: "file_read") == nil)
        #expect(MCPToolNaming.components(of: "mcp__noseparator") == nil)
        #expect(MCPToolNaming.components(of: "mcp____tool") == nil)
        #expect(MCPToolNaming.components(of: "mcp__srv__") == nil)
    }

    private static func isProviderValid(_ name: String) -> Bool {
        name.count <= MCPToolNaming.maxNameLength
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    @Test("A long server name keeps the separator and part of every tool name")
    func longServerKeepsSeparator() {
        let server = String(repeating: "s", count: 60)
        let s49 = String(repeating: "s", count: 49)
        let read = MCPToolNaming.prefixedName(server: server, tool: "read_file")
        let write = MCPToolNaming.prefixedName(server: server, tool: "write_file")
        #expect(read == "mcp__\(s49)__read_fil")
        #expect(write == "mcp__\(s49)__write_fi")
        #expect(MCPToolNaming.components(of: read)?.server == s49)
        #expect(MCPToolNaming.components(of: read)?.tool == "read_fil")
    }

    @Test("A truncated server slug never ends in a separator character")
    func truncatedSlugIsRetrimmed() {
        let q48 = String(repeating: "q", count: 48)
        let name = MCPToolNaming.prefixedName(server: q48 + "_x", tool: "read")
        #expect(name == "mcp__\(q48)__read")
        #expect(MCPToolNaming.components(of: name)?.server == q48)
    }

    @Test("Disambiguating a name already at the cap stays within the cap")
    func disambiguatedCappedNameFits() {
        var used = Set<String>()
        let long = String(repeating: "a", count: 200)
        let names = MCPClientHost.assignPrefixedToolNames(serverName: "srv", toolNames: [long, long], usedNames: &used)
        #expect(names == [
            "mcp__srv__" + String(repeating: "a", count: 52) + "_2",
            "mcp__srv__" + String(repeating: "a", count: 54)
        ])
        #expect(names.allSatisfy(Self.isProviderValid))
    }

    @Test("A truncated tool part ending in _ still splits at the server separator")
    func truncatedToolPartEndingInUnderscore() {
        let q49 = String(repeating: "q", count: 49)
        let name = MCPToolNaming.prefixedName(server: q49, tool: "ttttt_hij", disambiguationOrdinal: 2)
        #expect(name == "mcp__\(q49)__ttttt__2")
        #expect(MCPToolNaming.components(of: name)?.server == q49)
        #expect(MCPToolNaming.components(of: name)?.tool == "ttttt__2")
    }

    @Test("Every composed name is provider-valid, invertible, and keeps its ordinal and server slug")
    func composedNamesProperties() {
        let servers = ["srv", "My Server", String(repeating: "s", count: 49), String(repeating: "s", count: 50),
                       String(repeating: "s", count: 56), String(repeating: "s", count: 57),
                       String(repeating: "s", count: 200), String(repeating: "q", count: 48) + "_x", "***", "日本語 server"]
        let tools = ["read_file", "x", String(repeating: "t", count: 200), "ttttt_hij", "@@@", "foo_2"]
        for server in servers {
            for tool in tools {
                let base = MCPToolNaming.prefixedName(server: server, tool: tool)
                #expect(Self.isProviderValid(base))
                let baseParts = MCPToolNaming.components(of: base)
                #expect(baseParts != nil)
                for ordinal in [2, 3, 10, 99, 999_999, 1_000_000, Int.max] {
                    let name = MCPToolNaming.prefixedName(server: server, tool: tool, disambiguationOrdinal: ordinal)
                    #expect(Self.isProviderValid(name))
                    #expect(name.hasSuffix("_\(ordinal)"))
                    let parts = MCPToolNaming.components(of: name)
                    #expect(parts != nil)
                    if ordinal < 1_000_000 { #expect(parts?.server == baseParts?.server) }
                }
            }
        }
    }

    @Test("Heavy collisions on a long server name all resolve to unique valid names")
    func heavyCollisionsResolve() {
        var used = Set<String>()
        let names = MCPClientHost.assignPrefixedToolNames(
            serverName: String(repeating: "z", count: 100),
            toolNames: Array(repeating: String(repeating: "t", count: 100), count: 500),
            usedNames: &used
        )
        #expect(Set(names).count == names.count)
        #expect(names.allSatisfy { Self.isProviderValid($0) && MCPToolNaming.components(of: $0) != nil })
    }

    /// Persisted tool policies and per-task overrides are keyed by these names; any server slug of
    /// `maxServerSlugLength` or fewer characters must keep producing exactly what it always did.
    @Test("Names for slugs within the cap are unchanged")
    func unchangedNamesPinned() {
        let q49 = String(repeating: "q", count: 49)
        #expect(MCPToolNaming.prefixedName(server: q49, tool: "abcdefghijk") == "mcp__\(q49)__abcdefgh")
        #expect(MCPToolNaming.prefixedName(server: "srv", tool: String(repeating: "a", count: 200))
            == "mcp__srv__" + String(repeating: "a", count: 54))
        #expect(MCPToolNaming.prefixedName(server: "filesystem", tool: "read_file", disambiguationOrdinal: 2)
            == "mcp__filesystem__read_file_2")
        #expect(MCPToolNaming.maxServerSlugLength == 49)
    }

    @Test("No built-in tool name can collide with an MCP name")
    func builtInsNeverUseMCPPrefix() {
        let builtIns = BrownBehavior.toolNames + SmithBehavior.toolNames + SecurityAgentBehavior.toolNames
        #expect(!builtIns.contains { $0.hasPrefix(MCPToolNaming.prefix) })
    }
}

@Suite("MCP value conversion")
struct MCPValueConversionTests {
    @Test("AnyCodable round-trips through Value for arguments")
    func argsConversion() {
        let args: [String: AnyCodable] = [
            "s": .string("hi"),
            "n": .int(3),
            "f": .double(1.5),
            "b": .bool(true),
            "arr": .array([.int(1), .int(2)]),
            "obj": .dictionary(["k": .string("v")])
        ]
        let values = MCPValueConversion.values(from: args)
        #expect(values["s"] == .string("hi"))
        #expect(values["n"] == .int(3))
        #expect(values["f"] == .double(1.5))
        #expect(values["b"] == .bool(true))
        #expect(values["arr"] == .array([.int(1), .int(2)]))
        #expect(values["obj"] == .object(["k": .string("v")]))
    }

    @Test("Object schema maps to AnyCodable dictionary")
    func schemaFromObject() {
        let schema: Value = .object([
            "type": .string("object"),
            "properties": .object(["path": .object(["type": .string("string")])])
        ])
        let params = MCPValueConversion.parametersSchema(from: schema)
        #expect(params["type"] == .string("object"))
        if case .dictionary(let props)? = params["properties"] {
            #expect(props["path"] != nil)
        } else {
            Issue.record("properties did not convert to a dictionary")
        }
    }

    @Test("Nil or non-object schema yields a permissive object schema")
    func schemaFromNil() {
        let params = MCPValueConversion.parametersSchema(from: nil)
        #expect(params["type"] == .string("object"))
        #expect(params["properties"] != nil)
    }
}

private final class FakeSecretWriter: MCPSecretWriting, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var saved: [String: String] = [:]
    func save(_ secret: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        saved[account] = secret
    }
}

@Suite("MCP config import")
struct MCPConfigImportTests {
    @Test("Parses standard blob and routes env values to the secret store")
    func parsesBlob() throws {
        let json = """
        {
          "mcpServers": {
            "fs": {
              "command": "npx",
              "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
              "env": { "API_KEY": "secret-value" }
            }
          }
        }
        """
        let store = FakeSecretWriter()
        let outcome = try MCPConfigImport.parse(json: json, existingNames: [], secretStore: store)
        #expect(outcome.configs.count == 1)
        let cfg = try #require(outcome.configs.first)
        #expect(cfg.name == "fs")
        #expect(cfg.command == "npx")
        #expect(cfg.args == ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"])
        #expect(cfg.envVarNames == ["API_KEY"])
        // Env value routed to keychain, keyed by this config's id.
        let account = MCPSecretStore.envAccount(serverID: cfg.id, name: "API_KEY")
        #expect(store.saved[account] == "secret-value")
    }

    @Test("Makes server names unique against existing names")
    func uniqueNames() throws {
        let json = """
        { "mcpServers": { "fs": { "command": "npx" } } }
        """
        let outcome = try MCPConfigImport.parse(json: json, existingNames: ["fs"], secretStore: FakeSecretWriter())
        #expect(outcome.configs.first?.name == "fs 2")
    }

    @Test("Skips entries without a command, with a warning")
    func skipsNoCommand() throws {
        let json = """
        { "mcpServers": { "bad": { "args": ["x"] }, "good": { "command": "node" } } }
        """
        let outcome = try MCPConfigImport.parse(json: json, existingNames: [], secretStore: FakeSecretWriter())
        #expect(outcome.configs.count == 1)
        #expect(outcome.configs.first?.name == "good")
        #expect(!outcome.warnings.isEmpty)
    }

    @Test("Throws on invalid JSON")
    func invalidJSON() {
        #expect(throws: (any Error).self) {
            try MCPConfigImport.parse(json: "not json", existingNames: [], secretStore: FakeSecretWriter())
        }
    }

    @Test("Throws when no mcpServers present")
    func noServers() {
        #expect(throws: (any Error).self) {
            try MCPConfigImport.parse(json: "{ \"other\": {} }", existingNames: [], secretStore: FakeSecretWriter())
        }
    }
}

@Suite("MCP secret store accounts")
struct MCPSecretAccountTests {
    @Test("Env and arg accounts are namespaced by server id")
    func accounts() {
        let id = UUID()
        #expect(MCPSecretStore.envAccount(serverID: id, name: "TOKEN") == "\(id.uuidString)/env/TOKEN")
        #expect(MCPSecretStore.argAccount(serverID: id, index: 2) == "\(id.uuidString)/arg/2")
    }
}
