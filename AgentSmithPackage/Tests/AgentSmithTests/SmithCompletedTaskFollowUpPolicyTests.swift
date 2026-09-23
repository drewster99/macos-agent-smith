import Foundation
import Testing
@testable import AgentSmithKit

@Suite("Smith completed-task follow-up policy")
struct SmithCompletedTaskFollowUpPolicyTests {
    @Test("Changed acceptance contracts create related successor tasks")
    func changedContractsCreateSuccessors() {
        let prompt = SmithBehavior.systemPrompt()

        #expect(prompt.contains("A follow-up that materially changes deliverables"))
        #expect(prompt.contains("call `create_task` for a related successor"))
        #expect(prompt.contains("Never call `set_acceptance_criteria` on the completed predecessor"))
        #expect(prompt.contains("predecessor task's id, title, and relevant"))
    }

    @Test("Same-contract retries continue to use run_task")
    func sameContractRetriesReuseTask() {
        let prompt = SmithBehavior.systemPrompt()

        #expect(prompt.contains("existing acceptance criteria still describe success completely"))
        #expect(prompt.contains("`run_task` on the completed task"))
        #expect(prompt.contains("This is a retry"))
    }

    @Test("Old unconditional reopen instructions are gone")
    func noUnconditionalReopenInstruction() {
        let prompt = SmithBehavior.systemPrompt()

        #expect(!prompt.contains("Whenever this happens, RE-OPEN THE EXISTING TASK"))
        #expect(!prompt.contains("you should first update the deliverables (acceptance_criteria)"))
        #expect(!prompt.contains("Do NOT call `create_task` when a matching task exists"))
    }
}
