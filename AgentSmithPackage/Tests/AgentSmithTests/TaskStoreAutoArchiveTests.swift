import Testing
import Foundation
@testable import AgentSmithKit

/// Exercises the auto-archive-stale-completed policy gate on `TaskStore`. The sweep is OFF by
/// default; the app layer opts in via `setAutoArchivePolicy`. Only the gated entry point
/// (`autoArchiveStaleCompletedIfEnabled`) consults the gate — the underlying
/// `archiveStaleCompleted(olderThan:)` mechanism is unconditional and tested separately.
///
/// A negative `interval` is used to force staleness deterministically: `cutoff = now - interval`
/// lands in the future, so a just-completed task counts as "older than the cutoff" without the
/// test having to wait real time.
@Suite("TaskStore auto-archive gating")
struct TaskStoreAutoArchiveTests {

    private func makePair() -> (TaskStore, InactiveTaskStore) {
        let inactive = InactiveTaskStore()
        let store = TaskStore(inactiveStore: inactive)
        return (store, inactive)
    }

    @Test("off by default: the gated sweep archives nothing even for a stale completed task")
    func offByDefault() async {
        let (store, inactive) = makePair()
        let task = await store.addTask(title: "T", description: "D")
        await store.updateStatus(id: task.id, status: .completed)

        await store.autoArchiveStaleCompletedIfEnabled()

        #expect(await store.allTasks().contains { $0.id == task.id })
        #expect(await inactive.all().isEmpty)
    }

    @Test("explicitly disabled: a would-be-stale completed task is left active")
    func disabledLeavesStale() async {
        let (store, inactive) = makePair()
        let task = await store.addTask(title: "T", description: "D")
        await store.updateStatus(id: task.id, status: .completed)
        await store.setAutoArchivePolicy(enabled: false, interval: -1)

        await store.autoArchiveStaleCompletedIfEnabled()

        #expect(await store.allTasks().contains { $0.id == task.id })
        #expect(await inactive.all().isEmpty)
    }

    @Test("enabled: the gated sweep moves a stale completed task to the archive")
    func enabledSweeps() async {
        let (store, inactive) = makePair()
        let task = await store.addTask(title: "T", description: "D")
        await store.updateStatus(id: task.id, status: .completed)
        await store.setAutoArchivePolicy(enabled: true, interval: -1)

        await store.autoArchiveStaleCompletedIfEnabled()

        #expect(!(await store.allTasks()).contains { $0.id == task.id })
        let archived = await inactive.all()
        #expect(archived.contains { $0.id == task.id && $0.disposition == .archived })
    }

    @Test("enabled: a completed task younger than the cutoff is NOT archived")
    func enabledRespectsCutoff() async {
        let (store, inactive) = makePair()
        let task = await store.addTask(title: "T", description: "D")
        await store.updateStatus(id: task.id, status: .completed)
        // Large positive cutoff: a just-completed task is far younger than this, so it stays.
        await store.setAutoArchivePolicy(enabled: true, interval: 4 * 3600)

        await store.autoArchiveStaleCompletedIfEnabled()

        #expect(await store.allTasks().contains { $0.id == task.id })
        #expect(await inactive.all().isEmpty)
    }

    @Test("enabled: failed tasks are never auto-archived — only completed ones")
    func failedNotArchived() async {
        let (store, inactive) = makePair()
        let task = await store.addTask(title: "T", description: "D")
        await store.updateStatus(id: task.id, status: .failed)
        await store.setAutoArchivePolicy(enabled: true, interval: -1)

        await store.autoArchiveStaleCompletedIfEnabled()

        #expect(await store.allTasks().contains { $0.id == task.id })
        #expect(await inactive.all().isEmpty)
    }
}
