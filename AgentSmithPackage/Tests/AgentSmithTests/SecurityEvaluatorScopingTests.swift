import Testing
import Foundation
@testable import AgentSmithKit

/// Tests for the per-task tool scoping response parser — the fail-closed / hallucinated-allow /
/// case-tolerance rules that turn Jones's ALLOW/BLOCK text into an approved-name set.
@Suite("SecurityEvaluator tool scoping parse")
struct SecurityEvaluatorScopingTests {
    private let candidates: Set<String> = ["bash", "file_read", "file_write", "grep"]

    @Test("clean allow/block lines parse to the allowed set")
    func cleanParse() {
        let text = """
            ALLOW file_read
            ALLOW grep
            BLOCK bash
            BLOCK file_write
            """
        let result = SecurityEvaluator.parseScopingResponse(text, candidateNames: candidates)
        #expect(result == ["file_read", "grep"])
    }

    @Test("omitted tools are blocked (fail-closed)")
    func failClosedOmission() {
        // Only file_read is mentioned; the rest are implicitly blocked.
        let result = SecurityEvaluator.parseScopingResponse("ALLOW file_read", candidateNames: candidates)
        #expect(result == ["file_read"])
    }

    @Test("hallucinated allow of a non-candidate is ignored")
    func hallucinatedAllowIgnored() {
        let text = """
            ALLOW file_read
            ALLOW some_tool_that_does_not_exist
            """
        let result = SecurityEvaluator.parseScopingResponse(text, candidateNames: candidates)
        #expect(result == ["file_read"])
    }

    @Test("tolerates markdown bullets, backticks, and mixed case")
    func tolerantParsing() {
        let text = """
            - allow `file_read`
            * BLOCK bash
            Allow grep
            """
        let result = SecurityEvaluator.parseScopingResponse(text, candidateNames: candidates)
        #expect(result == ["file_read", "grep"])
    }

    @Test("no recognizable lines returns nil (triggers retry)")
    func unparseableReturnsNil() {
        #expect(SecurityEvaluator.parseScopingResponse("I cannot help with that.", candidateNames: candidates) == nil)
        #expect(SecurityEvaluator.parseScopingResponse("", candidateNames: candidates) == nil)
    }

    @Test("all-block parses to an empty (but non-nil) set — a deliberate refusal")
    func allBlockedIsEmptyNonNil() {
        let text = """
            BLOCK bash
            BLOCK file_read
            BLOCK file_write
            BLOCK grep
            """
        let result = SecurityEvaluator.parseScopingResponse(text, candidateNames: candidates)
        #expect(result == [])
    }
}
