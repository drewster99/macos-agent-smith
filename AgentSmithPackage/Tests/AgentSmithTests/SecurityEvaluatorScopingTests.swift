import Testing
import Foundation
@testable import AgentSmithKit

/// Tests for the structured (JSON) tool-scoping response parser — the fail-closed /
/// hallucinated-allow / fence-tolerance rules that turn the security agent's JSON
/// `{toolResponses:[{toolID,isAllowed}]}` into an approved-name set.
@Suite("SecurityEvaluator tool scoping parse")
struct SecurityEvaluatorScopingTests {
    private let candidates: Set<String> = ["bash", "file_read", "file_write", "grep"]

    private func json(_ pairs: [(String, Bool)]) -> String {
        let entries = pairs.map { "{\"toolID\":\"\($0.0)\",\"isAllowed\":\($0.1)}" }.joined(separator: ",")
        return "{\"toolResponses\":[\(entries)]}"
    }

    @Test("clean JSON parses to the allowed set")
    func cleanParse() {
        let text = json([("file_read", true), ("grep", true), ("bash", false), ("file_write", false)])
        #expect(SecurityEvaluator.parseScopingResponse(text, candidateNames: candidates) == ["file_read", "grep"])
    }

    @Test("omitted tools are blocked (fail-closed)")
    func failClosedOmission() {
        // Only file_read is mentioned; the rest are implicitly blocked.
        let text = json([("file_read", true)])
        #expect(SecurityEvaluator.parseScopingResponse(text, candidateNames: candidates) == ["file_read"])
    }

    @Test("hallucinated toolID is ignored")
    func hallucinatedAllowIgnored() {
        let text = json([("file_read", true), ("some_tool_that_does_not_exist", true)])
        #expect(SecurityEvaluator.parseScopingResponse(text, candidateNames: candidates) == ["file_read"])
    }

    @Test("tolerates ```json code fences and surrounding prose")
    func tolerantParsing() {
        let inner = json([("file_read", true), ("bash", false), ("grep", true)])
        let text = "Sure, here is my decision:\n```json\n\(inner)\n```\nLet me know if you need changes."
        #expect(SecurityEvaluator.parseScopingResponse(text, candidateNames: candidates) == ["file_read", "grep"])
    }

    @Test("no decodable JSON returns nil (triggers retry)")
    func unparseableReturnsNil() {
        #expect(SecurityEvaluator.parseScopingResponse("I cannot help with that.", candidateNames: candidates) == nil)
        #expect(SecurityEvaluator.parseScopingResponse("", candidateNames: candidates) == nil)
        // Valid JSON shape but references no real candidate → treated as garbage → nil (retry).
        #expect(SecurityEvaluator.parseScopingResponse(json([("ghost", true)]), candidateNames: candidates) == nil)
        // Empty decision array → no candidate recognized → nil (contract violation → retry).
        #expect(SecurityEvaluator.parseScopingResponse("{\"toolResponses\":[]}", candidateNames: candidates) == nil)
    }

    @Test("all-block parses to an empty (but non-nil) set — a deliberate refusal")
    func allBlockedIsEmptyNonNil() {
        let text = json([("bash", false), ("file_read", false), ("file_write", false), ("grep", false)])
        #expect(SecurityEvaluator.parseScopingResponse(text, candidateNames: candidates) == [])
    }

    @Test("extractJSONObject pulls a balanced object out of surrounding prose")
    func extractsBalancedObject() {
        let inner = json([("file_read", true)])
        let text = "Here is my decision: \(inner) — done."
        let data = SecurityEvaluator.extractJSONObject(from: text)
        let decoded = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        #expect(decoded?["toolResponses"] != nil)
    }
}
