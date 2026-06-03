import Testing
import Foundation
@testable import AgentSmithKit

/// Verifies that re-running / re-completing a task preserves the *prior* result and summary
/// into the task's update history, instead of silently overwriting them. Without this, a task
/// that completes, is reopened after a follow-up, and completes again loses its original
/// deliverable and summary once the live transcript is gone.
@Suite("TaskStore result/summary preservation")
struct TaskStoreResultPreservationTests {

    @Test("reopening a completed task preserves prior result+commentary; re-summarizing preserves prior summary")
    func reopenPreservesResultAndSummary() async {
        let store = TaskStore()
        let task = await store.addTask(title: "T", description: "D")
        await store.setResult(id: task.id, result: "RESULT ONE", commentary: "did A then B")
        await store.setSummary(id: task.id, summary: "SUMMARY ONE")
        await store.updateStatus(id: task.id, status: .completed)

        // Re-run path: reopen clears the result (must preserve it first), then a new completion.
        _ = await store.reopenCompletedTask(id: task.id)
        await store.setResult(id: task.id, result: "RESULT TWO", commentary: "did C")
        await store.setSummary(id: task.id, summary: "SUMMARY TWO")

        let updated = await store.task(id: task.id)
        let updatesText = (updated?.updates ?? []).map(\.message).joined(separator: "\n---\n")
        #expect(updated?.result == "RESULT TWO")
        #expect(updated?.summary == "SUMMARY TWO")
        #expect(updatesText.contains("Replacing previous result:"))
        #expect(updatesText.contains("RESULT ONE"))
        #expect(updatesText.contains("did A then B"))     // commentary preserved alongside result
        #expect(updatesText.contains("Replacing previous summary:"))
        #expect(updatesText.contains("SUMMARY ONE"))
    }

    @Test("clearResult (review request-changes path) preserves the prior result")
    func clearResultPreserves() async {
        let store = TaskStore()
        let task = await store.addTask(title: "T", description: "D")
        await store.setResult(id: task.id, result: "WORK V1", commentary: nil)
        await store.clearResult(id: task.id)

        let updated = await store.task(id: task.id)
        #expect(updated?.result == nil)
        #expect((updated?.updates ?? []).contains { $0.message.contains("WORK V1") })
    }

    @Test("no-op cases add no spurious replacement updates")
    func noSpuriousUpdates() async {
        let store = TaskStore()
        let task = await store.addTask(title: "T", description: "D")
        await store.clearResult(id: task.id)                       // no result present
        await store.setSummary(id: task.id, summary: "S1")         // no prior summary
        await store.setSummary(id: task.id, summary: "S1")         // identical summary

        let updated = await store.task(id: task.id)
        let replacements = (updated?.updates ?? []).filter { $0.message.hasPrefix("Replacing previous") }
        #expect(replacements.isEmpty)
    }
}
