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
