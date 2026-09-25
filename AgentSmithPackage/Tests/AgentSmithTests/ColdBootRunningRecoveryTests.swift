import Testing
@testable import AgentSmithKit

@Suite("ColdBootRunningRecovery")
struct ColdBootRunningRecoveryTests {

    private func task(status: AgentTask.Status, result: String?) -> AgentTask {
        var task = AgentTask(title: "t", description: "d")
        task.status = status
        task.result = result
        return task
    }

    @Test("A running task with a submitted result resumes validation, with a note")
    func submittedResultResumesValidation() {
        let recovery = ColdBootRunningRecovery.recovery(for: task(status: .running, result: "Done."))
        #expect(recovery == .resumeValidation)
        #expect(recovery?.recoveredStatus == .validating)
        #expect(recovery?.progressNote != nil)
    }

    @Test("A running task without a result is interrupted", arguments: [nil, "", "  \n\t "])
    func noResultInterrupts(result: String?) {
        let recovery = ColdBootRunningRecovery.recovery(for: task(status: .running, result: result))
        #expect(recovery == .interrupt)
        #expect(recovery?.recoveredStatus == .interrupted)
        #expect(recovery?.progressNote == nil)
    }

    @Test("Only running tasks are recovered")
    func nonRunningUntouched() {
        for status in AgentTask.Status.allCases where status != .running {
            #expect(ColdBootRunningRecovery.recovery(for: task(status: status, result: "Done.")) == nil)
        }
    }
}
