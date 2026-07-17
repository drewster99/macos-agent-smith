import Foundation
import Testing
@testable import AgentSmithKit

@Suite("Off-actor file I/O")
struct FileIOTests {

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Raw bytes round-trip through write/read")
    func rawRoundTrip() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("blob.bin")
        let bytes = Data((0..<10_000).map { UInt8($0 % 256) })

        try await FileIO.write(bytes, to: url)
        let read = try await FileIO.read(url)
        #expect(read == bytes)
    }

    @Test("JSON round-trips through writeJSON/readJSON")
    func jsonRoundTrip() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("model.json")
        let value = ["alpha", "beta", "gamma"]

        try await FileIO.writeJSON(value, to: url)
        let read = try await FileIO.readJSON([String].self, from: url)
        #expect(read == value)
    }

    @Test("Reading a missing file throws")
    func missingFileThrows() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("does-not-exist.json")
        await #expect(throws: (any Error).self) {
            _ = try await FileIO.read(url)
        }
    }
}
