import Foundation
import os
import System
import MCP
import SwiftLLMKit

private let logger = Logger(subsystem: "AgentSmithKit", category: "MCPClientHost")

/// Live connection status for a configured MCP server, surfaced to the settings UI.
public struct MCPServerStatus: Sendable, Equatable {
    public enum State: String, Sendable, Equatable {
        case connecting
        case connected
        case failed
        case disabled
    }
    public var state: State
    /// Number of tools currently exposed to Brown (after per-tool filtering).
    public var toolCount: Int
    /// Error summary when `state == .failed`.
    public var error: String?
    /// Tail of the server's stderr, for debugging bad configs.
    public var stderrTail: String?
    /// Raw (unprefixed) tool names the server advertised, for the per-tool toggle UI.
    public var advertisedToolNames: [String]
    /// Per-tool descriptions (unprefixed tool name → description) the server advertised, for the
    /// settings UI. Empty when a tool declared no description.
    public var toolDescriptions: [String: String]
    /// The server's own description / usage notes, from the MCP `initialize` response's
    /// `instructions` field. `nil` when the server didn't provide any.
    public var serverInstructions: String?

    public init(
        state: State,
        toolCount: Int = 0,
        error: String? = nil,
        stderrTail: String? = nil,
        advertisedToolNames: [String] = [],
        toolDescriptions: [String: String] = [:],
        serverInstructions: String? = nil
    ) {
        self.state = state
        self.toolCount = toolCount
        self.error = error
        self.stderrTail = stderrTail
        self.advertisedToolNames = advertisedToolNames
        self.toolDescriptions = toolDescriptions
        self.serverInstructions = serverInstructions
    }
}

/// Why a server's handshake was abandoned.
enum MCPConnectError: LocalizedError {
    case timedOut
    case processExited

    var errorDescription: String? {
        switch self {
        case .timedOut: return "timed out waiting for the server to complete the MCP handshake"
        case .processExited: return "the server process exited before completing the MCP handshake"
        }
    }
}

/// Result of invoking an MCP tool, normalized for the bridged `AgentTool`.
struct MCPToolCallResult: Sendable {
    var text: String
    var images: [(data: Data, mimeType: String)]
    var isError: Bool
}

