import Testing
@testable import AgentSmithKit

/// The reconciliation-response parser: first line SAME/DIFFERENT, remaining lines the
/// merged text on SAME, safe degradation to `.distinct` on anything malformed.
@Suite("Memory reconciliation parsing")
struct MemoryReconciliationParseTests {

    @Test("DIFFERENT → distinct")
    func differentIsDistinct() {
        #expect(TaskSummarizer.parseReconciliation("DIFFERENT") == .distinct)
        #expect(TaskSummarizer.parseReconciliation("DIFFERENT\nthey are unrelated") == .distinct)
        #expect(TaskSummarizer.parseReconciliation("different.") == .distinct)
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

    @Test("SAME with no body degrades to distinct (never clobber on a malformed response)")
    func sameWithoutBodyIsDistinct() {
        #expect(TaskSummarizer.parseReconciliation("SAME") == .distinct)
        #expect(TaskSummarizer.parseReconciliation("SAME\n   \n") == .distinct)
    }

    @Test("Unrecognized first word → distinct")
    func garbageIsDistinct() {
        #expect(TaskSummarizer.parseReconciliation("maybe?\nsome text") == .distinct)
        #expect(TaskSummarizer.parseReconciliation("") == .distinct)
    }
}
