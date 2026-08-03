import Foundation

/// A user-created folder of template tasks in the global Library. Templates have SINGLE-group
/// membership (a template is in exactly one group), and there is always a seeded "Default" group that
/// new templates land in. Subgroups are intentionally not modeled.
public struct TemplateGroup: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    /// Ordered ids of the templates in this group. Disjoint across groups (single membership),
    /// enforced by `TemplateLibraryStore`.
    public var templateIDs: [UUID]

    public init(id: UUID = UUID(), name: String, templateIDs: [UUID] = []) {
        self.id = id
        self.name = name
        self.templateIDs = templateIDs
    }
}

/// The on-disk shape of the Library: the template tasks plus their group organization, persisted
/// together in one global file.
public struct TemplateLibrarySnapshot: Codable, Sendable, Equatable {
    public var templates: [AgentTask]
    public var groups: [TemplateGroup]

    public init(templates: [AgentTask], groups: [TemplateGroup]) {
        self.templates = templates
        self.groups = groups
    }
}

/// The single, GLOBAL store of template tasks + their groups — shared by every session/window, mirroring
/// `InactiveTaskStore`. Templates are pure definitions (no transcript/worker), so they live here rather
/// than in any one session; starting one instantiates an instance into the CURRENT session.
///
/// Invariants it maintains: there is always a "Default" group; every template is in exactly ONE group
/// (orphans are reconciled into Default); deleting a group re-homes its templates to Default and never
/// deletes Default itself.
public actor TemplateLibraryStore {

    private var templates: [UUID: AgentTask] = [:]
    private var groups: [TemplateGroup] = []
    private var onChange: (@Sendable () -> Void)?

    public init() {}

    public func setOnChange(_ handler: @escaping @Sendable () -> Void) {
        onChange = handler
    }

    // MARK: Reads

    /// All templates, newest first.
    public func allTemplates() -> [AgentTask] {
        templates.values.sorted { $0.createdAt > $1.createdAt }
    }
    public func allGroups() -> [TemplateGroup] { groups }
    public func template(id: UUID) -> AgentTask? { templates[id] }
    public func snapshot() -> TemplateLibrarySnapshot {
        TemplateLibrarySnapshot(templates: Array(templates.values), groups: groups)
    }

    // MARK: Templates

    /// Inserts or updates a template. A brand-new one (in no group yet) lands in Default.
    public func upsert(_ template: AgentTask) {
        let isNew = templates[template.id] == nil
        templates[template.id] = template
        if isNew {
            let defaultID = ensureDefaultGroup()
            if !groups.contains(where: { $0.templateIDs.contains(template.id) }),
               let idx = groups.firstIndex(where: { $0.id == defaultID }) {
                groups[idx].templateIDs.append(template.id)
            }
        }
        onChange?()
    }

    /// Removes a template from the library entirely (and from its group).
    @discardableResult
    public func removeTemplate(id: UUID) -> AgentTask? {
        let removed = templates.removeValue(forKey: id)
        if removed != nil {
            for i in groups.indices { groups[i].templateIDs.removeAll { $0 == id } }
            onChange?()
        }
        return removed
    }

    /// Moves a template to `groupID`, removing it from whatever group it was in (single membership).
    public func moveTemplate(_ templateID: UUID, toGroup groupID: UUID) {
        guard templates[templateID] != nil, groups.contains(where: { $0.id == groupID }) else { return }
        for i in groups.indices { groups[i].templateIDs.removeAll { $0 == templateID } }
        if let idx = groups.firstIndex(where: { $0.id == groupID }) {
            groups[idx].templateIDs.append(templateID)
        }
        onChange?()
    }

    // MARK: Groups

    @discardableResult
    public func createGroup(name: String) -> TemplateGroup {
        let group = TemplateGroup(name: name)
        groups.append(group)
        onChange?()
        return group
    }

    public func renameGroup(id: UUID, to name: String) {
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[idx].name = name
        onChange?()
    }

    /// Deletes a group, re-homing its templates into Default. Refuses to delete the Default group.
    public func deleteGroup(id: UUID) {
        let defaultID = ensureDefaultGroup()
        guard id != defaultID, let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        let orphaned = groups[idx].templateIDs
        groups.remove(at: idx)
        if !orphaned.isEmpty, let dIdx = groups.firstIndex(where: { $0.id == defaultID }) {
            groups[dIdx].templateIDs.append(contentsOf: orphaned.filter { templates[$0] != nil })
        }
        onChange?()
    }

    // MARK: Restore / migration seed

    /// Replaces all templates + groups from a persisted (or migrated) snapshot, then reconciles so the
    /// invariants hold regardless of what was on disk.
    public func restore(_ snapshot: TemplateLibrarySnapshot) {
        templates = Dictionary(snapshot.templates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        groups = snapshot.groups
        reconcileMembership()
    }

    // MARK: Invariants

    private func ensureDefaultGroup() -> UUID {
        if let existing = groups.first(where: { $0.name == "Default" }) { return existing.id }
        let group = TemplateGroup(name: "Default")
        groups.insert(group, at: 0)
        return group.id
    }

    /// Every template ends up in exactly one group: drop stale/duplicate ids, and sweep any template
    /// not referenced by any group into Default.
    private func reconcileMembership() {
        _ = ensureDefaultGroup()
        var placed = Set<UUID>()
        for i in groups.indices {
            groups[i].templateIDs = groups[i].templateIDs.filter { id in
                templates[id] != nil && placed.insert(id).inserted
            }
        }
        let orphans = templates.keys.filter { !placed.contains($0) }
        if !orphans.isEmpty, let dIdx = groups.firstIndex(where: { $0.name == "Default" }) {
            groups[dIdx].templateIDs.append(contentsOf: orphans)
        }
    }
}
