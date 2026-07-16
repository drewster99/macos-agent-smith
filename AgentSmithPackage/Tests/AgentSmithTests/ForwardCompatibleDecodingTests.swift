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
        // Deliberately fictional — the original fixture used "validating", which became
        // a real case within the hour and proved the shim by turning this test red.
        let decoded = try JSONDecoder().decode(AgentTask.Status.self, from: Data("\"someFutureStatusNoBuildKnows\"".utf8))
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

    @Test("Unknown result-item kind decodes to a preserved .unknown, not a throw")
    func unknownResultItemKindFallsBack() throws {
        // A future build could add a Content kind (e.g. "chart"); an OLDER build reading it must
        // NOT throw, or the all-or-nothing array decode would take down the whole task file.
        let json = "{\"content\":{\"kind\":\"chart\",\"payload\":42},\"refs\":[\"c1\"]}"
        let decoded = try JSONDecoder().decode(ResultItem.self, from: Data(json.utf8))
        guard case .unknown(let kind, _) = decoded.content else {
            Issue.record("expected .unknown for an unrecognized kind")
            return
        }
        #expect(kind == "chart")
        #expect(decoded.refs == ["c1"])
    }

    @Test("An unknown result-item round-trips losslessly (downgrade→resave keeps the payload)")
    func unknownResultItemRoundTrips() throws {
        let json = "{\"content\":{\"kind\":\"chart\",\"payload\":42,\"title\":\"Q3\"},\"refs\":[\"c1\"]}"
        let decoded = try JSONDecoder().decode(ResultItem.self, from: Data(json.utf8))
        let reencoded = try JSONEncoder().encode(decoded)
        // Re-decoding the re-encoded bytes still yields the same unknown kind with its payload,
        // proving the older build didn't silently drop the newer content on save.
        let roundTripped = try JSONDecoder().decode(ResultItem.self, from: reencoded)
        guard case .unknown(let kind, let raw) = roundTripped.content else {
            Issue.record("re-encoded unknown item should decode back to .unknown")
            return
        }
        #expect(kind == "chart")
        guard case .dictionary(let dict) = raw else {
            Issue.record("preserved payload should be a JSON object")
            return
        }
        #expect(dict["payload"] == .int(42))
        #expect(dict["title"] == .string("Q3"))
    }

    @Test("A task carrying an unknown result-item kind decodes without failing the whole task")
    func taskWithUnknownResultItemKindDecodes() throws {
        var task = AgentTask(title: "t", description: "d")
        task.resultItems = [ResultItem(content: .text("keep me"), refs: [])]
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as! [String: Any]
        json["resultItems"] = [["content": ["kind": "someFutureKind", "extra": true], "refs": []]]
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(AgentTask.self, from: data)
        #expect(decoded.title == "t")
        #expect(decoded.resultItems.count == 1)
        if case .unknown = decoded.resultItems[0].content {} else {
            Issue.record("unknown result-item kind should decode to .unknown")
        }
    }

    @Test("Known result-item kinds still round-trip exactly")
    func knownResultItemKindsRoundTrip() throws {
        let attachment = Attachment(filename: "a.png", mimeType: "image/png", byteCount: 10)
        let items: [ResultItem] = [
            ResultItem(content: .text("hi"), refs: ["c1"]),
            ResultItem(content: .attachment(attachment), refs: []),
            ResultItem(content: .attachmentGroup(attachments: [attachment], description: "grp"), refs: ["c2", "c3"])
        ]
        let data = try JSONEncoder().encode(items)
        let decoded = try JSONDecoder().decode([ResultItem].self, from: data)
        #expect(decoded == items)
    }
}
