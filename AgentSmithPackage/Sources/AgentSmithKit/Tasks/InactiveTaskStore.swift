import Foundation

/// Global store for tasks that have left the active list — the `.archived` and
/// `.recentlyDeleted` buckets.
///
/// Unlike `TaskStore` (one instance per session, holding only that session's *active*
/// tasks), there is a single `InactiveTaskStore` shared by every session and window:
/// archived and deleted tasks are global. The per-session `TaskStore` moves tasks into
/// this store when they're archived/deleted and pulls them back out when they're
/// restored. Persisted to `inactive_tasks.json` in the global Application Support dir.
public actor InactiveTaskStore {
    private var tasks: [UUID: AgentTask] = [:]
    private var onChange: (@Sendable () -> Void)?

    public init() {}

    /// Registers a callback fired whenever the store changes.
    public func setOnChange(_ handler: @escaping @Sendable () -> Void) {
        onChange = handler
    }

    /// All inactive tasks (archived + recently-deleted), newest first.
    public func all() -> [AgentTask] {
        tasks.values.sorted { $0.createdAt > $1.createdAt }
    }

    /// Looks up a single inactive task by ID.
    public func task(id: UUID) -> AgentTask? {
        tasks[id]
    }

    /// IDs of recently-deleted tasks. Used to keep deleted tasks out of semantic search.
    public func deletedIDs() -> Set<UUID> {
        Set(tasks.values.lazy.filter { $0.disposition == .recentlyDeleted }.map(\.id))
    }

    /// Snapshot of every stored task, for persistence.
    public func snapshot() -> [AgentTask] {
        Array(tasks.values)
    }

    /// Inserts or replaces an inactive task. The caller is responsible for having set the
    /// task's `disposition` to `.archived` or `.recentlyDeleted` before calling.
    public func insert(_ task: AgentTask) {
        tasks[task.id] = task
        onChange?()
    }

    /// Merges a batch of inactive tasks, keeping the newer copy when an id already exists.
    /// Used by the one-time migration and the defensive per-session load split. Fires
    /// `onChange` once if anything changed.
    public func merge(_ incoming: [AgentTask]) {
        var changed = false
        for task in incoming {
            if let existing = tasks[task.id], existing.updatedAt >= task.updatedAt { continue }
            tasks[task.id] = task
            changed = true
        }
        if changed { onChange?() }
    }

    /// Changes the disposition of a task already in the store (e.g. archived → recently-deleted).
    /// Returns false if the task isn't present.
    @discardableResult
    public func setDisposition(id: UUID, to disposition: AgentTask.TaskDisposition) -> Bool {
        guard var task = tasks[id] else { return false }
        task.disposition = disposition
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
        return true
    }

    /// Removes a task from the store and returns it — used when restoring a task to a
    /// session's active list. Returns nil if the task isn't present.
    @discardableResult
    public func remove(id: UUID) -> AgentTask? {
        guard let task = tasks.removeValue(forKey: id) else { return nil }
        onChange?()
        return task
    }

    /// Permanently removes a task. Unrecoverable.
    @discardableResult
    public func permanentlyDelete(id: UUID) -> Bool {
        guard tasks.removeValue(forKey: id) != nil else { return false }
        onChange?()
        return true
    }

    /// Replaces all contents from a persisted snapshot (app launch / migration). Clears any
    /// stale `assigneeIDs` — the agents they referred to died with the previous process.
    public func restore(_ persisted: [AgentTask]) {
        tasks.removeAll()
        for var task in persisted {
            task.assigneeIDs.removeAll()
            tasks[task.id] = task
        }
        onChange?()
    }
}
