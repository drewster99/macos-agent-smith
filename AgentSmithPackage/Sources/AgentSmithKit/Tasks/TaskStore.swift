import Foundation

/// Thread-safe storage for one session's *active* tasks.
///
/// Archived and recently-deleted tasks are global — they live in the shared
/// `InactiveTaskStore`, not here. The disposition-changing methods move tasks between this
/// per-session store and that global store: archiving/deleting pushes a task out to the
/// global store; unarchiving/undeleting pulls it back into this (the current) session's
/// active list. When `inactiveStore` is nil (standalone/test construction) the disposition
/// methods fall back to changing the disposition in place, preserving legacy behavior.
public actor TaskStore {
    private var tasks: [UUID: AgentTask] = [:]
    private var onChange: (@Sendable () -> Void)?
    /// Fired the first time a task transitions to a terminal status (`.completed` or `.failed`).
    /// Used by `OrchestrationRuntime` to cancel any scheduled wakes pinned to the task.
    private var onTaskTerminated: (@Sendable (UUID) -> Void)?
    /// The shared global store for archived + recently-deleted tasks. See the type doc.
    private let inactiveStore: InactiveTaskStore?
    /// Durably writes the global inactive store to disk *now*, returning whether it succeeded.
    /// Injected by the app so a cross-store move can guarantee the destination file is on disk
    /// before the source is removed — a crash in the gap must never leave a task absent from both
    /// files. Nil in standalone/test construction (the move is then best-effort, as before).
    private var durablyPersistInactiveNow: (@Sendable () async -> Bool)?
    /// Durably writes this session's active-task snapshot to disk *now*, returning success. Same
    /// purpose as `durablyPersistInactiveNow`, for the restore direction (global → active).
    private var durablyPersistActiveNow: (@Sendable ([AgentTask]) async -> Bool)?

    /// Whether the automatic stale-completed sweep is enabled. Off until the app layer pushes the
    /// user's Settings value via `setAutoArchivePolicy`. This gate is consulted ONLY by the
    /// automatic triggers (via `autoArchiveStaleCompletedIfEnabled`); the underlying
    /// `archiveStaleCompleted(olderThan:)` mechanism stays callable directly regardless.
    private var autoArchiveEnabled = false
    /// Age a completed task must exceed before the automatic sweep archives it. Only consulted when
    /// `autoArchiveEnabled`. Defaults to the historical four-hour cutoff.
    private var autoArchiveInterval: TimeInterval = 4 * 3600

    public init(inactiveStore: InactiveTaskStore? = nil) {
        self.inactiveStore = inactiveStore
    }

    /// Pushes the user's auto-archive Settings into the store — the single source of the effective
    /// policy the automatic triggers consult. Called at session start and live on a Settings change.
    /// `interval` is taken as given; its range is validated at the UI boundary (the Settings
    /// Stepper enforces 1–168 hours).
    public func setAutoArchivePolicy(enabled: Bool, interval: TimeInterval) {
        autoArchiveEnabled = enabled
        autoArchiveInterval = interval
    }

    /// Gated entry point for the automatic triggers (task creation, app launch). No-op unless the
    /// user has enabled auto-archive; otherwise sweeps at the configured cutoff.
    public func autoArchiveStaleCompletedIfEnabled() async {
        guard autoArchiveEnabled else { return }
        await archiveStaleCompleted(olderThan: autoArchiveInterval)
    }

    /// Registers a callback fired whenever tasks change.
    public func setOnChange(_ handler: @escaping @Sendable () -> Void) {
        onChange = handler
    }

    /// Injects the durable-write hooks that make cross-store disposition moves crash-safe. The
    /// `inactive` hook durably persists the global inactive store; `active` durably persists the
    /// given snapshot of this session's active tasks. Both return whether the write succeeded.
    public func setDurablePersistHooks(
        inactive: @escaping @Sendable () async -> Bool,
        active: @escaping @Sendable ([AgentTask]) async -> Bool
    ) {
        durablyPersistInactiveNow = inactive
        durablyPersistActiveNow = active
    }

    /// Registers a callback fired when a task transitions to a terminal status for the first time.
    public func setOnTaskTerminated(_ handler: @escaping @Sendable (UUID) -> Void) {
        onTaskTerminated = handler
    }

    /// All tasks, newest first.
    public func allTasks() -> [AgentTask] {
        tasks.values.sorted { $0.createdAt > $1.createdAt }
    }

    /// Retrieves a single active task by ID (this session only). Archived/deleted tasks live in
    /// the global store — use `taskAnyDisposition(id:)` to look across both.
    public func task(id: UUID) -> AgentTask? {
        tasks[id]
    }

    /// Looks up a task by ID across this session's active list and the global inactive store
    /// (archived + deleted). Used by tools that operate on a task regardless of disposition.
    public func taskAnyDisposition(id: UUID) async -> AgentTask? {
        if let active = tasks[id] { return active }
        return await inactiveStore?.task(id: id)
    }

    /// All globally-inactive tasks (archived + recently-deleted), across every session. Empty
    /// when no inactive store is wired (legacy/test construction).
    public func allInactiveTasks() async -> [AgentTask] {
        guard let inactiveStore else { return [] }
        return await inactiveStore.all()
    }

    /// Toggles a task's template flag. A template, when started, clones a fresh instance
    /// rather than running in place. Any task can become a template or stop being one.
    /// Becoming a template normalizes a terminal task to a clean `.pending` launcher
    /// (prior result preserved into history) so it's startable and carries no stale
    /// run-state — a template never runs itself.
    @discardableResult
    public func setTemplate(id: UUID, isTemplate: Bool) -> String? {
        guard var task = tasks[id] else { return "Task not found: \(id.uuidString)" }
        guard !task.status.isInProgress else {
            return "Task '\(task.title)' cannot be converted while it is \(task.status.rawValue). Stop or finish it first."
        }
        let wasTemplate = task.isTemplate
        task.isTemplate = isTemplate
        if isTemplate {
            preservePriorRunAsTemplateChildIfNeeded(&task, wasTemplate: wasTemplate)
            task.templateInputValues = [:]
            normalizeTemplateLauncher(&task)
        } else {
            clearTemplateAuthoringFieldsIfDemoting(&task, wasTemplate: wasTemplate)
        }
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
        return nil
    }

    /// Clears the template authoring fields — but ONLY when an actual template is being demoted.
    /// A task that was never a template keeps them, and that distinction matters: a template
    /// INSTANCE is a non-template task carrying a snapshot of its template's input definitions
    /// plus the concrete `templateInputValues` its run was created with. Those values are the
    /// record of what that run was told to do — they render into the worker's briefing, the
    /// security agent's scoping prompt, and the validator payload. Clearing them on an unrelated
    /// title or description edit silently destroys that record.
    private func clearTemplateAuthoringFieldsIfDemoting(_ task: inout AgentTask, wasTemplate: Bool) {
        guard wasTemplate else { return }
        task.templateInputDefinitions = []
        task.templateInstanceTitleTemplate = nil
        task.templateInputValues = [:]
    }

    public func setTemplateInputDefinitions(id: UUID, definitions: [TemplateInputDefinition]) -> String? {
        guard var task = tasks[id] else { return "Task not found: \(id.uuidString)" }
        guard task.isTemplate else {
            return "Task '\(task.title)' is not a template. Only template tasks can define template inputs."
        }
        if let error = TemplateInputValidation.validateDefinitions(definitions) {
            return error
        }
        if let titleTemplate = task.templateInstanceTitleTemplate,
           !titleTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let problem = TemplateStringRenderer.validate(titleTemplate, allowedNames: Set(definitions.map(\.name))) {
            return "Template inputs would invalidate the instance title template: \(problem) Clear or update the title template first."
        }
        task.templateInputDefinitions = definitions
        task.templateInputValues = [:]
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
        return nil
    }

    public func setTemplateInstanceTitleTemplate(id: UUID, titleTemplate: String?) -> String? {
        guard var task = tasks[id] else { return "Task not found: \(id.uuidString)" }
        guard task.isTemplate else {
            return "Task '\(task.title)' is not a template. Only template tasks can define an instance title template."
        }
        let normalized = titleTemplate?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalized, !normalized.isEmpty {
            let names = Set(task.templateInputDefinitions.map(\.name))
            if let problem = TemplateStringRenderer.validate(normalized, allowedNames: names) {
                return problem
            }
            task.templateInstanceTitleTemplate = normalized
        } else {
            task.templateInstanceTitleTemplate = nil
        }
        task.updatedAt = Date()
        task.lastEditedAt = Date()
        tasks[id] = task
        onChange?()
        return nil
    }

    @discardableResult
    public func updateDefinition(
        id: UUID,
        title: String,
        description: String,
        isTemplate: Bool,
        templateInputDefinitions: [TemplateInputDefinition],
        templateInstanceTitleTemplate: String?
    ) -> String? {
        guard var task = tasks[id] else { return "Task not found: \(id.uuidString)" }
        guard task.status.isDescriptionEditable else {
            return "Task '\(task.title)' cannot be edited while it is \(task.status.rawValue)."
        }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return "Title must not be empty." }
        guard !description.isEmpty else { return "Description must not be empty." }
        if isTemplate, let problem = TemplateInputValidation.validateDefinitions(templateInputDefinitions) {
            return problem
        }
        let normalizedTitleTemplate = templateInstanceTitleTemplate?.trimmingCharacters(in: .whitespacesAndNewlines)
        if isTemplate, let normalizedTitleTemplate, !normalizedTitleTemplate.isEmpty {
            let names = Set(templateInputDefinitions.map(\.name))
            if let problem = TemplateStringRenderer.validate(normalizedTitleTemplate, allowedNames: names) {
                return problem
            }
        }

        let wasTemplate = task.isTemplate
        task.isTemplate = isTemplate
        if isTemplate {
            // Archive the prior run BEFORE the new title/description land, so the preserved
            // child records the text the run actually executed under — not the edit that
            // retired it.
            preservePriorRunAsTemplateChildIfNeeded(&task, wasTemplate: wasTemplate)
            task.templateInputDefinitions = templateInputDefinitions
            task.templateInstanceTitleTemplate = normalizedTitleTemplate?.isEmpty == false ? normalizedTitleTemplate : nil
            task.templateInputValues = [:]
            normalizeTemplateLauncher(&task)
        } else {
            clearTemplateAuthoringFieldsIfDemoting(&task, wasTemplate: wasTemplate)
        }
        task.title = title
        task.description = description
        let now = Date()
        task.updatedAt = now
        task.lastEditedAt = now
        tasks[id] = task
        onChange?()
        return nil
    }

    private func hasPriorRunState(_ task: AgentTask) -> Bool {
        task.startedAt != nil
            || task.completedAt != nil
            || task.result != nil
            || task.commentary != nil
            || !task.resultAttachments.isEmpty
            || !task.resultItems.isEmpty
            || task.validation != nil
            || task.status.isTerminal
    }

    private func preservePriorRunAsTemplateChildIfNeeded(_ task: inout AgentTask, wasTemplate: Bool) {
        guard !wasTemplate, hasPriorRunState(task) else { return }
        var historicalRun = task
        historicalRun.id = UUID()
        historicalRun.isTemplate = false
        historicalRun.parentTaskID = task.id
        historicalRun.assigneeIDs = []
        historicalRun.templateInputDefinitions = []
        historicalRun.templateInstanceTitleTemplate = nil
        historicalRun.templateInputValues = [:]
        historicalRun.scheduledRunAt = nil
        historicalRun.updatedAt = Date()
        tasks[historicalRun.id] = historicalRun
        appendUpdate(to: &task, "Converted this task into a template. Preserved the prior run as child task \(historicalRun.id.uuidString).")
    }

    private func normalizeTemplateLauncher(_ task: inout AgentTask) {
        task.status = .pending
        task.result = nil
        task.commentary = nil
        task.resultAttachments = []
        task.resultItems = []
        task.completedAt = nil
        task.startedAt = nil
        task.validation = nil
        task.assigneeIDs = []
        task.helpRequest = nil
    }

    /// Clones a template into a fresh, runnable INSTANCE and adds it to the store.
    /// Carries over the "what to do" fields — title, description, description
    /// attachments, the step plan (each reset to `.pending`, notes cleared), and the
    /// acceptance criteria (fresh criterion IDs, no verdicts). Blanks every run-state
    /// field (result, commentary, updates, summary, validation, timestamps, scoped
    /// tools, relevant-context, help request) and the template/recurrence-carrying
    /// fields (`isTemplate = false`, `scheduledRunAt = nil`). Sets `parentTaskID` to the
    /// template. Returns the instance, or nil if the template is missing.
    public func cloneTemplateInstance(templateID: UUID) -> AgentTask? {
        switch instantiateTemplate(templateID: templateID, inputValues: [:]) {
        case .success(let instance): return instance
        case .failure: return nil
        }
    }

    public enum TemplateInstantiationResult: Sendable, Equatable {
        case success(AgentTask)
        case failure(String)
    }

    public func instantiateTemplate(templateID: UUID, inputValues: [String: String]) -> TemplateInstantiationResult {
        guard let template = tasks[templateID] else {
            return .failure("Template task not found: \(templateID.uuidString)")
        }
        guard template.isTemplate else {
            return .failure("Task '\(template.title)' is not a template and cannot accept template inputs.")
        }
        let resolvedInputs: TemplateInputValidation.ResolvedInputs
        switch TemplateInputValidation.resolveValues(definitions: template.templateInputDefinitions, rawValues: inputValues) {
        case .success(let resolved):
            resolvedInputs = resolved
        case .failure(let message):
            return .failure(message)
        }
        guard resolvedInputs.missingRequiredNames.isEmpty else {
            let details = template.templateInputDefinitions
                .filter { resolvedInputs.missingRequiredNames.contains($0.name) }
                .map { "- \($0.name): \($0.description)" }
                .joined(separator: "\n")
            return .failure("""
                Missing required template input(s): \(resolvedInputs.missingRequiredNames.joined(separator: ", ")).
                \(details)
                """)
        }
        let clonedSteps = template.steps.map { step in
            TaskStep(text: step.text, status: .pending, note: nil, origin: step.origin)
        }
        let clonedCriteria = template.acceptanceCriteria.map { criterion in
            AcceptanceCriterion(
                name: criterion.name,
                validationPrompt: criterion.validationPrompt,
                inputEnumeratorPrompt: criterion.inputEnumeratorPrompt,
                waivable: criterion.waivable,
                origin: criterion.origin,
                validator: criterion.validator,
                prepare: criterion.prepare
            )
        }
        let instanceTitle: String
        if let titleTemplate = template.templateInstanceTitleTemplate,
           !titleTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            switch TemplateStringRenderer.render(
                titleTemplate,
                values: resolvedInputs.values,
                definedNames: Set(template.templateInputDefinitions.map(\.name))
            ) {
            case .success(let rendered):
                let trimmed = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
                instanceTitle = trimmed.isEmpty ? template.title : trimmed
            case .failure(let message):
                return .failure(message)
            }
        } else {
            instanceTitle = template.title
        }
        let instance = AgentTask(
            title: instanceTitle,
            description: template.description,
            status: .pending,
            disposition: .active,
            descriptionAttachments: template.descriptionAttachments,
            userToolOverrides: template.userToolOverrides,
            acceptanceCriteria: clonedCriteria,
            steps: clonedSteps,
            isTemplate: false,
            parentTaskID: template.id,
            templateInputDefinitions: template.templateInputDefinitions,
            templateInputValues: resolvedInputs.values
        )
        tasks[instance.id] = instance
        onChange?()
        return .success(instance)
    }

    /// Adds a new task and returns it. When auto-archive is enabled (Settings), also sweeps any
    /// completed tasks older than the configured cutoff out to the Archived bucket first.
    /// When `scheduledRunAt` is non-nil and in the future the new task is created with status
    /// `.scheduled` so the auto-runner skips it; the runtime should pair the call with a
    /// matching wake bound to the new task's id.
    @discardableResult
    public func addTask(
        title: String,
        description: String,
        scheduledRunAt: Date? = nil,
        descriptionAttachments: [Attachment] = [],
        isTemplate: Bool = false,
        templateInputDefinitions: [TemplateInputDefinition] = []
    ) async -> AgentTask {
        await autoArchiveStaleCompletedIfEnabled()
        let definitions = isTemplate ? templateInputDefinitions : []
        let initialStatus: AgentTask.Status = (scheduledRunAt.map { $0 > Date() } ?? false) ? .scheduled : .pending
        let task = AgentTask(
            title: title,
            description: description,
            status: initialStatus,
            scheduledRunAt: scheduledRunAt,
            descriptionAttachments: descriptionAttachments,
            isTemplate: isTemplate,
            templateInputDefinitions: definitions
        )
        tasks[task.id] = task
        onChange?()
        return task
    }

    /// Promotes a `.scheduled` task to `.pending` so the queue (or `run_task`) can pick it up.
    /// No-op when the task is missing, already non-`.scheduled`, or has a future scheduledRunAt
    /// the caller didn't ask to bypass.
    @discardableResult
    public func promoteScheduledToPending(id: UUID) -> Bool {
        guard var task = tasks[id], task.status == .scheduled else { return false }
        task.status = .pending
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
        return true
    }

    /// Archives all active completed tasks whose `updatedAt` is older than `interval` seconds,
    /// moving them out to the global inactive store. This is the pure mechanism, unconditional on
    /// the user's auto-archive Setting — the automatic triggers reach it via the gated
    /// `autoArchiveStaleCompletedIfEnabled`. `updatedAt` is intentionally not bumped, so the
    /// original completion time drives the archive sort order.
    public func archiveStaleCompleted(olderThan interval: TimeInterval = 4 * 3600) async {
        let cutoff = Date().addingTimeInterval(-interval)
        let stale = tasks.values.filter {
            $0.status == .completed && $0.disposition == .active && $0.updatedAt < cutoff
        }
        guard !stale.isEmpty else { return }
        guard let inactiveStore else {
            for task in stale {
                var moved = task
                moved.disposition = .archived
                tasks[task.id] = moved
            }
            onChange?()
            return
        }
        // Batch move with the same destination-durable-before-source-removal ordering as `move`,
        // but a SINGLE durable write for the whole batch (not one per task): insert every stale
        // task into the global store, durably persist it once, then strip them from active. A crash
        // in the gap leaves them in both files; load-time reconciliation drops the duplicate. On a
        // failed global write, roll the inserts back and leave the tasks active — the load-time
        // stale-archive path re-archives them safely next launch. `updatedAt` is intentionally NOT
        // bumped, preserving the original completion time as the archive sort key (and letting the
        // reconciliation's `>=` tiebreak still resolve an equal-timestamp crash-duplicate).
        for task in stale {
            var moved = task
            moved.disposition = .archived
            await inactiveStore.insert(moved)
        }
        if let durablyPersistInactiveNow, await durablyPersistInactiveNow() == false {
            for task in stale { await inactiveStore.remove(id: task.id) }
            return
        }
        for task in stale { tasks.removeValue(forKey: task.id) }
        onChange?()
    }

    /// Updates a task's status.
    /// If the new status is in-progress (pending, running, paused), the task is automatically
    /// restored to the active disposition — it cannot remain archived or deleted while active.
    /// The first transition to a terminal status (`.completed`/`.failed`) fires `onTaskTerminated`
    /// so the runtime can dispose any wakes scoped to the task.
    public func updateStatus(id: UUID, status: AgentTask.Status) {
        guard var task = tasks[id] else { return }

        // Invariant: a task in `.awaitingReview` MUST have a non-empty result. The only
        // legitimate caller setting this status is `TaskCompleteTool`, which always calls
        // `setResult` first. Refuse the transition if the invariant would be violated —
        // this prevents the "Task Completed" banner from being posted with no body to
        // deliver, regardless of how a future bug might land us here.
        if status == .awaitingReview {
            let trimmed = task.result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty {
                assertionFailure("TaskStore.updateStatus(.awaitingReview) called for task \(id) with no stored result. Refusing transition.")
                return
            }
        }

        let now = Date()
        let wasTerminal = task.status == .completed || task.status == .failed
        let isTerminal = status == .completed || status == .failed
        task.status = status
        task.updatedAt = now
        if status == .running && task.startedAt == nil {
            task.startedAt = now
        }
        if isTerminal {
            task.completedAt = now
        }
        if status.isInProgress {
            task.disposition = .active
        }
        tasks[id] = task
        onChange?()
        if isTerminal && !wasTerminal {
            onTaskTerminated?(id)
        }
    }

    /// Atomically transitions a task to `newStatus` only if its current status equals
    /// `expected`, returning whether the transition was applied. The compare and the write
    /// run in a single synchronous actor hop (no `await` between them), so a caller acting on
    /// a stale snapshot cannot clobber a task that has since moved off `expected` — e.g. a
    /// `task_complete` landing `.completed` after a self-terminating agent snapshotted the
    /// task as `.running` and tried to fail it. Routes through `updateStatus` so terminal
    /// side-effects (`completedAt`, `onTaskTerminated`) stay consistent.
    @discardableResult
    public func updateStatus(id: UUID, ifCurrentlyEquals expected: AgentTask.Status, to newStatus: AgentTask.Status) -> Bool {
        guard tasks[id]?.status == expected else { return false }
        updateStatus(id: id, status: newStatus)
        return true
    }

    /// Appends an update to a task copy. Caller writes back. Update history is unbounded.
    private func appendUpdate(to task: inout AgentTask, _ message: String) {
        task.updates.append(AgentTask.TaskUpdate(message: message))
    }

    /// Preserves a task's current result (and commentary) into its update history before that
    /// result is cleared or replaced, so re-running or re-completing a task doesn't silently
    /// erase the original deliverable — the user can still recover it after the live transcript
    /// is gone. No-op when there's no result to preserve.
    private func preserveResultIntoHistory(_ task: inout AgentTask) {
        guard let previous = task.result, !previous.isEmpty else { return }
        var line = "Replacing previous result:\n\(previous)"
        if let commentary = task.commentary, !commentary.isEmpty {
            line += "\n\nPrevious commentary:\n\(commentary)"
        }
        appendUpdate(to: &task, line)
    }

    /// Resets a failed task's terminal state so it can be retried via `run_task`. Clears
    /// `result`, `commentary`, and `completedAt`; the caller is responsible for transitioning
    /// the status back to `.pending` (or via run_task → restart). Returns false if the task
    /// is missing or not in `.failed` state.
    @discardableResult
    public func resetFailedTask(id: UUID) -> Bool {
        guard var task = tasks[id], task.status == .failed else { return false }
        preserveResultIntoHistory(&task)
        task.result = nil
        task.commentary = nil
        task.completedAt = nil
        task.status = .pending
        task.disposition = .active
        // A fresh attempt against a discarded result gets a fresh ledger: counters reset (so a
        // stall-failed task doesn't insta-fail its first rejection) AND the sticky ACCEPTs are
        // dropped, so every criterion is re-judged against the NEW result rather than inheriting
        // an accept earned against the old one. A criterion is a reusable contract; a re-run is a
        // new run. (Pinned definitions are kept so the re-judge uses the same validator bodies.)
        if var validation = task.validation {
            validation.round = 0
            validation.consecutiveStallRounds = 0
            validation.verdictRecords.removeAll()
            task.validation = validation
        }
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
        return true
    }

    /// Reopens a completed task so it can be re-run via `run_task` without creating a
    /// duplicate. Clears `result`, `commentary`, and `completedAt`; flips status back to
    /// `.pending`. Returns false if the task is missing or not in `.completed` state.
    /// Distinct from `resetFailedTask` only by which terminal status it accepts —
    /// callers ask the question they want answered ("reopen completed" vs. "retry failed")
    /// rather than passing a status enum.
    @discardableResult
    public func reopenCompletedTask(id: UUID) -> Bool {
        guard var task = tasks[id], task.status == .completed else { return false }
        preserveResultIntoHistory(&task)
        task.result = nil
        task.commentary = nil
        task.completedAt = nil
        task.status = .pending
        task.disposition = .active
        // Re-running a completed task is a NEW run against a discarded result, so its verdict ledger
        // is reset just like a failed-task retry (`resetFailedTask`): drop the sticky ACCEPTs so every
        // criterion is re-judged against the new result instead of the task completing instantly on
        // verdicts earned by the old one. Pinned validator definitions are kept for the re-judge.
        if var validation = task.validation {
            validation.round = 0
            validation.consecutiveStallRounds = 0
            validation.verdictRecords.removeAll()
            task.validation = validation
        }
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
        return true
    }

    /// Assigns an agent to a task.
    public func assignAgent(taskID: UUID, agentID: UUID) {
        guard var task = tasks[taskID] else { return }
        if !task.assigneeIDs.contains(agentID) {
            task.assigneeIDs.append(agentID)
            task.updatedAt = Date()
            tasks[taskID] = task
            onChange?()
        }
    }

    /// Removes an agent from a single task's assignee list.
    /// No-op if the task doesn't exist or the agent wasn't assigned.
    public func unassignAgent(taskID: UUID, agentID: UUID) {
        guard var task = tasks[taskID] else { return }
        guard let idx = task.assigneeIDs.firstIndex(of: agentID) else { return }
        task.assigneeIDs.remove(at: idx)
        task.updatedAt = Date()
        tasks[taskID] = task
        onChange?()
    }

    /// Removes an agent from every task's assignee list. Called when an agent is
    /// terminated so stale UUIDs don't accumulate across respawns.
    /// Returns the IDs of the tasks that were actually modified (for callers that
    /// want to log or persist just those).
    @discardableResult
    public func unassignAgentFromAllTasks(agentID: UUID) -> [UUID] {
        var modified: [UUID] = []
        let now = Date()
        for (taskID, task) in tasks {
            guard let idx = task.assigneeIDs.firstIndex(of: agentID) else { continue }
            var updated = task
            updated.assigneeIDs.remove(at: idx)
            updated.updatedAt = now
            tasks[taskID] = updated
            modified.append(taskID)
        }
        if !modified.isEmpty {
            onChange?()
        }
        return modified
    }

    /// Returns the currently active running or awaiting-review task, if any.
    ///
    /// Used by Smith (who orchestrates tasks but is never in a task's `assigneeIDs`)
    /// to determine which task it's currently working in service of. When multiple
    /// tasks are active simultaneously (rare), returns the most recently started —
    /// consistent with the startup migration's `windows.last(where:)` preference.
    public func currentActiveTask() -> AgentTask? {
        tasks.values
            .filter { $0.disposition == .active && ($0.status == .starting || $0.status == .running || $0.status == .awaitingReview) }
            .max(by: { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) })
    }

    /// Returns the oldest actionable task assigned to the given agent.
    ///
    /// Tasks are sorted by `createdAt` ascending so the result is deterministic
    /// regardless of dictionary iteration order.
    public func taskForAgent(agentID: UUID) -> AgentTask? {
        let actionableStatuses: Set<AgentTask.Status> = [.pending, .running, .paused, .awaitingReview, .interrupted]
        return tasks.values
            .filter { $0.assigneeIDs.contains(agentID) && actionableStatuses.contains($0.status) }
            .sorted { $0.createdAt < $1.createdAt }
            .first
    }

    /// Appends a progress update to a task. Update history is unbounded.
    public func addUpdate(id: UUID, message: String, attachments: [Attachment] = []) {
        guard var task = tasks[id] else { return }
        task.updates.append(AgentTask.TaskUpdate(message: message, attachments: attachments))
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
    }

    /// Replaces a task's description entirely.
    ///
    /// Allowed in any state where `Status.isDescriptionEditable` returns true: the runnable
    /// states (`pending`, `paused`, `interrupted`), the terminal states (`completed`,
    /// `failed`), and `scheduled`. Excluded: `running` and `awaitingReview` — editing the
    /// description while Brown is executing or while Smith is reviewing would change the
    /// shared context out from under them.
    ///
    /// On success, `status` is preserved (a completed task stays completed) and
    /// `lastEditedAt` is stamped so the UI can show an "edited" indicator. The body of the
    /// edit is also no-op'd if the new description is identical to the old one — no
    /// `lastEditedAt` change in that case.
    ///
    /// Returns true if the update succeeded, false if the task wasn't found or its status
    /// doesn't allow editing.
    @discardableResult
    public func updateDescription(id: UUID, description: String) -> Bool {
        guard var task = tasks[id] else { return false }
        guard task.status.isDescriptionEditable else { return false }
        // Skip the no-op edit so an "edited" badge doesn't appear from a Save click that
        // didn't actually change anything.
        guard task.description != description else { return true }
        task.description = description
        let now = Date()
        task.updatedAt = now
        task.lastEditedAt = now
        tasks[id] = task
        onChange?()
        return true
    }

    /// Appends a clearly-labeled amendment to a task's description, optionally adding
    /// attachments to the task's `descriptionAttachments`. Used by Smith to relay user
    /// clarifications so that Security Agent (which reads the live description on every approval)
    /// sees the updated context. This only mutates the stored task — delivering the
    /// amendment to a running Brown is `AmendTaskTool`'s responsibility, since Brown's
    /// briefing is a one-time spawn snapshot. Attachments appended here are also
    /// re-injected into Brown's briefing on any future respawn.
    public func amendDescription(id: UUID, amendment: String, attachments: [Attachment] = []) {
        guard var task = tasks[id] else { return }
        // Dedup: don't stack an [Amendment] identical to the one already at the end of the
        // description. `run_task` amends BEFORE it tries to spawn/scope, so a failed start
        // (e.g. a tool-scoping failure) leaves the amendment applied; retrying with the same
        // instructions would otherwise append the same block over and over.
        if !task.description.hasSuffix("[Amendment]: \(amendment)") {
            task.description += "\n\n[Amendment]: \(amendment)"
        }
        if !attachments.isEmpty {
            task.descriptionAttachments.append(contentsOf: attachments)
        }
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
    }

    /// Records a help-request escalation from Brown and parks the task in `.awaitingReview`,
    /// reusing the review wait/slot machinery. `helpRequest` marks it as a blocker (not a
    /// result), so `review_work` refuses it and Smith answers via `provide_help`. Deliberately
    /// does NOT touch `result` — there is no completed work to deliver.
    // MARK: - Acceptance criteria (requester-owned)

    /// Replaces the task's acceptance criteria. Any criterion whose validation prompt,
    /// input enumerator, waivable flag, or legacy validator selection CHANGED — and any
    /// new criterion — loses its sticky verdict (its
    /// records stay in the audit ledger; only the "settled" reading resets, because the
    /// contract it was judged against no longer exists). Unchanged criteria keep their
    /// verdicts.
    public func setAcceptanceCriteria(id: UUID, criteria: [AcceptanceCriterion]) {
        guard var task = tasks[id] else { return }
        let previousByID = Dictionary(task.acceptanceCriteria.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var changedIDs: Set<UUID> = []
        for criterion in criteria {
            if let previous = previousByID[criterion.id] {
                if previous.validationPrompt != criterion.validationPrompt
                    || previous.inputEnumeratorPrompt != criterion.inputEnumeratorPrompt
                    || previous.waivable != criterion.waivable
                    || previous.validator != criterion.validator
                    || previous.prepare != criterion.prepare {
                    changedIDs.insert(criterion.id)
                }
            } else {
                changedIDs.insert(criterion.id)
            }
        }
        let previousIDs = Set(previousByID.keys)
        let currentIDs = Set(criteria.map(\.id))
        let contractChanged = !changedIDs.isEmpty || previousIDs != currentIDs
        task.acceptanceCriteria = criteria
        if var validation = task.validation {
            // Drop records for changed criteria (stickiness reset) AND for criteria no
            // longer on the task — orphaned records otherwise haunt every settled-count
            // ("4 of 3 settled", observed 2026-07-09 after Smith rewrote a criterion,
            // which mints new IDs and strands the old IDs' accepts in the ledger).
            validation.verdictRecords.removeAll {
                changedIDs.contains($0.criterionID) || !currentIDs.contains($0.criterionID)
            }
            // An edited contract gets a fresh convergence budget: rejections under the
            // OLD criteria must not count toward failing the task under the new ones
            // (agy review finding). Unchanged lists keep their counters.
            if contractChanged {
                validation.round = 0
                validation.consecutiveStallRounds = 0
            }
            task.validation = validation
        }
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
    }

    // MARK: - Steps (worker-owned, tombstone semantics)

    /// Replaces the task's step list wholesale — used by Smith's initial seeding at
    /// creation. Worker mutations go through `applyStepAction`.
    public func setSteps(id: UUID, steps: [TaskStep]) {
        guard var task = tasks[id] else { return }
        task.steps = steps
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
    }

    /// One mutation of the step list (from Brown on its own task, or Smith on an inactive
    /// task's plan). Removal is a TOMBSTONE (status `.removed`, note required) — the
    /// underlying record is append-only so the validator always sees what was skipped or
    /// removed and why. Returns a human-readable error, or nil on success.
    @discardableResult
    public func applyStepAction(taskID: UUID, action: TaskStepAction) -> String? {
        guard var task = tasks[taskID] else { return "Task not found." }
        switch action {
        case .add(let text, let origin):
            task.steps.append(TaskStep(text: text, origin: origin))
        case .update(let stepID, let newText):
            guard let index = task.steps.firstIndex(where: { $0.id == stepID }) else { return "No step with id \(stepID)." }
            guard task.steps[index].status != .removed else { return "Step \(stepID) was removed and cannot be edited." }
            task.steps[index].text = newText
        case .setStatus(let stepID, let status, let note):
            guard let index = task.steps.firstIndex(where: { $0.id == stepID }) else { return "No step with id \(stepID)." }
            guard task.steps[index].status != .removed else { return "Step \(stepID) was removed and cannot be changed." }
            if (status == .skipped || status == .removed) && (note ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                return "Skipping or removing a step requires a note explaining why."
            }
            task.steps[index].status = status
            if let note { task.steps[index].note = note }
        case .delete(let stepID, let note):
            guard let index = task.steps.firstIndex(where: { $0.id == stepID }) else { return "No step with id \(stepID)." }
            guard task.steps[index].status != .removed else { return "Step \(stepID) was already removed." }
            guard !note.trimmingCharacters(in: .whitespaces).isEmpty else { return "Deleting a step requires a note explaining why." }
            task.steps[index].status = .removed
            task.steps[index].note = note
        case .reorder(let orderedActiveIDs):
            let active = task.steps.filter(\.isActive)
            let activeIDs = Set(active.map(\.id))
            guard Set(orderedActiveIDs) == activeIDs, orderedActiveIDs.count == active.count else {
                return "reorder requires EXACTLY the current active step ids, each once, in the desired order. Call `list` to see them."
            }
            let byID = Dictionary(uniqueKeysWithValues: task.steps.map { ($0.id, $0) })
            // Reordered active steps first (in the requested order), then removed tombstones in
            // their original relative order — the record of removed steps is preserved.
            let reordered = orderedActiveIDs.compactMap { byID[$0] }
            let removed = task.steps.filter { !$0.isActive }
            task.steps = reordered + removed
        }
        task.updatedAt = Date()
        tasks[taskID] = task
        onChange?()
        return nil
    }

    // MARK: - Validation ledger

    /// Begins the next validation round and returns its number (1-based).
    public func beginValidationRound(id: UUID) -> Int? {
        guard var task = tasks[id] else { return nil }
        var validation = task.validation ?? TaskValidationState()
        validation.round += 1
        task.validation = validation
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
        return validation.round
    }

    /// Resets the validation counters (round + stall) for a fresh rework cycle — a
    /// `review_work` reject, or `run_task`'s auto-reset of a failed task. Without this,
    /// a resubmission would instantly re-fail on a stale stall counter. Sticky accepts,
    /// the verdict ledger, and pinned definitions all survive — only the counters
    /// refresh.
    public func resetValidationRound(id: UUID) {
        guard var task = tasks[id], var validation = task.validation else { return }
        validation.round = 0
        validation.consecutiveStallRounds = 0
        task.validation = validation
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
    }

    /// Records whether a rejection round made progress (settled anything new). Returns
    /// the updated consecutive-stall count: 0 after a progressing round, incremented
    /// after a stalled one. The coordinator fails the task when this hits its limit.
    public func updateValidationStall(id: UUID, progressed: Bool) -> Int {
        guard var task = tasks[id] else { return 0 }
        var validation = task.validation ?? TaskValidationState()
        let updated = progressed ? 0 : (validation.consecutiveStallRounds ?? 0) + 1
        validation.consecutiveStallRounds = updated
        task.validation = validation
        tasks[id] = task
        onChange?()
        return updated
    }

    /// Appends verdict records to the task's audit ledger — but ONLY for records whose criterion
    /// still has the SAME contract (validator / prepare / waivable) it was judged against, per the
    /// `judgedAgainst` snapshot. If a `set_acceptance_criteria` edit changed a same-text criterion
    /// mid-round (the ID is retained and the old records are dropped by `setAcceptanceCriteria`), a
    /// record produced by the now-stale validator would otherwise settle the edited criterion on an
    /// obsolete verdict and skip the new validator. The check runs HERE, on the actor that owns the
    /// live criteria, so it's atomic against a concurrent edit. Dropped criteria stay unjudged and are
    /// re-judged against the new contract next round. Returns the records actually recorded.
    @discardableResult
    public func recordCriterionVerdicts(id: UUID, records: [CriterionVerdictRecord], judgedAgainst: [AcceptanceCriterion]) -> [CriterionVerdictRecord] {
        guard var task = tasks[id], !records.isEmpty else { return [] }
        let judgedByID = Dictionary(judgedAgainst.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let currentByID = Dictionary(task.acceptanceCriteria.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let fresh = records.filter { record in
            guard let judged = judgedByID[record.criterionID], let current = currentByID[record.criterionID] else { return false }
            return current.validationPrompt == judged.validationPrompt
                && current.inputEnumeratorPrompt == judged.inputEnumeratorPrompt
                && current.validator == judged.validator
                && current.prepare == judged.prepare
                && current.waivable == judged.waivable
        }
        guard !fresh.isEmpty else { return [] }
        var validation = task.validation ?? TaskValidationState()
        validation.verdictRecords.append(contentsOf: fresh)
        task.validation = validation
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
        return fresh
    }

    /// Pins a definition body on the task at first use — later registry edits apply to
    /// future tasks, never to rounds already in flight. No-op if already pinned.
    public func pinValidatorDefinition(id: UUID, definition: EvaluatorDefinition) {
        guard var task = tasks[id] else { return }
        var validation = task.validation ?? TaskValidationState()
        guard validation.pinnedDefinitions[definition.name] == nil else { return }
        validation.pinnedDefinitions[definition.name] = definition
        task.validation = validation
        tasks[id] = task
        onChange?()
    }

    /// Materializes the implicit default criterion for a criterion-less task at first
    /// validation, making the contract visible to the user like any other criterion.
    public func materializeImplicitCriterion(id: UUID, criterion: AcceptanceCriterion) {
        guard var task = tasks[id], task.acceptanceCriteria.isEmpty else { return }
        task.acceptanceCriteria = [criterion]
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
    }

    public func requestHelp(id: UUID, request: String) {
        guard var task = tasks[id] else { return }
        task.helpRequest = request
        task.status = .awaitingReview
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
    }

    /// Clears a task's pending help request. Called when Smith answers via `provide_help`
    /// (which also returns the task to running) or otherwise resolves the escalation.
    public func clearHelpRequest(id: UUID) {
        guard var task = tasks[id], task.helpRequest != nil else { return }
        task.helpRequest = nil
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
    }

    /// Stores a result (and optional commentary) on a task.
    public func setResult(id: UUID, result: String, commentary: String?, attachments: [Attachment] = [], resultItems: [ResultItem] = []) {
        guard var task = tasks[id] else { return }
        task.result = result
        task.commentary = commentary
        task.resultAttachments = attachments
        task.resultItems = resultItems
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
    }

    /// Records the security-approved tool set on a task (per-task tool scoping). This is a
    /// **record**, not the enforcement gate — the live `ToolRegistry` enforces. When the set
    /// changes from a previously-recorded one, a labeled update is appended for history.
    public func setApprovedTools(id: UUID, approvedTools: [String]) {
        guard var task = tasks[id] else { return }
        // Persist in a stable, sorted order (callers pass `Array(Set)`, whose order is
        // nondeterministic). The change check below is set-based, so ordering never fabricates a
        // diff; sorting just keeps the on-disk list stable across writes.
        let approvedTools = approvedTools.sorted()
        let previous = task.approvedTools
        task.approvedTools = approvedTools
        if let previous, Set(previous) != Set(approvedTools) {
            // Log only the DELTA, not both full lists — the old before/after dump ran on
            // every re-scope and swamped the actual findings (and now the embedding).
            let added = Set(approvedTools).subtracting(previous).sorted()
            let removed = Set(previous).subtracting(approvedTools).sorted()
            var changes: [String] = []
            if !added.isEmpty { changes.append("+\(added.joined(separator: ", +"))") }
            if !removed.isEmpty { changes.append("-\(removed.joined(separator: ", -"))") }
            let line = "Approved tool list updated (\(changes.joined(separator: ", ")))."
            task.updates.append(AgentTask.TaskUpdate(message: line))
        }
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
    }

    /// Sets (or clears) a per-task user override for a single tool. `enabled == nil` removes the
    /// override (the tool reverts to the global policy / automatic verdict). User overrides survive
    /// re-evaluation — the live registry re-applies them after every scoping pass.
    public func setUserToolOverride(id: UUID, tool: String, enabled: Bool?) {
        guard var task = tasks[id] else { return }
        var overrides = task.userToolOverrides ?? [:]
        if let enabled {
            overrides[tool] = enabled
        } else {
            overrides.removeValue(forKey: tool)
        }
        task.userToolOverrides = overrides.isEmpty ? nil : overrides
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
    }

    /// Bulk variant of `setUserToolOverride`: applies the same `enabled` value to many tools in a
    /// single mutation (one persist, one `onChange`). `enabled == nil` clears the override for each.
    /// Backs the per-MCP-server Auto/On/Off shortcut so toggling a whole server doesn't fan out into
    /// N separate writes. No-op when `tools` is empty.
    public func setUserToolOverrides(id: UUID, tools: [String], enabled: Bool?) {
        guard !tools.isEmpty, var task = tasks[id] else { return }
        var overrides = task.userToolOverrides ?? [:]
        for tool in tools {
            if let enabled {
                overrides[tool] = enabled
            } else {
                overrides.removeValue(forKey: tool)
            }
        }
        task.userToolOverrides = overrides.isEmpty ? nil : overrides
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
    }

    /// Saves a compressed summary of Brown's last working state for resumability.
    public func setLastBrownContext(id: UUID, context: String) {
        guard var task = tasks[id] else { return }
        task.lastBrownContext = context
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
    }

    /// Increments the task's acknowledgment counter and returns the new value. Called
    /// by the first-turn acknowledgement side effect on every ack so a respawned Brown can
    /// distinguish a first-time ack (count == 1) from a continuation (count > 1) without relying
    /// on the fragile `updates.isEmpty` heuristic.
    @discardableResult
    public func incrementAcknowledgmentCount(id: UUID) -> Int {
        guard var task = tasks[id] else { return 0 }
        task.acknowledgmentCount += 1
        task.updatedAt = Date()
        let newCount = task.acknowledgmentCount
        tasks[id] = task
        onChange?()
        return newCount
    }

    /// Stores an LLM-generated summary on a completed or failed task. If the task already had a
    /// (different) summary — e.g. it was re-completed after a follow-up — the prior summary is
    /// preserved into the update history first, so re-summarization doesn't erase the original.
    public func setSummary(id: UUID, summary: String) {
        guard var task = tasks[id] else { return }
        if let previous = task.summary, !previous.isEmpty, previous != summary {
            appendUpdate(to: &task, "Replacing previous summary:\n\(previous)")
        }
        task.summary = summary
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
    }

    /// Stores relevant memories and prior tasks on a task (set at creation time).
    public func setRelevantContext(
        id: UUID,
        memories: [RelevantMemory]?,
        priorTasks: [RelevantPriorTask]?
    ) {
        guard var task = tasks[id] else { return }
        task.relevantMemories = memories
        task.relevantPriorTasks = priorTasks
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
    }

    /// Clears the stored result and commentary on a task. Preserves the prior result into the
    /// task's update history first (used by the review "request changes" path), so re-work
    /// doesn't erase the original deliverable.
    public func clearResult(id: UUID) {
        guard var task = tasks[id] else { return }
        preserveResultIntoHistory(&task)
        task.result = nil
        task.commentary = nil
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
    }

    // MARK: - Disposition management

    /// Moves a task to the (global) archive bucket.
    /// Returns false without making changes if the task is currently in progress, or if the
    /// task can't be found in either this session's active list or the global inactive store.
    @discardableResult
    public func archive(id: UUID) async -> Bool {
        if let task = tasks[id] {
            guard !task.status.isInProgress else { return false }
            guard let inactiveStore else {
                setDisposition(id: id, disposition: .archived)
                return true
            }
            return await move(task, to: .archived, in: inactiveStore)
        }
        // Already out in the global store (e.g. re-archiving, or archiving a deleted task).
        if let inactiveStore { return await inactiveStore.setDisposition(id: id, to: .archived) }
        return false
    }

    /// Moves an active task out to the global inactive store with the destination-durable-before-
    /// source-removal ordering that keeps a crash from losing it from both files. Inserts the task
    /// (with its new disposition) into the global store, durably persists that store, and only then
    /// removes the active copy. If the durable write fails, rolls the insert back and leaves the
    /// task active — nothing is lost. A crash between the durable global write and the (coalesced)
    /// active-file write leaves the task in both files; load-time reconciliation drops the duplicate
    /// by newest `updatedAt`, which the global copy always wins here.
    private func move(_ task: AgentTask, to disposition: AgentTask.TaskDisposition, in inactiveStore: InactiveTaskStore) async -> Bool {
        var moved = task
        moved.disposition = disposition
        moved.updatedAt = Date()
        await inactiveStore.insert(moved)
        if let durablyPersistInactiveNow, await durablyPersistInactiveNow() == false {
            await inactiveStore.remove(id: moved.id)   // roll back; keep the task active
            return false
        }
        tasks.removeValue(forKey: task.id)
        onChange?()
        return true
    }

    /// Soft-deletes a task by moving it to the (global) Deleted bucket.
    /// Returns false without making changes if the task is currently in progress, or if the
    /// task can't be found in either this session's active list or the global inactive store.
    @discardableResult
    public func softDelete(id: UUID) async -> Bool {
        if let task = tasks[id] {
            guard !task.status.isInProgress else { return false }
            guard let inactiveStore else {
                setDisposition(id: id, disposition: .recentlyDeleted)
                return true
            }
            return await move(task, to: .recentlyDeleted, in: inactiveStore)
        }
        // Already out in the global store (e.g. deleting an archived task).
        if let inactiveStore { return await inactiveStore.setDisposition(id: id, to: .recentlyDeleted) }
        return false
    }

    /// Returns an archived task to this (the current) session's active list.
    public func unarchive(id: UUID) async {
        await restoreFromInactive(id: id)
    }

    /// Recovers a recently-deleted task back to this (the current) session's active list.
    public func undelete(id: UUID) async {
        await restoreFromInactive(id: id)
    }

    /// Restores a task from the global inactive store to this (the current) session's active list,
    /// regardless of whether it was archived or deleted. Used by `run_task` to "redo" a task the
    /// agent referenced by ID that has since been auto-archived (or deleted).
    public func restoreToActive(id: UUID) async {
        await restoreFromInactive(id: id)
    }

    /// Pulls a task out of the global inactive store and into this session's active list.
    /// No-op when there's no inactive store (legacy in-place fallback) or the task isn't there.
    private func restoreFromInactive(id: UUID) async {
        guard let inactiveStore else {
            setDisposition(id: id, disposition: .active)
            return
        }
        guard let existing = await inactiveStore.task(id: id) else { return }
        var task = existing
        task.disposition = .active
        task.updatedAt = Date()
        task.assigneeIDs.removeAll()
        tasks[task.id] = task
        // Symmetric to `move`: durably land the task in this session's active file BEFORE removing
        // it from the global store, so a crash can't lose it from both. On a failed active write,
        // roll back and leave it in the global store. A crash between the durable active write and
        // the (coalesced) global-removal write leaves it in both files; load-time reconciliation
        // keeps the newer copy, which the freshly-stamped active copy always wins here.
        if let durablyPersistActiveNow, await durablyPersistActiveNow(Array(tasks.values)) == false {
            tasks.removeValue(forKey: task.id)
            return
        }
        await inactiveStore.remove(id: id)
        onChange?()
    }

    /// Permanently removes a task. Unrecoverable. Looks in this session's active list first,
    /// then the global inactive store (the usual case — only deleted tasks get permanently
    /// deleted). Returns false without making changes if an active task is currently in progress.
    @discardableResult
    public func permanentlyDelete(id: UUID) async -> Bool {
        if let task = tasks[id] {
            guard !task.status.isInProgress else { return false }
            tasks.removeValue(forKey: id)
            onChange?()
            return true
        }
        if let inactiveStore { return await inactiveStore.permanentlyDelete(id: id) }
        return false
    }

    /// Sets a running task to paused.
    public func pause(id: UUID) {
        updateStatus(id: id, status: .paused)
    }

    /// Marks a running task as interrupted so it can be resumed later.
    public func stop(id: UUID) {
        updateStatus(id: id, status: .interrupted)
    }

    /// Atomically transition a task's status ONLY IF it is currently one of `allowed`,
    /// returning whether it applied. Validation transitions use this: a user pause/stop can
    /// flip a `.validating` task to `.paused`/`.interrupted` between the coordinator's status
    /// snapshot and its transition, and this prevents the transition from clobbering that.
    /// Atomic because the guard and the `updateStatus` call run with no actor suspension
    /// between them.
    @discardableResult
    public func updateStatus(id: UUID, to newStatus: AgentTask.Status, ifCurrentlyIn allowed: Set<AgentTask.Status>) -> Bool {
        guard let task = tasks[id], allowed.contains(task.status) else { return false }
        updateStatus(id: id, status: newStatus)
        return true
    }

    // MARK: - Bulk operations

    /// Restores tasks from a persisted list (e.g., on app launch).
    ///
    /// Clears every restored task's `assigneeIDs` — persisted agent UUIDs are
    /// all stale at this point (the agents they refer to died with the previous
    /// process). The runtime will re-populate the list as it spawns fresh agents
    /// and assigns them via `assignAgent`.
    public func restore(_ persistedTasks: [AgentTask]) {
        for var task in persistedTasks {
            task.assigneeIDs.removeAll()
            tasks[task.id] = task
        }
        onChange?()
    }

    /// Removes all tasks.
    public func clear() {
        tasks.removeAll()
        onChange?()
    }

    // MARK: - Private

    private func setDisposition(id: UUID, disposition: AgentTask.TaskDisposition) {
        guard var task = tasks[id] else { return }
        task.disposition = disposition
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
    }
}
