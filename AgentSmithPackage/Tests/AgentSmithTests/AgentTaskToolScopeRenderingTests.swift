import Testing
import Foundation
@testable import AgentSmithKit

/// Covers `AgentTask.renderedToolScope()` — the approved-tool-list section `get_task_details`
/// appends. The rendering reads only per-task state (`approvedTools` + `userToolOverrides`), the
/// same fields the task-detail screen's tool editor shows, so it stays honest for archived tasks
/// with no live worker.
@Suite("AgentTask tool-scope rendering (get_task_details)")
struct AgentTaskToolScopeRenderingTests {

    private func task(approved: [String]? = nil, overrides: [String: Bool]? = nil) -> AgentTask {
        AgentTask(title: "T", description: "d", approvedTools: approved, userToolOverrides: overrides)
    }

    @Test("An unscoped task with no overrides renders nothing")
    func nilWhenUnscoped() {
        #expect(task().renderedToolScope() == nil)
    }

    @Test("Approved tools render sorted")
    func approvedSorted() {
        let out = task(approved: ["grep", "bash", "file_read"]).renderedToolScope()
        #expect(out == "Approved tools (security-scoped worker toolset): bash, file_read, grep\n" + AgentTask.toolScopeGlobalPolicyNote)
    }

    @Test("A scoped-but-empty approved set renders (none), distinct from unscoped")
    func emptyApproved() {
        let out = task(approved: []).renderedToolScope()
        #expect(out == "Approved tools (security-scoped worker toolset): (none)\n" + AgentTask.toolScopeGlobalPolicyNote)
    }

    @Test("Overrides render turned on/off (sorted) even without an approved set")
    func overridesOnly() {
        let out = task(overrides: ["bash": false, "run_applescript": true, "file_read": false]).renderedToolScope()
        #expect(out == "User tool overrides for this task — turned on: run_applescript; turned off: bash, file_read\n" + AgentTask.toolScopeGlobalPolicyNote)
    }

    /// An override for a tool no worker can have is stored but never applied — it must not read as
    /// "turned on" (2026-10-04: Smith "enabled" its own create_task on a worker's task).
    @Test("Overrides for tools no worker can have render as ignored")
    func unavailableOverridesRenderAsIgnored() {
        let out = task(overrides: ["create_task": true, "curl": false, "file_write": true]).renderedToolScope()
        #expect(out == "User tool overrides for this task — turned on: file_write; ignored, not worker tools: create_task, curl\n" + AgentTask.toolScopeGlobalPolicyNote)
    }

    @Test("Approved tools and overrides render together, on separate lines")
    func approvedAndOverrides() {
        let out = task(approved: ["file_read", "bash"], overrides: ["bash": false]).renderedToolScope()
        #expect(out == """
            Approved tools (security-scoped worker toolset): bash, file_read
            User tool overrides for this task — turned off: bash
            \(AgentTask.toolScopeGlobalPolicyNote)
            """)
    }
}
