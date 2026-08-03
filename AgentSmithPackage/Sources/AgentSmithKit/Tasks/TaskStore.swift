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
    /// Fired when a task LEAVES the active store via archive or soft-delete (i.e. `move`). Used by
    /// `OrchestrationRuntime` to cancel any scheduled wakes pinned to the task — a disposition change
    /// is not a terminal STATUS change, so `onTaskTerminated` never fires for it, which used to leave
    /// an archived/deleted scheduled task's wake orphaned (it fired later and was silently skipped).
    private var onTaskMovedToInactive: (@Sendable (UUID) -> Void)?
    /// The shared global store for archived + recently-deleted tasks. See the type doc.
    private let inactiveStore: InactiveTaskStore?
    /// The shared global template library. Templates may live here (after the global migration) rather
    /// than in this per-session store, so template lookups (`instantiateTemplate`) consult both.
    private let templateLibrary: TemplateLibraryStore?
    /// The session this store belongs to. Stamped onto every task created here (`addTask`,
    /// `instantiateTemplate`) as its immutable origin `sessionID`. `nil` in standalone / test stores.
    /// A set-once `var` (`setSessionID`) because the LIVE store is built inside the runtime before the
    /// session id is threaded in and adopted by the view model afterward. Note this is the stable
    /// `Session.id`, NOT the runtime's per-run `currentSessionID`.
    private var sessionID: UUID?
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

    public init(
        inactiveStore: InactiveTaskStore? = nil,
        sessionID: UUID? = nil,
        templateLibrary: TemplateLibraryStore? = nil
    ) {
        self.inactiveStore = inactiveStore
        self.sessionID = sessionID
        self.templateLibrary = templateLibrary
    }

    /// Sets the origin session ONCE (no-op if already set). Used for the live store, which is
    /// constructed inside the runtime before the session id is known and adopted afterward.
    public func setSessionID(_ id: UUID) {
        if sessionID == nil { sessionID = id }
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

    /// Registers a callback fired when a task is archived or soft-deleted (leaves the active store).
    public func setOnTaskMovedToInactive(_ handler: @escaping @Sendable (UUID) -> Void) {
        onTaskMovedToInactive = handler
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
        // Deliberately does NOT sweep the task's existing text for placeholders this change would
        // orphan. That guard was written and removed the same day: it makes RENAMING an input
        // impossible. The new name can't appear in a step until it is defined, and the definition
        // can't change while a step still names the old one — neither ordering is legal, and there
        // is no third call that does both. Its error message even advised the impossible ("update
        // that text first").
        //
        // So the rule everywhere is: a write validates the text IT writes, against the definitions
        // that will then be in effect. Removing an input can therefore leave a `{{name}}` behind in
        // text this call doesn't touch — it renders as literal text (the lenient path), the task
        // editor flags it live across the whole prospective task, and the next edit of that text
        // refuses it outright. A visible stale placeholder is worth far less than a rename nobody
        // can perform.
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
        // Only the two fields this call WRITES, checked against the definitions it is about to
        // install — so renaming an input and its references in the title and description is one
        // legal call. Extending it to the steps and criteria (which this call does not write) is
        // what deadlocked the task editor: it saves the definition first and the steps second, so
        // a user who correctly renamed the input AND fixed every step in one sheet had the save
        // refused over the step text it was about to replace. Those fields are checked by the
        // calls that write them.
        if isTemplate {
            let definedNames = Set(templateInputDefinitions.map(\.name))
            if let problem = TemplateInputValidation.firstProblem(
                in: [("title", title), ("description", description)],
                definedNames: definedNames
            ) {
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
    public func cloneTemplateInstance(templateID: UUID) async -> AgentTask? {
        switch await instantiateTemplate(templateID: templateID, inputValues: [:]) {
        case .success(let instance): return instance
        case .failure: return nil
        }
    }

    public enum TemplateInstantiationResult: Sendable, Equatable {
        case success(AgentTask)
        case failure(String)
    }

    /// Looks up a task in this session's active list, falling back to the global template library — a
    /// template may live there (after the migration) rather than in this per-session store. Used by the
    /// start path and run tools, which must resolve a template wherever it lives before instantiating it
    /// into this session. For a normal (non-template) task this is just `task(id:)`.
    public func taskOrLibraryTemplate(id: UUID) async -> AgentTask? {
        if let local = tasks[id] { return local }
        return await templateLibrary?.template(id: id)
    }

    /// Every template in the global library (empty when no library is wired). Lets `list_tasks` and the
    /// sidebar surface templates that have moved out of the per-session store into the global library.
    public func allLibraryTemplates() async -> [AgentTask] {
        await templateLibrary?.allTemplates() ?? []
    }

    public func instantiateTemplate(templateID: UUID, inputValues: [String: String]) async -> TemplateInstantiationResult {
        // A template may live in this session's tasks (before the global migration) or in the shared
        // library (after it). Prefer a local copy, fall back to the library. The instance is always
        // minted into THIS per-session store (stamped with `sessionID`), wherever the template lives.
        let template: AgentTask
        if let local = tasks[templateID] {
            template = local
        } else if let fromLibrary = await templateLibrary?.template(id: templateID) {
            template = fromLibrary
        } else {
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
        // Substitution covers EVERY authored field the run is judged and executed against, not
        // just the title. A criterion reading "the binary must be named {{app_name}}" is put to a
        // validator verbatim, and a step reading "cd {{project_dir}}" is put to a worker verbatim;
        // both are as broken by a surviving placeholder as the description is. Unknown placeholders
        // pass through untouched — see `renderSubstitutingDefinedPlaceholders` for why that is
        // deliberate, and `TemplateInputValidation.placeholderProblem` for where a typo is caught
        // instead. This function is the definition of WHICH fields substitution covers; the
        // authoring checks mirror it field for field.
        let definedNames = Set(template.templateInputDefinitions.map(\.name))
        func substituted(_ text: String, layout: TemplateStringRenderer.Layout = .preserved) -> String {
            TemplateStringRenderer.renderSubstitutingDefinedPlaceholders(
                text,
                values: resolvedInputs.values,
                definedNames: definedNames,
                layout: layout
            )
        }
        // Tombstones belong to the TEMPLATE's authoring history, not to the run. Mapping the
        // whole array (which is what this used to do) reset every `.removed` step to `.pending`
        // and shipped it to the instance as live work the author had already deleted. A fresh
        // run gets the active plan and an empty removal record of its own.
        let clonedSteps = template.steps.filter(\.isActive).map { step in
            TaskStep(text: substituted(step.text), status: .pending, note: nil, origin: step.origin)
        }
        let clonedCriteria = template.acceptanceCriteria.map { criterion in
            AcceptanceCriterion(
                name: substituted(criterion.name),
                validationPrompt: substituted(criterion.validationPrompt),
                inputEnumeratorPrompt: criterion.inputEnumeratorPrompt.map { substituted($0) },
                waivable: criterion.waivable,
                origin: criterion.origin
            )
        }
        // Composed ONCE, because both title paths need it: the template's own title is what an
        // instance inherits, and it is equally what the instance falls back to when a title
        // template renders to nothing. This was composed twice and the copies disagreed — the
        // fallback handed back the RAW title, which stopped being correct the moment
        // `template.title` began rendering like every other authored field. A template titled
        // `Localize {{app_name}}` fronted by an optional `{{locale}}` title template showed a
        // placeholder for an input the run had actually supplied.
        //
        // An author who wrote placeholders straight into the title meant them just as much as the
        // ones in the description, so it renders single-line, like the title template it stands in
        // for. That is safe as the universal fallback because `.singleLine` collapses whitespace
        // ONLY when something substituted, so a title holding no placeholders comes back
        // byte-for-byte — the raw title, reached by a longer route.
        let renderedTemplateTitle = substituted(template.title, layout: .singleLine)
        // Empty means the title was nothing BUT placeholders and every one was left blank, so there
        // is no rendered text to inherit and the author's raw text stands in — it at least names
        // the template the run came from. Deliberately not an error: failing would let a cosmetic
        // title veto a recurring scheduled run forever, the same reason an omitted optional input
        // renders empty rather than erroring.
        //
        // Whitespace-only is not treated as empty, and cannot need to be: `collapsingWhitespace`
        // trims, so a whitespace-only result implies nothing substituted, which implies the value
        // already IS `template.title` — both sides of the ternary agree.
        let titleInheritedFromTemplate = renderedTemplateTitle.isEmpty ? template.title : renderedTemplateTitle
        let instanceTitle: String
        if let titleTemplate = template.templateInstanceTitleTemplate,
           !titleTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            switch TemplateStringRenderer.render(
                titleTemplate,
                values: resolvedInputs.values,
                definedNames: definedNames
            ) {
            case .success(let rendered):
                let trimmed = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
                instanceTitle = trimmed.isEmpty ? titleInheritedFromTemplate : trimmed
            case .failure(let message):
                return .failure(message)
            }
        } else {
            instanceTitle = titleInheritedFromTemplate
        }
        let instance = AgentTask(
            title: instanceTitle,
            description: substituted(template.description),
            status: .pending,
            disposition: .active,
            descriptionAttachments: template.descriptionAttachments,
            userToolOverrides: template.userToolOverrides,
            acceptanceCriteria: clonedCriteria,
            steps: clonedSteps,
            isTemplate: false,
            parentTaskID: template.id,
            sessionID: sessionID,
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
            sessionID: sessionID,
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
        // A retry is a fresh attempt at the whole plan, so the plan starts unstarted. Without
        // this the retry's worker inherits a fully-checked list from the run that FAILED and
        // reads it as "already done."
        resetActiveStepsForFreshAttempt(&task)
        // A fresh attempt against a discarded result gets a fresh ledger: counters reset (so a
        // stall-failed task doesn't insta-fail its first rejection) AND the sticky ACCEPTs are
        // dropped, so every criterion is re-judged against the NEW result rather than inheriting
        // an accept earned against the old one. A criterion is a reusable contract; a re-run is a
        // new run. (Pinned definitions are kept so the re-judge uses the same validator bodies.)
        // The REJECTION HISTORY survives untouched: "the criteria were weakened and then retried"
        // is the exact sequence it exists to make visible, and this is its second step.
        if var validation = task.validation {
            validation.round = 0
            validation.consecutiveValidationsWithoutNewApprovals = 0
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
    ///
    /// Deliberately does NOT reset the step statuses, which is where it parts company with
    /// `resetFailedTask`. Reopening means the work landed but something was incomplete,
    /// broken, or needs more information — the completed steps really were completed, and
    /// the worker should see that rather than redo the lot. A user who wants a genuinely
    /// clean run uses "Run Again" (a brand-new task) or a template instance.
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
            validation.consecutiveValidationsWithoutNewApprovals = 0
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

    /// Returns the oldest actionable task assigned to the given agent.
    ///
    /// Tasks are sorted by `createdAt` ascending so the result is deterministic
    /// regardless of dictionary iteration order.
    public func taskForAgent(agentID: UUID) -> AgentTask? {
        let actionableStatuses: Set<AgentTask.Status> = [.pending, .running, .paused, .awaitingReview, .awaitingHelp, .interrupted]
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
    /// Returns a human-readable refusal, or nil on success — the caller used to invent its own
    /// reason from a bare `false`, which could only ever name one of the ways this can fail.
    @discardableResult
    public func updateDescription(id: UUID, description: String) -> String? {
        guard var task = tasks[id] else { return "Task not found." }
        guard task.status.isDescriptionEditable else {
            return "Task \"\(task.title)\" can't be edited while it is \(task.status.rawValue)."
        }
        // Skip the no-op edit so an "edited" badge doesn't appear from a Save click that
        // didn't actually change anything.
        guard task.description != description else { return nil }
        if task.isTemplate,
           let problem = TemplateInputValidation.placeholderProblem(
               in: description,
               field: "description",
               definedNames: Set(task.templateInputDefinitions.map(\.name))
           ) {
            return problem
        }
        task.description = description
        let now = Date()
        task.updatedAt = now
        task.lastEditedAt = now
        tasks[id] = task
        onChange?()
        return nil
    }

    /// Appends a clearly-labeled amendment to a task's description, optionally adding
    /// attachments to the task's `descriptionAttachments`. Used by Smith to relay user
    /// clarifications so that Security Agent (which reads the live description on every approval)
    /// sees the updated context. This only mutates the stored task — delivering the
    /// amendment to a running Brown is `AmendTaskTool`'s responsibility, since Brown's
    /// briefing is a one-time spawn snapshot. Attachments appended here are also
    /// re-injected into Brown's briefing on any future respawn.
    /// Returns a human-readable refusal, or nil on success. On a TEMPLATE the AMENDMENT is checked
    /// for placeholders naming no defined input: this writes text that gets substituted at
    /// instantiation, so it carries the same authoring check as `updateDescription` and
    /// `updateDefinition` — and unlike those, a typo here welds into EVERY future clone. Only the
    /// amendment is checked, never the description it lands on; re-sweeping the existing text would
    /// leave a template already carrying an orphan placeholder from an earlier input rename
    /// permanently un-amendable, the deadlock documented in `setTemplateInputDefinitions`.
    ///
    /// Deliberately NOT `@discardableResult` — a silently dropped refusal is the whole defect.
    public func amendDescription(id: UUID, amendment: String, attachments: [Attachment] = []) -> String? {
        guard var task = tasks[id] else { return "Task not found: \(id.uuidString)" }
        // Checked ABOVE the dedup: below it, re-sending an already-applied bad amendment would fall
        // into the no-op branch and report success for text the system rejected the first time.
        if task.isTemplate,
           let problem = TemplateInputValidation.placeholderProblem(
               in: amendment,
               field: "description amendment",
               definedNames: Set(task.templateInputDefinitions.map(\.name))
           ) {
            return problem
        }
        // An amendment to an INSTANCE substitutes the run's supplied input values, so
        // "also sign {{app_name}}" reads like the rest of the rendered instance instead of
        // reaching the worker as a literal placeholder (2026-07-28, user decision; before this,
        // instance amendments were the one authored-text path substitution never touched).
        // `definedNames` is the VALUE key set because instances don't carry input definitions —
        // a name with no supplied value (an omitted optional, or a typo) stays literal, which
        // for an after-the-fact amendment is the visible outcome, not a silent empty gap.
        var amendment = amendment
        if !task.isTemplate, !task.templateInputValues.isEmpty {
            amendment = TemplateStringRenderer.renderSubstitutingDefinedPlaceholders(
                amendment,
                values: task.templateInputValues,
                definedNames: Set(task.templateInputValues.keys),
                layout: .preserved
            )
        }
        // Dedup: don't stack an [Amendment] identical to the one already at the end of the
        // description. `run_task` amends BEFORE it tries to spawn/scope, so a failed start
        // (e.g. a tool-scoping failure) leaves the amendment applied; retrying with the same
        // instructions would otherwise append the same block over and over. Compared AFTER
        // substitution, because the substituted text is what the previous send appended.
        if !task.description.hasSuffix("[Amendment]: \(amendment)") {
            task.description += "\n\n[Amendment]: \(amendment)"
        }
        if !attachments.isEmpty {
            task.descriptionAttachments.append(contentsOf: attachments)
        }
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
        return nil
    }

    /// Records a help-request escalation from Brown and parks the task in `.awaitingHelp`, its own
    /// state (Brown stays alive, blocked, holding its slot). `helpRequest` marks it as a blocker
    /// (not a result); Smith answers via `provide_help`. Deliberately does NOT touch `result` —
    /// there is no completed work to deliver, which is exactly why this is NOT `.awaitingReview`
    /// (that state's invariant requires a result).
    // MARK: - Acceptance criteria (requester-owned)

    /// Replaces the task's acceptance criteria. Any criterion whose validation prompt,
    /// input enumerator, waivable flag, or legacy validator selection CHANGED — and any
    /// new criterion — loses its sticky verdict (its
    /// records stay in the audit ledger; only the "settled" reading resets, because the
    /// contract it was judged against no longer exists). Unchanged criteria keep their
    /// verdicts.
    ///
    /// Gated on status AND evidence, HERE rather than at the tool layer: a tool reads the task and
    /// mutates later, so its check is TOCTOU. Returns a human-readable refusal, or nil on success.
    @discardableResult
    public func setAcceptanceCriteria(id: UUID, criteria: [AcceptanceCriterion]) -> String? {
        guard var task = tasks[id] else { return "Task not found." }
        guard task.status.isValidationContractEditable else {
            return "Task \"\(task.title)\" is \(task.status.rawValue) — its acceptance criteria can't be edited while a worker or validator is active."
        }
        guard task.canReplaceAcceptanceContract(with: criteria) else {
            let dropped = task.acceptanceCriteria.filter { existing in !criteria.contains { $0.id == existing.id } }
            return """
                Task "\(task.title)" has already been validated, so its contract can't be replaced wholesale — \
                this list drops \(dropped.count) criterion(s) that carry a verdict or rejection history \
                (\(dropped.map { "\"\($0.name)\"" }.joined(separator: ", "))). \
                Use `actions` with `update` (which keeps a criterion's id, and its verdict when the contract text \
                is unchanged) and `delete` (which says so plainly) instead.
                """
        }
        if task.isTemplate {
            let definedNames = Set(task.templateInputDefinitions.map(\.name))
            for criterion in criteria {
                if let problem = TemplateInputValidation.placeholderProblem(inCriterion: criterion, definedNames: definedNames) {
                    return problem
                }
            }
        }
        writeAcceptanceContract(criteria, to: &task)
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
        return nil
    }

    /// Applies a batch of per-criterion edits ATOMICALLY: every action is validated and applied to a
    /// working copy, and nothing is written unless all of them succeed. A half-applied contract edit
    /// is the specific failure this shape exists to prevent — the contract is what the work is judged
    /// against, so "three of your four edits landed" is not a state anyone can reason about.
    ///
    /// Returns a human-readable error, or nil on success.
    @discardableResult
    public func applyCriterionActions(taskID: UUID, actions: [CriterionAction]) -> String? {
        guard var task = tasks[taskID] else { return "Task not found." }
        guard task.status.isValidationContractEditable else {
            return "Task \"\(task.title)\" is \(task.status.rawValue) — its acceptance criteria can't be edited while a worker or validator is active."
        }
        guard !actions.isEmpty else { return "No criterion actions were given." }
        var criteria = task.acceptanceCriteria
        let templateInputNames = task.isTemplate ? Set(task.templateInputDefinitions.map(\.name)) : []
        for action in actions {
            switch action {
            case .add(let name, let validationPrompt, let inputEnumeratorPrompt, let waivable, let origin):
                let criterion = AcceptanceCriterion(
                    name: name,
                    validationPrompt: validationPrompt,
                    inputEnumeratorPrompt: inputEnumeratorPrompt,
                    waivable: waivable,
                    origin: origin
                )
                if let problem = TemplateInputValidation.placeholderProblem(inCriterion: criterion, definedNames: templateInputNames) {
                    return problem
                }
                criteria.append(criterion)
            case .update(let criterionID, let name, let validationPrompt, let inputEnumeratorPrompt, let waivable):
                guard let index = criteria.firstIndex(where: { $0.id == criterionID }) else {
                    return "No acceptance criterion with id \(criterionID.uuidString)."
                }
                // id and origin are deliberately untouched: preserving identity across an edit is
                // the whole reason this verb exists.
                var edited = criteria[index]
                edited.name = name
                edited.validationPrompt = validationPrompt
                edited.inputEnumeratorPrompt = inputEnumeratorPrompt
                edited.waivable = waivable
                if let problem = TemplateInputValidation.placeholderProblem(inCriterion: edited, definedNames: templateInputNames) {
                    return problem
                }
                criteria[index] = edited
            case .delete(let criterionID):
                guard let index = criteria.firstIndex(where: { $0.id == criterionID }) else {
                    return "No acceptance criterion with id \(criterionID.uuidString)."
                }
                criteria.remove(at: index)
            }
        }
        // Names must stay distinct: the replace-all path matches criteria BY NAME to preserve
        // identity, so a duplicate would silently collapse two criteria into one there.
        guard Set(criteria.map(\.name)).count == criteria.count else {
            return "Duplicate criterion names — each display name must be distinct."
        }
        writeAcceptanceContract(criteria, to: &task)
        task.updatedAt = Date()
        tasks[taskID] = task
        onChange?()
        return nil
    }

    /// The SINGLE writer of a task's acceptance contract. Both authoring paths — a wholesale replace
    /// and a batch of per-criterion actions — land here, so verdict retirement and contract
    /// versioning cannot drift between them. Does not stamp `updatedAt` or notify; the caller owns
    /// the write-back.
    private func writeAcceptanceContract(_ criteria: [AcceptanceCriterion], to task: inout AgentTask) {
        let previousByID = Dictionary(task.acceptanceCriteria.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var changedIDs: Set<UUID> = []
        for criterion in criteria {
            if let previous = previousByID[criterion.id] {
                if !criterion.statesSameContract(as: previous) {
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
            //
            // `criterionRejections` is deliberately NOT pruned alongside them. It is the record of
            // what a criterion was rejected for BEFORE this edit, which is precisely what makes an
            // edit that follows a failure auditable — pruning it by the same rule would erase the
            // evidence with the action most likely to warrant it.
            validation.verdictRecords.removeAll {
                changedIDs.contains($0.criterionID) || !currentIDs.contains($0.criterionID)
            }
            // An edited contract gets a fresh convergence budget: rejections under the
            // OLD criteria must not count toward failing the task under the new ones
            // (agy review finding). Unchanged lists keep their counters — including the
            // version, so a no-op save can't invalidate a round that is judging correctly.
            if contractChanged {
                validation.round = 0
                validation.consecutiveValidationsWithoutNewApprovals = 0
                validation.bumpContractVersion()
            }
            task.validation = validation
        }
    }

    // MARK: - Steps (worker-owned, tombstone semantics)

    /// Replaces the task's step list wholesale — used by Smith's initial seeding at
    /// creation. Worker mutations go through `applyStepAction`.
    ///
    /// Callers editing an EXISTING plan must pass the tombstones back through, not drop
    /// them: this writes exactly what it is given, so an "active steps only" array silently
    /// erases the append-only record validators are promised.
    ///
    /// Returns a human-readable refusal, or nil on success.
    @discardableResult
    public func setSteps(id: UUID, steps: [TaskStep]) -> String? {
        guard var task = tasks[id] else { return "Task not found." }
        if task.isTemplate {
            let definedNames = Set(task.templateInputDefinitions.map(\.name))
            for (position, step) in steps.filter(\.isActive).enumerated() {
                if let problem = TemplateInputValidation.placeholderProblem(
                    inStep: step.text,
                    atPosition: position + 1,
                    definedNames: definedNames
                ) {
                    return problem
                }
            }
        }
        task.steps = steps
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
        return nil
    }

    /// Returns the active steps to unstarted for a fresh attempt: status back to `.pending`,
    /// skip note cleared. Tombstones are left tombstoned — a removed step was judged
    /// unnecessary, and reviving it re-adds work the plan already dropped.
    private func resetActiveStepsForFreshAttempt(_ task: inout AgentTask) {
        for index in task.steps.indices where task.steps[index].isActive {
            task.steps[index].status = .pending
            task.steps[index].note = nil
        }
    }

    /// One mutation of the step list (from Brown on its own task, or Smith on an inactive
    /// task's plan). Removal is a TOMBSTONE (status `.removed`, note required) and `.delete`
    /// is its ONLY producer — the underlying record is append-only so the validator always
    /// sees what was skipped or removed and why. Returns a human-readable error, or nil on
    /// success.
    ///
    /// Each action is a POINT MUTATION — it writes only the field it is about.
    ///
    /// This used to copy the whole task out (`guard var task = tasks[taskID]`), mutate the copy,
    /// and write the entire record back. That is safe only for as long as the function contains no
    /// suspension point, and nothing enforces that invariant: adding a single `await` anywhere
    /// between the read and the write-back — to persist, to notify, to look one thing up — would
    /// silently turn concurrent step edits into lost updates, each caller clobbering the others'
    /// fields from its own stale copy. Four steps being marked complete in parallel is an ordinary
    /// thing for this tool to be asked to do, so the window is not hypothetical.
    ///
    /// `task` below is therefore a read-only snapshot used to VALIDATE and to compute new
    /// orderings; every write goes through `tasks[taskID]?` directly and touches only its own
    /// field. There is no whole-record write-back left to go stale.
    @discardableResult
    public func applyStepAction(taskID: UUID, action: TaskStepAction) -> String? {
        guard let task = tasks[taskID] else { return "Task not found." }
        // Only the two actions that author TEXT can introduce a placeholder; the rest move,
        // status, or tombstone steps whose text was checked when it was written.
        let templateInputNames = task.isTemplate ? Set(task.templateInputDefinitions.map(\.name)) : []
        switch action {
        case .add(let text, let origin):
            if let problem = TemplateInputValidation.placeholderProblem(
                inStep: text,
                atPosition: task.steps.filter(\.isActive).count + 1,
                definedNames: templateInputNames
            ) {
                return problem
            }
            tasks[taskID]?.steps.append(TaskStep(text: text, origin: origin))
        case .update(let stepID, let newText):
            guard let index = task.steps.firstIndex(where: { $0.id == stepID }) else { return "No step with id \(stepID)." }
            guard task.steps[index].status != .removed else { return "Step \(stepID) was removed and cannot be edited." }
            // Position among the ACTIVE steps, which is the numbering everything else reports.
            // Total, not defaulted: the guard above already established this step is active.
            if let problem = TemplateInputValidation.placeholderProblem(
                inStep: newText,
                atPosition: task.steps[..<index].filter(\.isActive).count + 1,
                definedNames: templateInputNames
            ) {
                return problem
            }
            tasks[taskID]?.steps[index].text = newText
        case .setStatus(let stepID, let status, let note):
            // `delete` is the single source of tombstoning. Letting `setStatus` write `.removed`
            // too meant two code paths for one irreversible mutation, and advertised removal as
            // just another interchangeable status when it is in fact terminal.
            guard status != .removed else {
                return "Use the `delete` action to remove a step. `set_status` covers only the reversible states: pending, in_progress, completed, skipped."
            }
            guard let index = task.steps.firstIndex(where: { $0.id == stepID }) else { return "No step with id \(stepID)." }
            guard task.steps[index].status != .removed else { return "Step \(stepID) was removed and cannot be changed." }
            if status == .skipped && (note ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                return "Skipping a step requires a note explaining why."
            }
            tasks[taskID]?.steps[index].status = status
            if let note { tasks[taskID]?.steps[index].note = note }
        case .delete(let stepID, let note):
            guard let index = task.steps.firstIndex(where: { $0.id == stepID }) else { return "No step with id \(stepID)." }
            guard task.steps[index].status != .removed else { return "Step \(stepID) was already removed." }
            guard !note.trimmingCharacters(in: .whitespaces).isEmpty else { return "Deleting a step requires a note explaining why." }
            tasks[taskID]?.steps[index].status = .removed
            tasks[taskID]?.steps[index].note = note
        case .purge(let stepID):
            // Enforced here as well as at the tool layer: this is the one step mutation that
            // leaves no trace, so the guard belongs at the point of mutation, not only at the
            // point of authorization.
            guard task.isStepPlanPurgeable else {
                return "Task \"\(task.title)\" has already been run or validated — its step record can't be hard-deleted. Use `delete` to tombstone the step instead."
            }
            guard let index = task.steps.firstIndex(where: { $0.id == stepID }) else { return "No step with id \(stepID)." }
            tasks[taskID]?.steps.remove(at: index)
        case .move(let stepID, let destination):
            var active = task.steps.filter(\.isActive)
            guard let from = active.firstIndex(where: { $0.id == stepID }) else {
                guard task.steps.contains(where: { $0.id == stepID }) else { return "No step with id \(stepID)." }
                return "Step \(stepID) was removed and cannot be moved."
            }
            // Resolve the destination against the list WITHOUT the moved step, so "before X" and
            // "after X" mean the same thing whether the step is travelling up or down.
            let moved = active.remove(at: from)
            let insertionIndex: Int
            switch destination {
            case .before(let anchorID):
                guard let anchor = active.firstIndex(where: { $0.id == anchorID }) else {
                    return anchorID == stepID
                        ? "`before_step_id` must name a different step than `step_id`."
                        : "No active step with id \(anchorID) to move before. Call `list` to see the current ids."
                }
                insertionIndex = anchor
            case .after(let anchorID):
                guard let anchor = active.firstIndex(where: { $0.id == anchorID }) else {
                    return anchorID == stepID
                        ? "`after_step_id` must name a different step than `step_id`."
                        : "No active step with id \(anchorID) to move after. Call `list` to see the current ids."
                }
                insertionIndex = anchor + 1
            case .position(let oneBased):
                // 1-based to match the numbering the worker sees; the upper bound is the count
                // INCLUDING the moved step, so "move to position <count>" means "make it last".
                guard oneBased >= 1 && oneBased <= active.count + 1 else {
                    return "`position` must be between 1 and \(active.count + 1) (1-based, among the \(active.count + 1) active step(s))."
                }
                insertionIndex = oneBased - 1
            }
            active.insert(moved, at: insertionIndex)
            tasks[taskID]?.steps = active + task.steps.filter { !$0.isActive }
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
            tasks[taskID]?.steps = reordered + removed
        }
        tasks[taskID]?.updatedAt = Date()
        onChange?()
        return nil
    }

    // MARK: - Queued worker messages

    /// Queues a message for a task's worker to receive when it next starts.
    ///
    /// For messages Smith sends to a task whose worker isn't alive yet — most often immediately
    /// after `create_task` or `run_task`, which both return before the worker is spawned. Point
    /// mutation: appends to this task's queue and touches nothing else.
    public func enqueueWorkerMessage(taskID: UUID, message: QueuedWorkerMessage) -> Bool {
        guard tasks[taskID] != nil else { return false }
        tasks[taskID]?.pendingWorkerMessages.append(message)
        tasks[taskID]?.updatedAt = Date()
        onChange?()
        return true
    }

    /// Returns this task's queued worker messages AND clears them, atomically.
    ///
    /// Read-and-clear is one operation on purpose: a separate read then write would let a message
    /// queued in between be dropped, which is the failure this queue exists to prevent. Called when
    /// a worker's briefing is composed, so each message is delivered once and does not resurface on
    /// a later restart.
    public func takePendingWorkerMessages(taskID: UUID) -> [QueuedWorkerMessage] {
        guard let queued = tasks[taskID]?.pendingWorkerMessages, !queued.isEmpty else { return [] }
        tasks[taskID]?.pendingWorkerMessages = []
        tasks[taskID]?.updatedAt = Date()
        onChange?()
        return queued
    }

    // MARK: - Validation ledger

    /// Begins the next validation round and returns the token identifying it — the round number AND
    /// the contract version it will judge, captured together so they cannot disagree. The caller
    /// hands this back to every mutation it makes for the rest of the round; each one refuses if the
    /// world moved while the round was awaiting an LLM.
    public func beginValidationRound(id: UUID) -> ValidationRoundToken? {
        guard var task = tasks[id] else { return nil }
        var validation = task.validation ?? TaskValidationState()
        validation.round += 1
        task.validation = validation
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
        return validation.currentRoundToken
    }

    /// Whether a round-scoped caller may still act on `task`. A nil token means the caller is making
    /// no round-scoped claim (a pause, a stop, a user resolution — none of them belong to a round),
    /// which is a different thing from a stale one.
    private func validationRoundIsCurrent(_ token: ValidationRoundToken?, on task: AgentTask) -> Bool {
        guard let token else { return true }
        return (task.validation ?? TaskValidationState()).isCurrentRound(token)
    }

    /// Resets the validation counters (round + consecutive-validations-without-new-approvals) for a
    /// fresh rework cycle — a user "send back to Brown"/re-validate, or `run_task`'s auto-reset of a
    /// failed task. Without this, a resubmission would instantly re-fail on a counter earned by the
    /// previous cycle. Sticky accepts, the verdict ledger, and the rejection history all survive —
    /// only the counters refresh. This is the deliberate escape hatch from an otherwise durable
    /// convergence budget.
    public func resetValidationRound(id: UUID) {
        guard var task = tasks[id], var validation = task.validation else { return }
        validation.round = 0
        validation.consecutiveValidationsWithoutNewApprovals = 0
        task.validation = validation
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
    }

    /// Records whether a rejection round newly APPROVED anything (reached ACCEPT or WAIVE on any
    /// criterion). Returns the updated count of consecutive validations without a new approval: 0
    /// after a round that approved something, incremented after one that didn't. The coordinator
    /// fails the task when this hits `maxConsecutiveValidationsWithoutNewApprovals`.
    ///
    /// `nil` when the task is gone (a Stop-then-Delete can land between the coordinator reading the
    /// task and this call), when it has no ledger, or when `judgedInRound` has been superseded — the
    /// caller abandons the round rather than acting on a fabricated number. Unlike
    /// `recordCriterionVerdicts`, one nil for all three is honest here: every one of them means
    /// "abandon", and none of them means "carry on". Returning `0` instead meant returning the value
    /// that also means "progress was made", and synthesizing a ledger meant a task with no validation
    /// history acquired one whose entire content was a stall count.
    public func updateValidationStall(id: UUID, progressed: Bool, judgedInRound token: ValidationRoundToken) -> Int? {
        guard var task = tasks[id], var validation = task.validation else { return nil }
        // Checked HERE, not from the caller's snapshot: an edit landing at any of the round's
        // suspension points grants the NEW contract a fresh convergence budget, and incrementing
        // this counter would spend a round of it on a contract we never judged.
        guard validation.isCurrentRound(token) else { return nil }
        let updated = progressed ? 0 : validation.validationsWithoutNewApprovals + 1
        validation.consecutiveValidationsWithoutNewApprovals = updated
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
    /// re-judged against the new contract next round.
    ///
    /// Returns `.recorded` with the records that landed, or `.superseded` when this run no longer
    /// owns the ledger — see `VerdictRecordingOutcome` for why those must not be the same answer.
    /// Deliberately NOT `@discardableResult`: ignoring the outcome is precisely the defect this
    /// return type exists to make impossible.
    public func recordCriterionVerdicts(id: UUID, records: [CriterionVerdictRecord], judgedAgainst: [AcceptanceCriterion], judgedInRound token: ValidationRoundToken) -> VerdictRecordingOutcome {
        // A vanished task is not "nothing qualified" either — a Stop-then-Delete can land while the
        // caller awaits an LLM, and there is no ledger left to reason about.
        guard var task = tasks[id] else { return .superseded }
        guard !records.isEmpty else { return .recorded([]) }
        // Round guard, checked HERE for the same reason the contract filter below is: this actor
        // owns the truth, so the check is atomic against whatever moved while the caller was awaiting
        // an LLM. A validation run that was cancelled and superseded (performStopAll clears the
        // reentrancy guard without awaiting in-flight runs, and a restart re-enqueues .validating
        // tasks) otherwise appends its stale verdict AFTER the live run's fresh one — and both
        // readers select by array position, so the stale record wins. Dropped records leave their
        // criteria unjudged and are re-judged next round; no evidence is lost.
        guard validationRoundIsCurrent(token, on: task) else { return .superseded }
        let judgedByID = Dictionary(judgedAgainst.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let currentByID = Dictionary(task.acceptanceCriteria.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let fresh = records.filter { record in
            guard let judged = judgedByID[record.criterionID], let current = currentByID[record.criterionID] else { return false }
            return current.statesSameContract(as: judged)
        }
        guard !fresh.isEmpty else { return .recorded([]) }
        var validation = task.validation ?? TaskValidationState()
        validation.verdictRecords.append(contentsOf: fresh)
        // Every rejection also lands in the append-only history, captured from the criterion AS
        // JUDGED (`judgedByID`) rather than its current state — the point of the record is what the
        // validator was actually asked. Written here because this is the sole producer of verdict
        // records, so the history cannot fall out of step with the ledger.
        let rejections = fresh.compactMap { record -> CriterionRejection? in
            guard case .rejected(let reason) = record.verdict,
                  let judged = judgedByID[record.criterionID] else { return nil }
            return CriterionRejection(judged: judged, rejectionText: reason, recordedAt: record.recordedAt)
        }
        if !rejections.isEmpty {
            validation.criterionRejections = validation.rejectionHistory + rejections
        }
        task.validation = validation
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
        return .recorded(fresh)
    }

    /// Materializes the implicit default criterion for a criterion-less task at first
    /// validation, making the contract visible to the user like any other criterion.
    public func materializeImplicitCriterion(id: UUID, criterion: AcceptanceCriterion) {
        guard var task = tasks[id], task.acceptanceCriteria.isEmpty else { return }
        task.acceptanceCriteria = [criterion]
        // Materializing IS a criteria mutation, so it versions the contract like any other. It runs
        // before the round begins, so the round's token already carries the bumped version.
        if var validation = task.validation {
            validation.bumpContractVersion()
            task.validation = validation
        }
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
    }

    public func requestHelp(id: UUID, request: String) {
        guard var task = tasks[id] else { return }
        task.helpRequest = request
        task.status = .awaitingHelp
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

    /// Parks a task that cannot be validated for a CONFIGURATION reason. CAS-guarded on
    /// `.validating` like every other validation exit, so a pause/stop that landed after the
    /// coordinator's snapshot is never overwritten. Returns true if the task was parked.
    @discardableResult
    public func blockValidation(id: UUID, reason: String) -> Bool {
        guard var task = tasks[id], task.status == .validating else { return false }
        task.validationBlockedReason = reason
        task.status = .awaitingReview
        task.updatedAt = Date()
        tasks[id] = task
        onChange?()
        return true
    }

    /// Releases every task parked by `blockValidation` back to `.validating`. Called when the
    /// missing configuration appears (a validator model is assigned); the caller re-enqueues
    /// the returned ids. Tasks the user has since paused, stopped, or failed are left alone —
    /// only ones still sitting in the parked state are released.
    @discardableResult
    public func releaseValidationBlockedTasks() -> [UUID] {
        var released: [UUID] = []
        for (id, task) in tasks where task.validationBlockedReason != nil && task.status == .awaitingReview {
            var updated = task
            updated.validationBlockedReason = nil
            updated.status = .validating
            updated.updatedAt = Date()
            tasks[id] = updated
            released.append(id)
        }
        if !released.isEmpty { onChange?() }
        return released
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
        // Archive / soft-delete must cancel the task's scheduled wakes: a disposition move is not a
        // terminal STATUS change, so `onTaskTerminated` does not fire here.
        onTaskMovedToInactive?(task.id)
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
    ///
    /// `ifValidationRoundIs` adds the same atomicity for the OTHER thing that moves under a
    /// validation round: the acceptance contract. Status alone is not enough — a criteria edit
    /// leaves the task `.validating`, so a round that has been superseded still passes the status
    /// gate and completes, escalates, or fails the task on a verdict about a contract that no longer
    /// exists. Pass the round's token from every transition a validation round makes; leave it nil
    /// when the caller does not belong to a round (pause, stop, a user resolution).
    @discardableResult
    public func updateStatus(
        id: UUID,
        to newStatus: AgentTask.Status,
        ifCurrentlyIn allowed: Set<AgentTask.Status>,
        ifValidationRoundIs token: ValidationRoundToken? = nil
    ) -> Bool {
        guard let task = tasks[id], allowed.contains(task.status) else { return false }
        guard validationRoundIsCurrent(token, on: task) else { return false }
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
            // Migration: help requests used to park in `.awaitingReview` alongside validator
            // escalations. They now have their own `.awaitingHelp` state (no result requirement).
            // A persisted `.awaitingReview` task carrying a `helpRequest` is an old help park —
            // move it to the correct state so it isn't treated as a reviewable submission.
            if task.status == .awaitingReview && task.helpRequest != nil {
                task.status = .awaitingHelp
            }
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
