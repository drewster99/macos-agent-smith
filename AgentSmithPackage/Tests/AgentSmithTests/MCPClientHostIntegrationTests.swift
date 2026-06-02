import Testing
import Foundation
@testable import AgentSmithKit

/// End-to-end exercise of `MCPClientHost` against a real stdio MCP server
/// (`@modelcontextprotocol/server-everything` via `npx`). Network- and Node-dependent,
/// so it is **opt-in**: set `MCP_INTEGRATION=1` to run it. It validates the risky native
/// path — subprocess launch, login-shell PATH resolution, the StdioTransport handshake,
/// tool listing, a real tool call, and mid-call termination recovery — none of which the
/// pure unit tests cover, and without spending any LLM credits.
@Suite("MCP client host integration", .enabled(if: ProcessInfo.processInfo.environment["MCP_INTEGRATION"] == "1"))
struct MCPClientHostIntegrationTests {
    private func everythingConfig() -> MCPServerConfig {
        MCPServerConfig(
            name: "everything",
            command: "npx",
            args: ["-y", "@modelcontextprotocol/server-everything"]
        )
    }

    /// Polls `predicate` (on the host actor) until it holds or the deadline passes.
    private func waitUntil(timeout: Duration, _ predicate: @Sendable () async -> Bool) async -> Bool {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < timeout {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return await predicate()
    }

    @Test("Connects, lists tools, and calls echo")
    func connectListCall() async throws {
        let host = MCPClientHost(secretStore: MCPSecretStore())
        let config = everythingConfig()
        await host.start(configs: [config])

        let connected = await waitUntil(timeout: .seconds(60)) {
            await host.currentBridgedTools().isEmpty == false
        }
        if !connected {
            let status = await host.statusSnapshot()
            Issue.record("Status on failure: \(status)")
        }
        #expect(connected, "Server never advertised tools within the timeout")

        let tools = await host.currentBridgedTools()
        #expect(tools.contains { $0.name == "mcp__everything__echo" })

        let result = try await host.callTool(
            serverID: config.id,
            toolName: "echo",
            arguments: ["message": .string("hello mcp")]
        )
        #expect(result.isError == false)
        #expect(result.text.contains("hello mcp"))

        await host.shutdown()
    }

    @Test("A server that never completes the handshake fails instead of hanging on connecting")
    func handshakeTimeout() async throws {
        // `cat` launches fine and stays alive reading stdin, but never speaks MCP — the
        // handshake can never complete. Without the connect deadline this hangs forever.
        let host = MCPClientHost(secretStore: MCPSecretStore())
        let config = MCPServerConfig(name: "stuck", command: "cat", args: [])
        await host.start(configs: [config])

        let failed = await waitUntil(timeout: .seconds(90)) {
            await host.statusSnapshot()[config.id]?.state == .failed
        }
        #expect(failed, "Stuck server should transition to .failed via the connect deadline")
        #expect(await host.currentBridgedTools().isEmpty)
        await host.shutdown()
    }

    @Test("Disabling a server mid-session terminates it and frees its tools")
    func terminationRecovery() async throws {
        let host = MCPClientHost(secretStore: MCPSecretStore())
        let config = everythingConfig()
        await host.start(configs: [config])

        let connected = await waitUntil(timeout: .seconds(120)) {
            await host.currentBridgedTools().isEmpty == false
        }
        #expect(connected)

        // Disable the server; its subprocess is terminated and its tools disappear.
        await host.applyConfigChange(configs: [])
        let cleared = await waitUntil(timeout: .seconds(10)) {
            await host.currentBridgedTools().isEmpty
        }
        #expect(cleared, "Tools were not cleared after the server was disabled")

        // A call to the now-terminated server surfaces an error rather than hanging.
        await #expect(throws: (any Error).self) {
            _ = try await host.callTool(serverID: config.id, toolName: "echo", arguments: ["message": .string("x")])
        }

        await host.shutdown()
    }
}
