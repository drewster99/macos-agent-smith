import Foundation

/// A unit of work managed by the orchestration system.
/// A message for a task's worker that was queued because no worker was alive to receive it.
///
/// Carries its own id so delivery can be made idempotent, and the time it was queued so a worker
/// reading it in a briefing can tell how stale the instruction is.
public struct QueuedWorkerMessage: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var text: String
    public var queuedAt: Date
    public var attachments: [Attachment]

    public init(id: UUID = UUID(), text: String, queuedAt: Date = Date(), attachments: [Attachment] = []) {
        self.id = id
        self.text = text
        self.queuedAt = queuedAt
        self.attachments = attachments
    }
}

public struct AgentTask: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var title: String
    public var description: String
    public var status: Status
    public var disposition: TaskDisposition
    public var assigneeIDs: [UUID]
    public var result: String?
    public var commentary: String?
    public var createdAt: Date
    public var updatedAt: Date
    /// Set when the task first transitions to `.running`.
    public var startedAt: Date?
    /// Set when the task transitions to `.completed` or `.failed`.
    public var completedAt: Date?
    /// Progress updates from Brown, persisted so a restarted Brown has context.
    public var updates: [TaskUpdate]
    /// Number of times this task has been acknowledged (a first-turn runtime action). Starts at 0;
    /// incremented each time Brown acknowledges. A value > 1 means Brown is picking up
    /// after a prior run (rejection-revision or respawn), not a fresh assignment.
    /// Persisted so the signal survives app restart and new-Brown spawns.
    public var acknowledgmentCount: Int
    /// Compressed summary of Brown's last working state, saved on termination for resumability.
    public var lastBrownContext: String?
    /// LLM-generated summary of the task (populated after completion/failure).
    public var summary: String?
    /// Relevant memories retrieved at task creation AND at each template instantiation, for the
    /// worker's context (a repeatedly-run template thus picks up newly-accumulated memories).
    public var relevantMemories: [RelevantMemory]?
    /// Relevant prior task summaries retrieved at creation and at each template instantiation.
    public var relevantPriorTasks: [RelevantPriorTask]?
    /// When set, the task is held in `.scheduled` status (or `.pending` after the time
    /// arrives) and will not be auto-run by the queue until this date passes. The runtime
    /// schedules a matching wake bound to `id` so Smith is notified at fire time.
    public var scheduledRunAt: Date?
    /// Timestamp of the most recent user edit to `description` (or other user-mutable
    /// fields, when added). `nil` for tasks that have never been edited. The UI surfaces
    /// this as an "edited" indicator. Editing does not change `status` — a completed
    /// task remains `.completed` after a description edit.
    public var lastEditedAt: Date?
    /// Attachments captured at task creation. Sourced from the user's incoming message
    /// when Smith calls `create_task` with an `attachment_ids` arg, plus anything Smith
    /// later attaches via amendment. Brown sees these in his initial briefing — image
    /// attachments are passed to the LLM as image content, others as text-only refs.
    /// `Attachment` itself excludes file bytes from Codable; bytes live in the per-session
    /// attachments directory.
    public var descriptionAttachments: [Attachment]
    /// Attachments produced or referenced as part of the final task result. Set by
    /// `task_complete`. Surfaced to Smith with the awaitingReview banner.
    public var resultAttachments: [Attachment]
    /// Optional STRUCTURED result: an ordered list of tagged text/attachment/group items
    /// (`ResultItem`). Additive alongside `result`/`resultAttachments`, which stay canonical —
    /// empty for tasks that never produced structured items. Lets a validator route evidence by
    /// criterion (the item `refs`) and pull attachment items into its context.
    public var resultItems: [ResultItem]

    /// The acceptance contract: criteria judged by evaluators when the task enters
    /// `.validating`. Requester-owned (user/Smith/system); the worker never edits these.
    /// Empty means the implicit default criterion is materialized at first
    /// validation.
    public var acceptanceCriteria: [AcceptanceCriterion]
    /// The worker's plan. Worker-owned, tombstone semantics (see `TaskStep`); Smith may
    /// seed initial steps at creation.
    public var steps: [TaskStep]
    /// The validation ledger: rounds, append-only verdict audit, pinned definitions.
    /// Nil until the first validation begins.
    public var validation: TaskValidationState?

    /// When true, this task is a TEMPLATE: starting it never runs the task itself —
    /// instead a fresh instance is CLONED (title/description/steps/criteria copied,
    /// run-state blanked) and that clone runs. The template stays put and can be
    /// started again for another fresh instance. Recurring tasks default to templates.
    /// Any task can be toggled into or out of a template.
    public var isTemplate: Bool
    /// For a cloned INSTANCE, the ID of the template it was cloned from. Nil for
    /// ordinary tasks and for templates themselves. Lets future UI group instances
    /// under their template; for now it's just a recorded lineage.
    public var parentTaskID: UUID?
    /// The session this task ORIGINATED in (was created / instantiated in). IMMUTABLE once set — a
    /// task belongs to exactly one session's transcript for its whole life, which is what makes "a
    /// task's messages live in one session's log" hold (unarchiving keeps it; re-running in a different
    /// session clones a fresh task rather than re-homing this one). Stamped on creation by `TaskStore`
    /// and back-filled on load for legacy per-session tasks. `nil` only for archived/deleted tasks that
    /// predate this field — their origin session is unrecoverable, so their transcript reads unavailable.
    public var sessionID: UUID?
    /// Inputs this template requires or accepts before a run can be instantiated. Only
    /// template tasks may define these directly. Template instances retain a snapshot so
    /// their historical context stays stable if the template is edited later.
    public var templateInputDefinitions: [TemplateInputDefinition]
    /// Optional title pattern used when this template creates an instance. Supports simple
    /// `{{input_name}}` placeholders resolved from the instance's template input values.
    /// Nil means instances keep the template's own title.
    public var templateInstanceTitleTemplate: String?
    /// Resolved input values captured when a template instance is created. Only cloned
    /// template instances should carry values; ordinary tasks and templates keep this empty.
    public var templateInputValues: [String: String]

    /// The most recent set of tool names the security agent approved for the worker on this
    /// task (per-task tool scoping). A **record**, not the gate — the live registry is the
    /// source of truth for enforcement. `nil` for legacy/unscoped tasks. Replaced wholesale
    /// on each scoping; replacements are also annotated in `updates` for history.
    public var approvedTools: [String]?

    /// Per-task user overrides of tool availability, keyed by tool name. `true` = the user forced the
    /// tool ON for this task; `false` = forced OFF. Takes precedence over both the automatic scoping
    /// verdict and the global `ToolPolicy`, and is re-applied after every re-evaluation so a re-scope
    /// never clobbers the user's choice. `nil`/absent = no per-task overrides.
    public var userToolOverrides: [String: Bool]?

    /// Non-nil when Brown has escalated a blocker via `request_help` and is waiting for Smith.
    /// The task sits in its own `.awaitingHelp` state (Brown stays alive, holding its slot); Smith
    /// answers via `provide_help`, which clears this and returns the task to running. Holds the
    /// formatted blocker + what's needed, for Smith's context and the UI.
    public var helpRequest: String?

    /// Non-nil when validation could not run for a CONFIGURATION reason (today: no model is
    /// assigned to `AgentRole.validator`). The task parks in `.awaitingReview`, but this one is
    /// nobody's to resolve — it isn't offered the user's escalation actions, because a human-free
    /// "accept" here would be exactly the unjudged pass the validation system exists to prevent.
    /// Cleared automatically when a validator model is assigned, which returns the task to
    /// `.validating` and re-enqueues it. (Distinguishes a config park from a validator-error park —
    /// see `occupiesWorkerSlot` and the escalation row actions.)
    public var validationBlockedReason: String?

    /// Messages addressed to this task's worker that arrived while no worker was alive.
    ///
    /// Smith addresses a worker by task (`notify_brown`), but the worker's existence is a race
    /// Smith cannot observe: creating or starting a task returns before the worker is spawned, so
    /// an immediate follow-up message had nobody to deliver to and simply failed. Asking Smith to
    /// notice that race and pick a different tool is asking it to reason about scheduling it has
    /// no visibility into. Instead the message is queued here and handed to the worker in its
    /// briefing when it starts — same shape as an amendment, which is durable for the same reason.
    ///
    /// Drained by `takePendingWorkerMessages` when the briefing is composed, so a message is
    /// delivered once and does not resurface on a later restart.
    public var pendingWorkerMessages: [QueuedWorkerMessage]

    /// Whether this task currently holds one of the `maxConcurrentWorkers` slots — i.e. has a LIVE
    /// worker. `starting`/`running`/`validating`/`awaitingHelp` always do (Brown is alive, working,
    /// or blocked on a help answer). `.awaitingReview` is the split case: a validator-error park has
    /// had its worker torn down (does NOT occupy), but a missing-validator park (`validationBlockedReason`
    /// set) keeps its worker alive waiting on config (DOES occupy). This is the tool-side proxy for the
    /// runtime's authoritative live-Brown count — keep the two in agreement.
    public var occupiesWorkerSlot: Bool {
        switch status {
        case .starting, .running, .validating, .awaitingHelp:
            return true
        case .awaitingReview:
            return validationBlockedReason != nil
        case .pending, .paused, .interrupted, .scheduled, .completed, .failed:
            return false
        }
    }

    /// Whether a step may be HARD-deleted from this task's plan (`manage_steps` `purge`),
    /// as opposed to tombstoned. True only while the plan is still a draft nobody has worked
    /// or judged against: purging elsewhere would destroy real history rather than tidy an
    /// unrun plan.
    ///
    /// Templates are always purgeable — a template is a launcher that never runs itself, so
    /// its steps are pure authoring and its tombstones are clutter that every clone has to
    /// filter out. (`setTemplate` normalizes a promoted task via `normalizeTemplateLauncher`,
    /// clearing `startedAt` and `validation`, so this arm is belt-and-braces rather than a
    /// carve-out.) Every other task must have neither started nor been validated —
    /// `validation == nil` alone is not enough, because a task with no acceptance criteria
    /// can run to completion and still never open a validation ledger.
    public var isStepPlanPurgeable: Bool {
        isTemplate || (startedAt == nil && validation == nil)
    }

    /// Whether this task has ever entered validation — the durable marker that its acceptance
    /// contract has been judged, or was about to be.
    ///
    /// It is the LEDGER'S EXISTENCE, not its contents, because every finer-grained signal is erased
    /// by the very action this guards. "A verdict exists" fails because a round increments BEFORE
    /// anything is judged, so the ledger is legitimately empty mid-validation. "A round has begun"
    /// fails because a contract edit resets `round` to 0 — so two edits in a row would find the
    /// second one unguarded, which is precisely the sequence worth guarding. `validation` is only
    /// ever created (by `beginValidationRound`) and only ever cleared by converting the task into a
    /// template, which deliberately discards all run state.
    public var hasValidationEvidence: Bool { validation != nil }

    /// Whether `criteria` may replace this task's contract WHOLESALE.
    ///
    /// The harm a replace does is not "it changes things" — it is that a replacement list built by
    /// matching on NAME mints a fresh UUID whenever a name changes, and a new UUID is a new
    /// criterion whose predecessor's verdicts are silently retired. So the gate asks the precise
    /// question: does this replacement still contain every criterion currently on the task? A
    /// replace that RESTATES them all destroys no identity whatever else it edits — that is the
    /// task-detail editor, which edits rows in place and carries their ids through. A replace that
    /// DROPS one, once evidence exists, must instead say so through `delete`, where the intent is
    /// stated rather than inferred from a list that happens to be missing something.
    ///
    /// Deliberately NOT parity with `isStepPlanPurgeable`, which additionally requires
    /// `startedAt == nil`: a task that ran but was never validated has no acceptance evidence to
    /// protect, and re-authoring its contract wholesale is exactly what a first draft needs.
    public func canReplaceAcceptanceContract(with criteria: [AcceptanceCriterion]) -> Bool {
        guard hasValidationEvidence else { return true }
        let incoming = Set(criteria.map(\.id))
        return acceptanceCriteria.allSatisfy { incoming.contains($0.id) }
    }

    /// A single progress update recorded on a task.
    public struct TaskUpdate: Codable, Sendable, Equatable {
        public var date: Date
        public var message: String
        /// Attachments captured with this update. Image attachments are forwarded to
        /// Smith as image content; text refs are appended to the update body. Non-empty
        /// only when `task_update` was called with `attachment_ids` or `attachment_paths`.
        public var attachments: [Attachment]

        public init(date: Date = Date(), message: String, attachments: [Attachment] = []) {
            self.date = date
            self.message = message
            self.attachments = attachments
        }

        private enum CodingKeys: String, CodingKey {
            case date, message, attachments
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            date = try c.decode(Date.self, forKey: .date)
            message = try c.decode(String.self, forKey: .message)
            attachments = try c.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(date, forKey: .date)
            try c.encode(message, forKey: .message)
            if !attachments.isEmpty {
                try c.encode(attachments, forKey: .attachments)
            }
        }
    }

    public enum Status: String, Codable, Sendable, CaseIterable {
        case pending
        /// Transient: a start has been claimed for this task and its worker (Brown) is being
        /// spawned — the multi-second Security-Agent scoping call happens here. Holds a worker
        /// slot and shows a "Starting…" indicator so the UI isn't blank during the spawn. The
        /// atomic `.pending → .starting` transition (CAS) also fences the start: a duplicate start
        /// enqueued while the task was still `.pending` finds the CAS already lost and bails, so a
        /// live worker can never be orphaned or double-spawned. Exits to `.running` once Brown is
        /// live; demoted back to `.pending` at cold boot (a crash mid-spawn left no live worker).
        case starting
        case running
        case completed
        case failed
        case paused
        case awaitingReview
        /// Brown hit a blocker it can't resolve and raised `request_help`; the worker stays ALIVE
        /// (blocked, holding its slot) until Smith answers via `provide_help`, which returns it to
        /// `.running`. Distinct from `.awaitingReview` — a help request happens MID-work, carries no
        /// submitted result, and keeps its worker; `.awaitingReview` is a validator-park with the
        /// worker already torn down.
        case awaitingHelp
        /// The task was running when the app was interrupted (crash or force-quit).
        case interrupted
        /// The task is queued with a future `scheduledRunAt`. The auto-runner skips these,
        /// and `run_task` refuses to start them until the runtime promotes the task to
        /// `.pending` at fire time.
        case scheduled
        /// The submitted result is being judged against the task's acceptance criteria
        /// by evaluators. Entered from `task_complete`; exits to `.completed` (all
        /// criteria accepted/waived), back to `.running` (rejections → worker punch
        /// list, bounded rounds), or `.awaitingReview` (escalation).
        case validating

        /// Forward-compatibility fallback: a status rawValue this build doesn't know
        /// (written by a NEWER build — e.g. a future `validating` case) must not brick
        /// the decode of the entire task list. `.interrupted` is the safe bucket: it
        /// never auto-runs, is visibly "needs attention" in the UI, and `run_task`
        /// accepts it for an explicit user-driven resume.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: raw) ?? .interrupted
        }

        /// Human-readable name for display. Not `rawValue.capitalized`: Swift's `capitalized`
        /// lowercases the tail of each word, turning `awaitingReview` into "Awaitingreview".
        /// Every surface that shows a status to the user goes through this.
        public var displayName: String {
            switch self {
            case .pending: return "Pending"
            case .starting: return "Starting"
            case .running: return "Running"
            case .completed: return "Completed"
            case .failed: return "Failed"
            case .paused: return "Paused"
            case .awaitingReview: return "Awaiting Review"
            case .awaitingHelp: return "Awaiting Help"
            case .interrupted: return "Interrupted"
            case .scheduled: return "Scheduled"
            case .validating: return "Validating"
            }
        }

        /// Whether this status represents work that is actively running — prevents archiving or deletion.
        public var isInProgress: Bool {
            self == .starting || self == .running || self == .paused || self == .awaitingReview || self == .awaitingHelp || self == .validating
        }

        /// Whether this status is a terminal outcome — the task's `UsageRecord`s
        /// won't grow further. Used by the inspector cost-load path to decide
        /// when to refresh a task's cached cost (terminal tasks only need one
        /// final read; non-terminal tasks may still accrue records).
        public var isTerminal: Bool {
            self == .completed || self == .failed
        }

        /// Whether this status allows `run_task` to start execution. `.scheduled` is
        /// deliberately excluded — calling `run_task` on a scheduled task before its fire
        /// time should be an explicit override, not a silent advance.
        public var isRunnable: Bool {
            self == .pending || self == .paused || self == .interrupted
        }

        /// Whether the user can edit the task's description in this state. Includes the
        /// runnable states plus terminal states (`completed`, `failed`) and `scheduled`.
        /// Excludes `running` and `awaitingReview` — those are actively in-flight and
        /// editing the description while Brown or Smith is reading it would be confusing.
        /// Description edits never change the status; the "edited" affordance is surfaced
        /// via `AgentTask.lastEditedAt` instead.
        public var isDescriptionEditable: Bool {
            switch self {
            case .pending, .paused, .interrupted, .scheduled, .completed, .failed:
                return true
            case .starting, .running, .awaitingReview, .awaitingHelp, .validating:
                return false
            }
        }

        /// Whether the user can edit the task's acceptance criteria and step list in
        /// this state — any state where no worker or validator is actively consuming
        /// them. `awaitingReview` is included deliberately: it's a validator-park with no
        /// live worker, and fixing a wrong criterion is exactly how it gets resolved before
        /// re-validating. `awaitingHelp` is excluded: Brown is still alive there (blocked on a
        /// help request) and owns its step list.
        public var isValidationContractEditable: Bool {
            switch self {
            case .pending, .paused, .interrupted, .scheduled, .failed, .awaitingReview:
                return true
            case .starting, .running, .awaitingHelp, .validating, .completed:
                return false
            }
        }
    }

    public enum TaskDisposition: String, Codable, Sendable {
        /// Visible in the main task list.
        case active
        /// Moved to the archive bucket.
        case archived
        /// Soft-deleted; recoverable from the Recently Deleted bucket.
        case recentlyDeleted

        /// Forward-compatibility fallback: a disposition rawValue this build doesn't know (written
        /// by a NEWER build) must not brick the decode of the entire task list — the tasks file is
        /// one array, so one unknown value would fail every task. `.active` is the safe bucket: the
        /// task stays visible and recoverable rather than silently vanishing into a hidden bucket.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = TaskDisposition(rawValue: raw) ?? .active
        }
    }

    public init(
        id: UUID = UUID(),
        title: String,
        description: String,
        status: Status = .pending,
        disposition: TaskDisposition = .active,
        assigneeIDs: [UUID] = [],
        result: String? = nil,
        commentary: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        updates: [TaskUpdate] = [],
        acknowledgmentCount: Int = 0,
        lastBrownContext: String? = nil,
        summary: String? = nil,
        relevantMemories: [RelevantMemory]? = nil,
        relevantPriorTasks: [RelevantPriorTask]? = nil,
        scheduledRunAt: Date? = nil,
        lastEditedAt: Date? = nil,
        descriptionAttachments: [Attachment] = [],
        resultAttachments: [Attachment] = [],
        resultItems: [ResultItem] = [],
        approvedTools: [String]? = nil,
        userToolOverrides: [String: Bool]? = nil,
        helpRequest: String? = nil,
        pendingWorkerMessages: [QueuedWorkerMessage] = [],
        validationBlockedReason: String? = nil,
        acceptanceCriteria: [AcceptanceCriterion] = [],
        steps: [TaskStep] = [],
        validation: TaskValidationState? = nil,
        isTemplate: Bool = false,
        parentTaskID: UUID? = nil,
        sessionID: UUID? = nil,
        templateInputDefinitions: [TemplateInputDefinition] = [],
        templateInstanceTitleTemplate: String? = nil,
        templateInputValues: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.status = status
        self.disposition = disposition
        self.assigneeIDs = assigneeIDs
        self.result = result
        self.commentary = commentary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.updates = updates
        self.acknowledgmentCount = acknowledgmentCount
        self.lastBrownContext = lastBrownContext
        self.summary = summary
        self.relevantMemories = relevantMemories
        self.relevantPriorTasks = relevantPriorTasks
        self.scheduledRunAt = scheduledRunAt
        self.lastEditedAt = lastEditedAt
        self.descriptionAttachments = descriptionAttachments
        self.resultAttachments = resultAttachments
        self.resultItems = resultItems
        self.approvedTools = approvedTools
        self.userToolOverrides = userToolOverrides
        self.helpRequest = helpRequest
        self.pendingWorkerMessages = pendingWorkerMessages
        self.validationBlockedReason = validationBlockedReason
        self.acceptanceCriteria = acceptanceCriteria
        self.steps = steps
        self.validation = validation
        self.isTemplate = isTemplate
        self.parentTaskID = parentTaskID
        self.sessionID = sessionID
        self.templateInputDefinitions = templateInputDefinitions
        self.templateInstanceTitleTemplate = templateInstanceTitleTemplate
        self.templateInputValues = templateInputValues
    }

    // MARK: - Codable (backward-compatible with persisted data lacking `disposition`)

    private enum CodingKeys: String, CodingKey {
        case id, title, description, status, disposition, assigneeIDs, result, commentary, createdAt, updatedAt, startedAt, completedAt, updates, acknowledgmentCount, lastBrownContext, summary, relevantMemories, relevantPriorTasks, scheduledRunAt, lastEditedAt, descriptionAttachments, resultAttachments, resultItems, approvedTools, userToolOverrides, helpRequest, validationBlockedReason, acceptanceCriteria, steps, validation, isTemplate, parentTaskID, sessionID, templateInputDefinitions, templateInstanceTitleTemplate, templateInputValues, pendingWorkerMessages
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        description = try c.decode(String.self, forKey: .description)
        status = try c.decode(Status.self, forKey: .status)
        disposition = try c.decodeIfPresent(TaskDisposition.self, forKey: .disposition) ?? .active
        assigneeIDs = try c.decode([UUID].self, forKey: .assigneeIDs)
        result = try c.decodeIfPresent(String.self, forKey: .result)
        commentary = try c.decodeIfPresent(String.self, forKey: .commentary)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        updates = try c.decodeIfPresent([TaskUpdate].self, forKey: .updates) ?? []
        acknowledgmentCount = try c.decodeIfPresent(Int.self, forKey: .acknowledgmentCount) ?? 0
        lastBrownContext = try c.decodeIfPresent(String.self, forKey: .lastBrownContext)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        relevantMemories = try c.decodeIfPresent([RelevantMemory].self, forKey: .relevantMemories)
        relevantPriorTasks = try c.decodeIfPresent([RelevantPriorTask].self, forKey: .relevantPriorTasks)
        scheduledRunAt = try c.decodeIfPresent(Date.self, forKey: .scheduledRunAt)
        lastEditedAt = try c.decodeIfPresent(Date.self, forKey: .lastEditedAt)
        descriptionAttachments = try c.decodeIfPresent([Attachment].self, forKey: .descriptionAttachments) ?? []
        resultAttachments = try c.decodeIfPresent([Attachment].self, forKey: .resultAttachments) ?? []
        resultItems = try c.decodeIfPresent([ResultItem].self, forKey: .resultItems) ?? []
        approvedTools = try c.decodeIfPresent([String].self, forKey: .approvedTools)
        userToolOverrides = try c.decodeIfPresent([String: Bool].self, forKey: .userToolOverrides)
        helpRequest = try c.decodeIfPresent(String.self, forKey: .helpRequest)
        pendingWorkerMessages = try c.decodeIfPresent([QueuedWorkerMessage].self, forKey: .pendingWorkerMessages) ?? []
        validationBlockedReason = try c.decodeIfPresent(String.self, forKey: .validationBlockedReason)
        acceptanceCriteria = try c.decodeIfPresent([AcceptanceCriterion].self, forKey: .acceptanceCriteria) ?? []
        steps = try c.decodeIfPresent([TaskStep].self, forKey: .steps) ?? []
        validation = try c.decodeIfPresent(TaskValidationState.self, forKey: .validation)
        isTemplate = try c.decodeIfPresent(Bool.self, forKey: .isTemplate) ?? false
        parentTaskID = try c.decodeIfPresent(UUID.self, forKey: .parentTaskID)
        sessionID = try c.decodeIfPresent(UUID.self, forKey: .sessionID)
        templateInputDefinitions = try c.decodeIfPresent([TemplateInputDefinition].self, forKey: .templateInputDefinitions) ?? []
        templateInstanceTitleTemplate = try c.decodeIfPresent(String.self, forKey: .templateInstanceTitleTemplate)
        templateInputValues = try c.decodeIfPresent([String: String].self, forKey: .templateInputValues) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(description, forKey: .description)
        try c.encode(status, forKey: .status)
        try c.encode(disposition, forKey: .disposition)
        try c.encode(assigneeIDs, forKey: .assigneeIDs)
        try c.encodeIfPresent(result, forKey: .result)
        try c.encodeIfPresent(commentary, forKey: .commentary)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(completedAt, forKey: .completedAt)
        if !updates.isEmpty {
            try c.encode(updates, forKey: .updates)
        }
        if acknowledgmentCount > 0 {
            try c.encode(acknowledgmentCount, forKey: .acknowledgmentCount)
        }
        try c.encodeIfPresent(lastBrownContext, forKey: .lastBrownContext)
        try c.encodeIfPresent(summary, forKey: .summary)
        try c.encodeIfPresent(relevantMemories, forKey: .relevantMemories)
        try c.encodeIfPresent(relevantPriorTasks, forKey: .relevantPriorTasks)
        try c.encodeIfPresent(scheduledRunAt, forKey: .scheduledRunAt)
        try c.encodeIfPresent(lastEditedAt, forKey: .lastEditedAt)
        if !descriptionAttachments.isEmpty {
            try c.encode(descriptionAttachments, forKey: .descriptionAttachments)
        }
        if !resultAttachments.isEmpty {
            try c.encode(resultAttachments, forKey: .resultAttachments)
        }
        if !resultItems.isEmpty {
            try c.encode(resultItems, forKey: .resultItems)
        }
        try c.encodeIfPresent(approvedTools, forKey: .approvedTools)
        try c.encodeIfPresent(userToolOverrides, forKey: .userToolOverrides)
        try c.encodeIfPresent(helpRequest, forKey: .helpRequest)
        try c.encode(pendingWorkerMessages, forKey: .pendingWorkerMessages)
        try c.encodeIfPresent(validationBlockedReason, forKey: .validationBlockedReason)
        if !acceptanceCriteria.isEmpty {
            try c.encode(acceptanceCriteria, forKey: .acceptanceCriteria)
        }
        if !steps.isEmpty {
            try c.encode(steps, forKey: .steps)
        }
        try c.encodeIfPresent(validation, forKey: .validation)
        if isTemplate { try c.encode(true, forKey: .isTemplate) }
        try c.encodeIfPresent(parentTaskID, forKey: .parentTaskID)
        try c.encodeIfPresent(sessionID, forKey: .sessionID)
        if !templateInputDefinitions.isEmpty {
            try c.encode(templateInputDefinitions, forKey: .templateInputDefinitions)
        }
        try c.encodeIfPresent(templateInstanceTitleTemplate, forKey: .templateInstanceTitleTemplate)
        if !templateInputValues.isEmpty {
            try c.encode(templateInputValues, forKey: .templateInputValues)
        }
    }
}

/// A string-only input definition owned by a template task.
public struct TemplateInputDefinition: Codable, Sendable, Equatable {
    public var name: String
    public var description: String
    public var required: Bool

    public init(name: String, description: String, required: Bool) {
        self.name = name
        self.description = description
        self.required = required
    }
}
