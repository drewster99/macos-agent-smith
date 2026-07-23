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

    @Test("Every parking tool is a lifecycle tool, so the run loop actually breaks on it")
    func parkingToolsAreLifecycleTools() {
        // Only the lifecycle branch of the segment loop knows how to stop the remaining
        // segments after a handoff. A parking tool that fell out of `taskLifecycleTools` would
        // set the flag from a branch that keeps going — the worker would carry on working on a
        // task it had already submitted, with nothing failing to say so.
        #expect(
            AgentActor.handoffLifecycleTools.isSubset(of: AgentActor.taskLifecycleTools),
            "handoff tools missing from taskLifecycleTools: \(AgentActor.handoffLifecycleTools.subtracting(AgentActor.taskLifecycleTools).sorted())"
        )
    }
}
