import Foundation
import Testing
@testable import AgentSmithKit

/// Forward-compatibility shims: rawValues written by NEWER builds (future enum cases)
/// must degrade to safe fallbacks instead of failing whole-array decodes — the
/// prerequisite for adding `validating` (Status) and `validator` (AgentRole) cases
/// without creating a data-loss-shaped rollback hazard.

@Suite("Forward-compatible enum decoding")
struct ForwardCompatibleDecodingTests {

    @Test("Unknown task status decodes to .interrupted")
    func unknownStatusFallsBack() throws {
        let decoded = try JSONDecoder().decode(AgentTask.Status.self, from: Data("\"validating\"".utf8))
        #expect(decoded == .interrupted)
    }

    @Test("Known task statuses still decode exactly")
    func knownStatusesRoundTrip() throws {
        for status in AgentTask.Status.allCases {
            let data = try JSONEncoder().encode(status)
            let decoded = try JSONDecoder().decode(AgentTask.Status.self, from: data)
            #expect(decoded == status)
        }
    }

    @Test("Unknown agent role decodes to the harmless fallback")
    func unknownRoleFallsBack() throws {
        let decoded = try JSONDecoder().decode(AgentRole.self, from: Data("\"validator\"".utf8))
        #expect(decoded == AgentRole.decodingFallback)
    }

    @Test("Known agent roles still decode exactly")
    func knownRolesRoundTrip() throws {
        for role in AgentRole.allCases {
            let data = try JSONEncoder().encode(role)
            let decoded = try JSONDecoder().decode(AgentRole.self, from: data)
            #expect(decoded == role)
        }
    }

    @Test("A task carrying an unknown status decodes without failing the whole task")
    func taskWithUnknownStatusDecodes() throws {
        var task = AgentTask(title: "t", description: "d")
        task.status = .running
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as! [String: Any]
        json["status"] = "someFutureStatus"
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(AgentTask.self, from: data)
        #expect(decoded.status == .interrupted)
        #expect(decoded.title == "t")
    }
}
