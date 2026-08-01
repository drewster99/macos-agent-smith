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
        #expect(out == "Approved tools (security-scoped worker toolset): bash, file_read, grep")
    }

    @Test("A scoped-but-empty approved set renders (none), distinct from unscoped")
    func emptyApproved() {
        let out = task(approved: []).renderedToolScope()
        #expect(out == "Approved tools (security-scoped worker toolset): (none)")
    }

    @Test("Overrides render forced on/off (sorted) even without an approved set")
    func overridesOnly() {
        let out = task(overrides: ["bash": false, "run_applescript": true, "curl": false]).renderedToolScope()
        #expect(out == "User tool overrides — forced on: run_applescript; forced off: bash, curl")
    }

    @Test("Approved tools and overrides render together, on separate lines")
    func approvedAndOverrides() {
        let out = task(approved: ["file_read", "bash"], overrides: ["bash": false]).renderedToolScope()
        #expect(out == """
            Approved tools (security-scoped worker toolset): bash, file_read
            User tool overrides — forced off: bash
            """)
    }
}
