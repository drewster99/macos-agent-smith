import Testing
import Foundation
@testable import AgentSmithKit

/// SIGPIPE suppression for MCP servers is scoped to the server's stdin pipe, never installed
/// process-wide. The runtime tests run with SIGPIPE at its DEFAULT disposition (terminate) and
/// restore the prior disposition after, so a regression kills the test run loudly instead of
/// passing. The source scan is what makes the guard deterministic: a once-only disposition change
/// (the original shape of this bug) fires at the first `MCPClientHost` any test creates, so the
/// runtime check alone can pass when another suite got there first.
@Suite("MCP SIGPIPE scope", .serialized)
struct MCPSIGPIPEScopeTests {
    /// The current SIGPIPE disposition as its raw handler value (`SIG_DFL` is 0, `SIG_IGN` is 1).
    private static func currentSIGPIPEDisposition() -> Int {
        var current = sigaction()
        sigaction(SIGPIPE, nil, &current)
        return unsafeBitCast(current.__sigaction_u.__sa_handler, to: Int.self)
    }

    private static func withDefaultSIGPIPE<T>(_ body: () throws -> T) rethrows -> T {
        let prior = signal(SIGPIPE, SIG_DFL)
        defer { signal(SIGPIPE, prior) }
        return try body()
    }

    @Test("Creating an MCPClientHost leaves the process's SIGPIPE disposition alone")
    func hostInitDoesNotChangeSIGPIPE() {
        Self.withDefaultSIGPIPE {
            _ = MCPClientHost(secretStore: MCPSecretStore(appIdentifier: "MCPSIGPIPEScopeTests"))
            #expect(Self.currentSIGPIPEDisposition() == unsafeBitCast(SIG_DFL, to: Int.self), "MCPClientHost must not ignore SIGPIPE process-wide")
        }
    }

    @Test("A write to a pipe whose reader is gone fails with EPIPE instead of raising SIGPIPE")
    func writeEndReportsEPIPE() throws {
        var fds: [Int32] = [0, 0]
        try #require(pipe(&fds) == 0, "a failed pipe() leaves fds at 0 — closing those would close stdin")
        let readFD = fds[0], writeFD = fds[1]
        defer { close(writeFD) }
        try MCPClientHost.disableSIGPIPE(onWriteFD: writeFD)
        #expect(fcntl(writeFD, F_GETNOSIGPIPE) == 1)
        close(readFD)
        let (written, writeErrno): (Int, Int32) = Self.withDefaultSIGPIPE {
            let byte: [UInt8] = [0x2A]
            let result = write(writeFD, byte, 1)
            return (result, errno)
        }
        #expect(written == -1)
        #expect(writeErrno == EPIPE)
    }

    /// Code (not comments or strings) that changes the process's SIGPIPE disposition.
    static func changesSIGPIPEDisposition(_ source: String) -> Bool {
        let code = CodeStyleGuardTests.blankingCommentsAndStringContents(source)
        return code.range(of: #"\b(signal|sigaction)\s*\(\s*SIGPIPE\b"#, options: .regularExpression) != nil
    }

    @Test("No source in either target changes the process's SIGPIPE disposition")
    func noProcessWideSIGPIPEChange() throws {
        var packageSources = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { packageSources.deleteLastPathComponent() }
        packageSources.appendPathComponent("Sources", isDirectory: true)
        let roots = [packageSources, CodeStyleGuardTests.appTargetRoot]
        var offenders: [String] = []
        for root in roots {
            let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let source = try String(contentsOf: url, encoding: .utf8)
                if Self.changesSIGPIPEDisposition(source) { offenders.append(url.lastPathComponent) }
            }
        }
        #expect(offenders.isEmpty, "SIGPIPE must be suppressed per descriptor (MCPClientHost.disableSIGPIPE), never process-wide: \(offenders)")
    }

    @Test("The disposition scan catches the original bug's shape and ignores comments")
    func dispositionScanIsNotEvadable() {
        #expect(Self.changesSIGPIPEDisposition("private static let ignore: Void = { signal(SIGPIPE, SIG_IGN) }()"))
        #expect(Self.changesSIGPIPEDisposition("sigaction( SIGPIPE, &action, nil)"))
        #expect(!Self.changesSIGPIPEDisposition("// signal(SIGPIPE, SIG_IGN) used to live here"))
        #expect(!Self.changesSIGPIPEDisposition("let note = \"signal(SIGPIPE, SIG_IGN)\""))
    }
}
