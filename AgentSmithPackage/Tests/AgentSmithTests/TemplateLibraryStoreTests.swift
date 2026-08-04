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

    // MARK: - Group identity is the reserved `.default`, NOT the display name (F10)

    @Test func seededDefaultGroupHasReservedIdentity() async {
        let store = TemplateLibraryStore()
        await store.upsert(tmpl("A"))
        let groups = await store.allGroups()
        #expect(groups.contains { $0.id == .default })
        #expect(groups.first { $0.id == .default }?.name == "Default")
    }

    /// A user is free to create a group literally named "Default"; it must get its OWN identity and stay
    /// fully manageable, never colliding with (or masquerading as) the seeded default.
    @Test func userGroupNamedDefaultDoesNotCollide() async {
        let store = TemplateLibraryStore()
        await store.upsert(tmpl("seed")) // materializes the reserved default
        let mine = await store.createGroup(name: "Default")
        #expect(mine.id != .default)
        // Two groups named "Default" now exist, with distinct identities.
        let named = await store.allGroups().filter { $0.name == "Default" }
        #expect(named.count == 2)
        // The user's group is deletable (the reserved default is not).
        await store.deleteGroup(id: mine.id)
        #expect(await store.allGroups().contains { $0.id == mine.id } == false)
        #expect(await store.allGroups().contains { $0.id == .default })
    }

    /// LEGACY data stored the default group as a bare-UUID id keyed only by its name. Restore must
    /// promote it to the reserved `.default` identity (and keep its templates).
    @Test func legacyDefaultGroupMigratesOnRestore() async {
        let t = tmpl("A")
        let legacyDefault = TemplateGroup(id: .other(UUID()), name: "Default", templateIDs: [t.id])
        let store = TemplateLibraryStore()
        await store.restore(TemplateLibrarySnapshot(templates: [t], groups: [legacyDefault]))
        let groups = await store.allGroups()
        // Exactly one `.default`, and it kept the template — no second empty default was minted.
        #expect(groups.filter { $0.id == .default }.count == 1)
        #expect(groups.first { $0.id == .default }?.templateIDs.contains(t.id) == true)
    }

    @Test func groupIDCodableRoundTrips() throws {
        let enc = JSONEncoder(), dec = JSONDecoder()
        // `.default` serializes as the token; `.other` as the UUID string.
        #expect(try dec.decode(TemplateGroup.ID.self, from: enc.encode(TemplateGroup.ID.default)) == .default)
        let uuid = UUID()
        #expect(try dec.decode(TemplateGroup.ID.self, from: enc.encode(TemplateGroup.ID.other(uuid))) == .other(uuid))
        // A legacy bare-UUID-string id decodes as `.other`.
        #expect(try dec.decode(TemplateGroup.ID.self, from: Data("\"\(uuid.uuidString)\"".utf8)) == .other(uuid))
    }
}
