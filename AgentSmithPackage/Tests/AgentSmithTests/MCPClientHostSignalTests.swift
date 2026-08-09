import Testing
import Darwin
@testable import AgentSmithKit

@Suite("MCP client host signal behavior")
struct MCPClientHostSignalTests {
    private func snapshotSIGPIPEDisposition() throws -> [UInt8] {
        var action = sigaction()
        guard sigaction(SIGPIPE, nil, &action) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw POSIXError(code)
        }
        return withUnsafeBytes(of: &action) { Array($0) }
    }

    @Test("MCPClientHost init does not mutate process-wide SIGPIPE disposition")
    func initDoesNotMutateSIGPIPEDisposition() throws {
        let before = try snapshotSIGPIPEDisposition()
        _ = MCPClientHost(secretStore: MCPSecretStore())
        let after = try snapshotSIGPIPEDisposition()
        #expect(before == after)
    }
}
