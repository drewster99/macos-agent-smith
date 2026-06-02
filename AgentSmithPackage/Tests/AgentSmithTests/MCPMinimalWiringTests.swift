import Testing
import Foundation
import System
import MCP
@testable import AgentSmithKit

/// Minimal, actor-free reproduction of the Process + pipes + `StdioTransport` + `Client`
/// wiring, to isolate whether the bug is in the SDK FD wiring or in `MCPClientHost`.
/// Opt-in via `MCP_INTEGRATION=1`. Has its own hard internal timeout so it can never hang.
@Suite("MCP minimal wiring", .enabled(if: ProcessInfo.processInfo.environment["MCP_INTEGRATION"] == "1"))
struct MCPMinimalWiringTests {
    private func loginPATH() -> String {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "printf '%s' \"$PATH\""]
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Runs `op`, failing if it doesn't finish within `seconds`.
    private func withTimeout<T: Sendable>(_ seconds: Int, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw CancellationError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    @Test("Raw SDK wiring connects and lists tools")
    func rawWiring() async throws {
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["npx", "-y", "@modelcontextprotocol/server-everything"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = loginPATH()
        process.environment = env
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let inputFD = FileDescriptor(rawValue: stdoutPipe.fileHandleForReading.fileDescriptor)
        let outputFD = FileDescriptor(rawValue: stdinPipe.fileHandleForWriting.fileDescriptor)
        let transport = StdioTransport(input: inputFD, output: outputFD)
        let client = Client(name: "min", version: "1.0.0")

        do {
            _ = try await withTimeout(20) {
                try await client.connect(transport: transport)
            }
            let (tools, _) = try await withTimeout(20) {
                try await client.listTools()
            }
            print("MINIMAL: connected, tools=\(tools.count): \(tools.prefix(3).map(\.name))")
            #expect(!tools.isEmpty)
        } catch {
            let err = stderrPipe.fileHandleForReading.availableData
            print("MINIMAL FAILED: \(error)")
            print("MINIMAL STDERR: \(String(data: err, encoding: .utf8) ?? "<none>")")
            throw error
        }

        await client.disconnect()
        process.terminate()
    }
}
