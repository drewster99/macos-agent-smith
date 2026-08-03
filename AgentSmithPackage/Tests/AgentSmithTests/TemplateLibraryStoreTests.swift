import Testing
import Foundation
@testable import AgentSmithKit

/// The global template Library's invariants: always a Default group, single-group membership,
/// group deletion re-homes to Default, restore reconciles orphans, and the snapshot round-trips.
@Suite struct TemplateLibraryStoreTests {

    private func tmpl(_ title: String) -> AgentTask {
        AgentTask(title: title, description: "d", isTemplate: true)
    }

    @Test func upsertLandsInDefaultGroup() async {
        let store = TemplateLibraryStore()
        let t = tmpl("A")
        await store.upsert(t)
        let groups = await store.allGroups()
        #expect(groups.contains { $0.name == "Default" && $0.templateIDs.contains(t.id) })
    }

    @Test func moveToGroupIsSingleMembership() async {
        let store = TemplateLibraryStore()
        let t = tmpl("A")
        await store.upsert(t)
        let work = await store.createGroup(name: "Work")
        await store.moveTemplate(t.id, toGroup: work.id)
        let containing = await store.allGroups().filter { $0.templateIDs.contains(t.id) }
        #expect(containing.count == 1)
        #expect(containing.first?.name == "Work")
    }

    @Test func deleteGroupRehomesToDefault() async {
        let store = TemplateLibraryStore()
        let t = tmpl("A")
        await store.upsert(t)
        let work = await store.createGroup(name: "Work")
        await store.moveTemplate(t.id, toGroup: work.id)
        await store.deleteGroup(id: work.id)
        let groups = await store.allGroups()
        #expect(!groups.contains { $0.id == work.id })
        #expect(groups.first { $0.name == "Default" }?.templateIDs.contains(t.id) == true)
    }

    @Test func restoreReconcilesOrphansIntoDefault() async {
        let store = TemplateLibraryStore()
        let t = tmpl("A")
        // A snapshot whose groups do NOT reference the template — restore must sweep it into Default.
        await store.restore(TemplateLibrarySnapshot(templates: [t], groups: []))
        let groups = await store.allGroups()
        #expect(groups.first { $0.name == "Default" }?.templateIDs.contains(t.id) == true)
    }

    @Test func removeTemplateDropsItFromItsGroup() async {
        let store = TemplateLibraryStore()
        let t = tmpl("A")
        await store.upsert(t)
        _ = await store.removeTemplate(id: t.id)
        #expect(await store.template(id: t.id) == nil)
        #expect(await store.allGroups().allSatisfy { !$0.templateIDs.contains(t.id) })
    }

    @Test func snapshotRoundTripsThroughJSON() throws {
        let t = AgentTask(title: "A", description: "d", isTemplate: true)
        let snap = TemplateLibrarySnapshot(
            templates: [t], groups: [TemplateGroup(name: "Default", templateIDs: [t.id])])
        let back = try JSONDecoder().decode(TemplateLibrarySnapshot.self, from: JSONEncoder().encode(snap))
        #expect(back == snap)
    }
}
