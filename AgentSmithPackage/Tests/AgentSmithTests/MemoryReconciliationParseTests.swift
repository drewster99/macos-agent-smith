import Testing
@testable import AgentSmithKit

/// The reconciliation-response parser: first line SAME/DIFFERENT, remaining lines the merged text
/// on SAME. Malformed and empty-merge answers are their own outcomes — never an affirmative
/// DIFFERENT — and none of them merges.
@Suite("Memory reconciliation parsing")
struct MemoryReconciliationParseTests {

    @Test("DIFFERENT → different")
    func differentIsDifferent() {
        #expect(TaskSummarizer.parseReconciliation("DIFFERENT") == .different)
        #expect(TaskSummarizer.parseReconciliation("DIFFERENT\nthey are unrelated") == .different)
        #expect(TaskSummarizer.parseReconciliation("different.") == .different)
    }

    @Test("SAME with a body → merged text")
    func sameYieldsMerged() {
        let out = TaskSummarizer.parseReconciliation("SAME\nThe user's phone number is 415-555-1234.")
        #expect(out == .merged("The user's phone number is 415-555-1234."))
    }

    @Test("SAME is punctuation- and case-tolerant, and keeps multi-line bodies")
    func sameTolerant() {
        let out = TaskSummarizer.parseReconciliation("same:\nline one\nline two")
        #expect(out == .merged("line one\nline two"))
    }

    @Test("SAME with no body is an empty merge, not a merge (never clobber on a malformed response)")
    func sameWithoutBodyIsEmptyMerge() {
        #expect(TaskSummarizer.parseReconciliation("SAME") == .emptyMerge)
        #expect(TaskSummarizer.parseReconciliation("SAME\n   \n") == .emptyMerge)
    }

    @Test("Unrecognized first word → malformed, carrying the response")
    func garbageIsMalformed() {
        #expect(TaskSummarizer.parseReconciliation("maybe?\nsome text") == .malformed(response: "maybe?\nsome text"))
        #expect(TaskSummarizer.parseReconciliation("") == .malformed(response: ""))
    }
}
