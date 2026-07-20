import Testing
@testable import AgentSmithKit

@Suite("Task complete control flow")
struct TaskCompleteControlFlowTests {
    @Test("A successful task completion parks the worker without inspecting response text")
    func successfulTaskCompletion() {
        #expect(AgentActor.shouldParkAfterLifecycleTool(named: "task_complete", succeeded: true))
    }

    @Test("A rejected task completion remains actionable")
    func rejectedTaskCompletion() {
        #expect(!AgentActor.shouldParkAfterLifecycleTool(named: "task_complete", succeeded: false))
    }

    @Test("Only handoff lifecycle tools park the worker")
    func otherToolCalls() {
        #expect(AgentActor.shouldParkAfterLifecycleTool(named: "request_help", succeeded: true))
        #expect(!AgentActor.shouldParkAfterLifecycleTool(named: "task_update", succeeded: true))
    }
}
