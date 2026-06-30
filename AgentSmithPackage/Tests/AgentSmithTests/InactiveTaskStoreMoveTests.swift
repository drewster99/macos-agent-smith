import Testing
import Foundation
@testable import AgentSmithKit

/// Exercises the per-session `TaskStore` ⇄ global `InactiveTaskStore` move logic that backs the
/// "archived + deleted are global" design: archiving/deleting pushes a task out to the global
/// store, restoring pulls it back into the (current) session.
@Suite("Inactive task store moves")
struct InactiveTaskStoreMoveTests {

    private func makePair() -> (TaskStore, InactiveTaskStore) {
        let inactive = InactiveTaskStore()
        let store = TaskStore(inactiveStore: inactive)
        return (store, inactive)
    }

    @Test("archive moves an active task out to the global store")
    func archiveMovesToGlobal() async {
        let (store, inactive) = makePair()
        let task = await store.addTask(title: "T", description: "D")

        let ok = await store.archive(id: task.id)
        #expect(ok)

        // Gone from the session's active list…
        let active = await store.allTasks()
        #expect(!active.contains { $0.id == task.id })

        // …and present in the global store as `.archived`.
        let archived = await inactive.all()
        #expect(archived.count == 1)
        #expect(archived.first?.id == task.id)
        #expect(archived.first?.disposition == .archived)

        // Cross-store lookup still finds it.
        let found = await store.taskAnyDisposition(id: task.id)
        #expect(found?.id == task.id)
        // And it shows up via the session store's inactive accessor.
        let viaAccessor = await store.allInactiveTasks()
        #expect(viaAccessor.contains { $0.id == task.id })
    }

    @Test("unarchive pulls a task back into the current session's active list")
    func unarchiveRestoresToSession() async {
        let (store, inactive) = makePair()
        let task = await store.addTask(title: "T", description: "D")
        _ = await store.archive(id: task.id)

        await store.unarchive(id: task.id)

        let active = await store.allTasks()
        #expect(active.contains { $0.id == task.id && $0.disposition == .active })
        let stillInactive = await inactive.all()
        #expect(stillInactive.isEmpty)
    }

    @Test("soft delete moves to the global deleted bucket; deletedIDs reflects it")
    func softDeleteMovesToGlobal() async {
        let (store, inactive) = makePair()
        let task = await store.addTask(title: "T", description: "D")

        let ok = await store.softDelete(id: task.id)
        #expect(ok)

        let active = await store.allTasks()
        #expect(!active.contains { $0.id == task.id })
        let deletedIDs = await inactive.deletedIDs()
        #expect(deletedIDs.contains(task.id))
        let entry = await inactive.task(id: task.id)
        #expect(entry?.disposition == .recentlyDeleted)
    }

    @Test("deleting an already-archived (global) task flips it to deleted in place")
    func deleteArchivedFlipsWithinGlobal() async {
        let (store, inactive) = makePair()
        let task = await store.addTask(title: "T", description: "D")
        _ = await store.archive(id: task.id)

        // The task is now only in the global store. Deleting it should flip its disposition there.
        let ok = await store.softDelete(id: task.id)
        #expect(ok)

        let entry = await inactive.task(id: task.id)
        #expect(entry?.disposition == .recentlyDeleted)
        let all = await inactive.all()
        #expect(all.count == 1)
    }

    @Test("permanent delete removes a deleted task from the global store for good")
    func permanentDeleteRemovesFromGlobal() async {
        let (store, inactive) = makePair()
        let task = await store.addTask(title: "T", description: "D")
        _ = await store.softDelete(id: task.id)

        let ok = await store.permanentlyDelete(id: task.id)
        #expect(ok)
        let all = await inactive.all()
        #expect(all.isEmpty)
        let found = await store.taskAnyDisposition(id: task.id)
        #expect(found == nil)
    }

    @Test("an in-progress task cannot be archived or deleted")
    func inProgressCannotLeaveActive() async {
        let (store, inactive) = makePair()
        let task = await store.addTask(title: "T", description: "D")
        await store.updateStatus(id: task.id, status: .running)

        #expect(await store.archive(id: task.id) == false)
        #expect(await store.softDelete(id: task.id) == false)
        let all = await inactive.all()
        #expect(all.isEmpty)
        #expect(await store.allTasks().contains { $0.id == task.id })
    }

    @Test("merge dedupes by id, keeping the newer copy")
    func mergeDedupesByNewer() async {
        let inactive = InactiveTaskStore()
        var older = AgentTask(title: "T", description: "old")
        older.disposition = .archived
        older.updatedAt = Date(timeIntervalSince1970: 1_000)
        var newer = older
        newer.description = "new"
        newer.updatedAt = Date(timeIntervalSince1970: 2_000)

        await inactive.merge([older])
        await inactive.merge([newer])

        let all = await inactive.all()
        #expect(all.count == 1)
        #expect(all.first?.description == "new")
    }
}