/// Thread-safe rolling buffer for a subprocess's stderr.
private final class StderrBuffer: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: Data())
    private let cap = 8 * 1024

    func append(_ data: Data) {
        lock.withLock { buf in
            buf.append(data)
            if buf.count > cap { buf.removeFirst(buf.count - cap) }
        }
    }

    var tail: String? {
        let data = lock.withLock { $0 }
        guard !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Owns the per-session set of running MCP server subprocesses and their clients.
///
/// One instance lives per `OrchestrationRuntime` (i.e. per session/tab); each
/// configured + enabled server gets its own subprocess, launched eagerly but
/// non-blockingly when the session starts. The host hard-terminates a server's
/// subprocess on disable or shutdown — even mid tool-call — so a stuck or removed
/// server can never wedge the agent loop.
public actor MCPClientHost {
    private struct Connection {
        var config: MCPServerConfig
        let process: Process
        let client: Client
        let stdin: Pipe
        let stdout: Pipe
        let stderr: Pipe
        let stderrBuffer: StderrBuffer
        var tools: [Tool]
        /// The server's `instructions` from the MCP handshake (a server-level description). nil
        /// when the server provided none.
        var instructions: String?
    }

    private let secretStore: MCPSecretStore
    private let clientName: String
    private let clientVersion: String

    private var configs: [MCPServerConfig] = []
    private var connections: [UUID: Connection] = [:]
    private var statuses: [UUID: MCPServerStatus] = [:]
    private var connectTasks: [UUID: Task<Void, Never>] = [:]

    /// Invoked whenever the set of exposed tools changes (connect, disconnect,
    /// `tools/list_changed`, per-tool toggle). Lets the app refresh any cached view.
    private var onToolsChanged: (@Sendable () -> Void)?
    /// Invoked whenever per-server status changes, for the settings UI.
    private var onStatusChanged: (@Sendable ([UUID: MCPServerStatus]) -> Void)?

    /// Ignore SIGPIPE process-wide exactly once. Writing to an MCP server's stdin after
    /// the server has crashed/exited (a common failure mode — bad command, missing
    /// package) raises SIGPIPE, which by default terminates the whole app. Ignoring it
    /// turns those writes into recoverable `EPIPE` errors that surface as tool failures.
    private static let ignoreSIGPIPE: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    public init(secretStore: MCPSecretStore, clientName: String = "AgentSmith", clientVersion: String = "1.0.0") {
        _ = Self.ignoreSIGPIPE
        self.secretStore = secretStore
        self.clientName = clientName
        self.clientVersion = clientVersion
    }

    public func setObservers(
        onToolsChanged: @escaping @Sendable () -> Void,
        onStatusChanged: @escaping @Sendable ([UUID: MCPServerStatus]) -> Void
    ) {
        self.onToolsChanged = onToolsChanged
        self.onStatusChanged = onStatusChanged
    }

    // MARK: - Lifecycle

    /// Eagerly (but non-blockingly) launch every enabled server. Returns immediately;
    /// each server connects on its own task so a slow `npx -y` download never stalls
    /// session start.
    public func start(configs: [MCPServerConfig]) {
        self.configs = configs
        for config in configs where config.enabled {
            beginConnect(config)
        }
        publishStatus()
    }

    /// Reconcile the running set against a new configuration: hard-terminate removed
    /// or disabled servers (even mid-call), launch newly-enabled ones, and update
    /// filters for servers whose tool toggles changed.
    public func applyConfigChange(configs: [MCPServerConfig]) async {
        let oldByID = Dictionary(uniqueKeysWithValues: self.configs.map { ($0.id, $0) })
        self.configs = configs
        let newByID = Dictionary(uniqueKeysWithValues: configs.map { ($0.id, $0) })

        // Tear down anything removed or newly disabled.
        for (id, old) in oldByID {
            let new = newByID[id]
            let shouldRun = new?.enabled ?? false
            if !shouldRun {
                await teardown(serverID: id, markDisabled: new != nil)
            } else if let new, needsRelaunch(old: old, new: new) {
                await teardown(serverID: id, markDisabled: false)
                beginConnect(new)
            } else if let new {
                // Same process; just refresh stored config so tool filtering picks up
                // per-tool toggles on the next turn.
                connections[id]?.config = new
                statuses[id]?.toolCount = exposedToolCount(serverID: id, config: new)
            }
        }
        // Launch newly-added enabled servers.
        for (id, new) in newByID where oldByID[id] == nil && new.enabled {
            beginConnect(new)
        }
        publishStatus()
        onToolsChanged?()
    }

    /// Terminate every subprocess and drop all clients.
    public func shutdown() async {
        for id in Array(connectTasks.keys) { connectTasks[id]?.cancel() }
        for id in Array(connections.keys) { await teardown(serverID: id, markDisabled: false) }
        connectTasks.removeAll()
        statuses.removeAll()
        publishStatus()
    }

    public func statusSnapshot() -> [UUID: MCPServerStatus] { statuses }

    /// Waits until no configured server is still in the `.connecting` state, or `timeout`
    /// elapses — whichever comes first. Used before per-task tool scoping so servers that
    /// connect quickly are included in the candidate list, without blocking task start forever
    /// on a slow or hung server. A server that connects after the deadline simply triggers a
    /// re-scope at the worker's next turn (its tools change the candidate fingerprint).
    public func waitUntilSettled(timeout: Duration) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let stillConnecting = statuses.values.contains { $0.state == .connecting }
            if !stillConnecting { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - Tools

    /// The MCP tools currently exposed to Brown, as bridged `AgentTool`s. Recomputed
    /// each turn so per-server/per-tool toggles and `tools/list_changed` updates take
    /// effect on Brown's next LLM call.
    public func currentBridgedTools() -> [any AgentTool] {
        var result: [any AgentTool] = []
        var usedNames = Set<String>()
        // Stable ordering by server name keeps the tool list deterministic across turns.
        let ordered = connections.values.sorted { $0.config.name < $1.config.name }
        for conn in ordered {
            for tool in conn.tools where !conn.config.disabledTools.contains(tool.name) {
                var prefixed = MCPToolNaming.prefixedName(server: conn.config.name, tool: tool.name)
                if usedNames.contains(prefixed) {
                    prefixed = disambiguate(prefixed, used: usedNames)
                }
                usedNames.insert(prefixed)
                result.append(MCPBridgedTool(
                    prefixedName: prefixed,
                    serverName: conn.config.name,
                    serverID: conn.config.id,
                    serverInstructions: conn.instructions,
                    originalToolName: tool.name,
                    toolDescription: tool.description ?? "MCP tool \(tool.name) from \(conn.config.name).",
                    parameters: MCPValueConversion.parametersSchema(from: tool.inputSchema),
                    isReadOnlyHint: tool.annotations.readOnlyHint,
                    destructiveHint: tool.annotations.destructiveHint,
                    openWorldHint: tool.annotations.openWorldHint,
                    host: self
                ))
            }
        }
        return result
    }

    // MARK: - Tool invocation (called by MCPBridgedTool)

    func callTool(serverID: UUID, toolName: String, arguments: [String: AnyCodable]) async throws -> MCPToolCallResult {
        guard let client = connections[serverID]?.client else {
            throw MCPError.connectionClosed
        }
        let mcpArgs = MCPValueConversion.values(from: arguments)
        let (content, isError): ([Tool.Content], Bool?) = try await client.callTool(name: toolName, arguments: mcpArgs)
        return normalize(content: content, isError: isError ?? false)
    }

    private func normalize(content: [Tool.Content], isError: Bool) -> MCPToolCallResult {
        var textChunks: [String] = []
        var images: [(data: Data, mimeType: String)] = []
        for item in content {
            switch item {
            case .text(let text, _, _):
                textChunks.append(text)
            case .image(let data, let mimeType, _, _):
                if let decoded = Data(base64Encoded: data) {
                    images.append((decoded, mimeType))
                    textChunks.append("[image returned (\(mimeType)) — added to visual context]")
                } else {
                    textChunks.append("[image returned (\(mimeType)) — could not decode]")
                }
            case .audio(_, let mimeType, _, _):
                textChunks.append("[audio returned (\(mimeType)) — not supported]")
            case .resource(let resource, _, _):
                textChunks.append("[embedded resource: \(resource.uri)]")
            case .resourceLink(let uri, let name, _, _, _, _):
                textChunks.append("[resource link: \(name) — \(uri)]")
            }
        }
        let text = textChunks.isEmpty ? "(no content returned)" : textChunks.joined(separator: "\n")
        return MCPToolCallResult(text: text, images: images, isError: isError)
    }

    // MARK: - Connect / teardown

    private func beginConnect(_ config: MCPServerConfig) {
        connectTasks[config.id]?.cancel()
        statuses[config.id] = MCPServerStatus(state: .connecting)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performConnect(config)
        }
        connectTasks[config.id] = task
    }

    private func performConnect(_ config: MCPServerConfig) async {
        let launched: (process: Process, client: Client, transport: StdioTransport, stdin: Pipe, stdout: Pipe, stderr: Pipe, stderrBuffer: StderrBuffer)
        do {
            launched = try launchProcess(config)
        } catch {
            statuses[config.id] = MCPServerStatus(state: .failed, error: "Failed to launch: \(error.localizedDescription)")
            connectTasks[config.id] = nil
            publishStatus()
            return
        }

        // Register the connection (with no tools yet) before the handshake await so a
        // disable/shutdown arriving mid-connect can always find and kill the process.
        connections[config.id] = Connection(
            config: config,
            process: launched.process,
            client: launched.client,
            stdin: launched.stdin,
            stdout: launched.stdout,
            stderr: launched.stderr,
            stderrBuffer: launched.stderrBuffer,
            tools: [],
            instructions: nil
        )
        do {
            let initResult = try await connectWithDeadline(
                client: launched.client,
                transport: launched.transport,
                process: launched.process
            )
            // Capture the server's self-description for the settings UI. Trim so a server that
            // sends whitespace-only instructions shows nothing rather than a blank block.
            let trimmed = initResult.instructions?.trimmingCharacters(in: .whitespacesAndNewlines)
            connections[config.id]?.instructions = (trimmed?.isEmpty == false) ? trimmed : nil
        } catch {
            // If the connection was already torn down (disabled mid-connect), don't clobber state.
            if connections[config.id] != nil {
                await teardown(serverID: config.id, markDisabled: false)
                // Keep `error` to a clean one-line reason; the full server stderr goes in
                // `stderrTail` so the UI can show it in full on demand.
                statuses[config.id] = MCPServerStatus(
                    state: .failed,
                    error: error.localizedDescription,
                    stderrTail: launched.stderrBuffer.tail
                )
            }
            connectTasks[config.id] = nil
            publishStatus()
            return
        }

        // Server may have been disabled while we were connecting.
        guard connections[config.id] != nil else {
            connectTasks[config.id] = nil
            return
        }

        // The SDK invokes notification handlers inline on the Client's message loop and
        // awaits them before processing the next message (including responses to our own
        // requests). Re-entering this actor synchronously here would deadlock: a
        // `tools/list_changed` that arrives while we're awaiting `listTools()` would block
        // the message loop on this actor, which is itself blocked awaiting that very
        // `listTools()` response. Detach the refresh so the handler returns immediately.
        await launched.client.onNotification(ToolListChangedNotification.self) { [weak self] _ in
            Task { await self?.handleToolsListChanged(serverID: config.id) }
        }

        await refreshTools(serverID: config.id)
        connectTasks[config.id] = nil
    }

    /// Awaits the MCP handshake, but fails instead of hanging when the server never
    /// completes it: races `client.connect()` against (a) the subprocess exiting before
    /// the handshake (a crashed/misconfigured server — fast fail) and (b) an overall
    /// deadline. The SDK does not fail a pending `initialize` on stdin/stdout EOF, so in
    /// both cases we call `disconnect()` to unblock the connect task, then throw.
    @discardableResult
    private nonisolated func connectWithDeadline(
        client: Client,
        transport: StdioTransport,
        process: Process,
        timeout: Duration = .seconds(120)
    ) async throws -> Initialize.Result {
        let pid = process.processIdentifier
        // Records why we abandoned the handshake so we can surface that reason rather
        // than the SDK's "Client disconnected" that our own `disconnect()` produces.
        let abandonReason = OSAllocatedUnfairLock<MCPConnectError?>(initialState: nil)
        return try await withThrowingTaskGroup(of: Initialize.Result.self) { group in
            group.addTask {
                // The handshake result carries the server's `instructions` (a server-level
                // description) and serverInfo — propagated up so the settings UI can show it.
                try await client.connect(transport: transport)
            }
            group.addTask {
                let start = ContinuousClock.now
                while ContinuousClock.now - start < timeout {
                    // `kill(pid, 0)` returns non-zero once the process is gone.
                    if kill(pid, 0) != 0 {
                        try? await Task.sleep(for: .milliseconds(300))  // let final stderr drain
                        abandonReason.withLock { $0 = .processExited }
                        await client.disconnect()
                        throw MCPConnectError.processExited
                    }
                    try await Task.sleep(for: .milliseconds(250))
                }
                abandonReason.withLock { $0 = .timedOut }
                await client.disconnect()
                throw MCPConnectError.timedOut
            }
            defer { group.cancelAll() }
            do {
                guard let result = try await group.next() else {
                    throw MCPConnectError.processExited
                }
                return result
            } catch {
                if let reason = abandonReason.withLock({ $0 }) { throw reason }
                throw error
            }
        }
    }

    private func refreshTools(serverID: UUID) async {
        guard let client = connections[serverID]?.client else { return }
        do {
            let (tools, _) = try await client.listTools()
            guard let config = connections[serverID]?.config else { return }
            connections[serverID]?.tools = tools
            var descriptions: [String: String] = [:]
            for tool in tools {
                if let d = tool.description, !d.isEmpty { descriptions[tool.name] = d }
            }
            statuses[serverID] = MCPServerStatus(
                state: .connected,
                toolCount: exposedToolCount(serverID: serverID, config: config),
                stderrTail: connections[serverID]?.stderrBuffer.tail,
                advertisedToolNames: tools.map(\.name),
                toolDescriptions: descriptions,
                serverInstructions: connections[serverID]?.instructions
            )
        } catch {
            statuses[serverID] = MCPServerStatus(
                state: .connected,
                toolCount: 0,
                error: "listTools failed: \(error.localizedDescription)",
                stderrTail: connections[serverID]?.stderrBuffer.tail
            )
        }
        publishStatus()
        onToolsChanged?()
    }

    private func handleToolsListChanged(serverID: UUID) async {
        logger.info("Server announced tools/list_changed; refreshing tool list")
        await refreshTools(serverID: serverID)
    }

    private func teardown(serverID: UUID, markDisabled: Bool) async {
        connectTasks[serverID]?.cancel()
        connectTasks[serverID] = nil
        guard let conn = connections.removeValue(forKey: serverID) else {
            if markDisabled { statuses[serverID] = MCPServerStatus(state: .disabled) }
            return
        }
        // Disconnecting the client fails any in-flight callTool with an error so the
        // bridged tool's execute() returns a failure instead of hanging.
        await conn.client.disconnect()
        if conn.process.isRunning {
            conn.process.terminate()
        }
        conn.stderr.fileHandleForReading.readabilityHandler = nil
        if markDisabled {
            statuses[serverID] = MCPServerStatus(state: .disabled)
        } else {
            statuses.removeValue(forKey: serverID)
        }
        onToolsChanged?()
    }

    private func launchProcess(_ config: MCPServerConfig) throws -> (process: Process, client: Client, transport: StdioTransport, stdin: Pipe, stdout: Pipe, stderr: Pipe, stderrBuffer: StderrBuffer) {
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stderrBuffer = StderrBuffer()

        let process = Process()
        // Launch through `env` so PATH resolution finds npx/node/uvx; the merged login
        // shell PATH is supplied in the environment.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [config.command] + MCPProcessEnvironment.resolvedArgs(for: config, secretStore: secretStore)
        process.environment = MCPProcessEnvironment.childEnvironment(for: config, secretStore: secretStore)
        if let wd = config.workingDirectory, !wd.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: wd)
        }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { stderrBuffer.append(chunk) }
        }

        try process.run()
        // Put the child in its own group so terminate() can take down grandchildren too.
        setpgid(process.processIdentifier, process.processIdentifier)

        let inputFD = FileDescriptor(rawValue: stdoutPipe.fileHandleForReading.fileDescriptor)
        let outputFD = FileDescriptor(rawValue: stdinPipe.fileHandleForWriting.fileDescriptor)
        let transport = StdioTransport(input: inputFD, output: outputFD)
        let client = Client(name: clientName, version: clientVersion)
        return (process, client, transport, stdinPipe, stdoutPipe, stderrPipe, stderrBuffer)
    }

    // MARK: - Helpers

    private func needsRelaunch(old: MCPServerConfig, new: MCPServerConfig) -> Bool {
        old.command != new.command
            || old.args != new.args
            || old.workingDirectory != new.workingDirectory
            || old.envVarNames != new.envVarNames
            || old.secretArgIndices != new.secretArgIndices
    }

    private func exposedToolCount(serverID: UUID, config: MCPServerConfig) -> Int {
        guard let tools = connections[serverID]?.tools else { return 0 }
        return tools.filter { !config.disabledTools.contains($0.name) }.count
    }

    private func disambiguate(_ name: String, used: Set<String>) -> String {
        var n = 2
        var candidate = "\(name)_\(n)"
        while used.contains(candidate) { n += 1; candidate = "\(name)_\(n)" }
        return candidate
    }

    private func publishStatus() {
        onStatusChanged?(statuses)
    }
}
