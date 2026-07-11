import Foundation

/// A unit of work managed by the orchestration system.
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
    /// Number of times `task_acknowledged` has been called for this task. Starts at 0;
    /// incremented each time Brown acknowledges. A value > 1 means Brown is picking up
    /// after a prior run (rejection-revision or respawn), not a fresh assignment.
    /// Persisted so the signal survives app restart and new-Brown spawns.
    public var acknowledgmentCount: Int
    /// Compressed summary of Brown's last working state, saved on termination for resumability.
    public var lastBrownContext: String?
    /// LLM-generated summary of the task (populated after completion/failure).
    public var summary: String?
    /// Relevant memories retrieved at task creation, for Brown's context.
    public var relevantMemories: [RelevantMemory]?
    /// Relevant prior task summaries retrieved at task creation.
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

    /// The acceptance contract: criteria judged by evaluators when the task enters
    /// `.validating`. Requester-owned (user/Smith/system); the worker never edits these.
    /// Empty means the implicit default-acceptance criterion is materialized at first
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
    /// The task sits in `.awaitingReview` (reusing the review wait/slot machinery) but this
    /// field marks it as a help request rather than completed work: `review_work` refuses it
    /// and Smith answers via `provide_help`, which clears this and returns the task to running.
    /// Holds the formatted blocker + what's needed, for Smith's context and the UI.
    public var helpRequest: String?

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

    /// Maximum number of updates retained per task.
    public static let maxUpdates = 20

    public enum Status: String, Codable, Sendable, CaseIterable {
        case pending
        case running
        case completed
        case failed
        case paused
        case awaitingReview
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

        /// Whether this status represents work that is actively running — prevents archiving or deletion.
        public var isInProgress: Bool {
            self == .running || self == .paused || self == .awaitingReview || self == .validating
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
            case .running, .awaitingReview, .validating:
                return false
            }
        }

        /// Whether the user can edit the task's acceptance criteria and step list in
        /// this state — any state where no worker or validator is actively consuming
        /// them. `awaitingReview` is included deliberately: fixing a wrong criterion is
        /// exactly how a validation escalation gets resolved before work is sent back.
        public var isValidationContractEditable: Bool {
            switch self {
            case .pending, .paused, .interrupted, .scheduled, .failed, .awaitingReview:
                return true
            case .running, .validating, .completed:
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
        approvedTools: [String]? = nil,
        userToolOverrides: [String: Bool]? = nil,
        helpRequest: String? = nil,
        acceptanceCriteria: [AcceptanceCriterion] = [],
        steps: [TaskStep] = [],
        validation: TaskValidationState? = nil,
        isTemplate: Bool = false,
        parentTaskID: UUID? = nil
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
        self.approvedTools = approvedTools
        self.userToolOverrides = userToolOverrides
        self.helpRequest = helpRequest
        self.acceptanceCriteria = acceptanceCriteria
        self.steps = steps
        self.validation = validation
        self.isTemplate = isTemplate
        self.parentTaskID = parentTaskID
    }

    // MARK: - Codable (backward-compatible with persisted data lacking `disposition`)

    private enum CodingKeys: String, CodingKey {
        case id, title, description, status, disposition, assigneeIDs, result, commentary, createdAt, updatedAt, startedAt, completedAt, updates, acknowledgmentCount, lastBrownContext, summary, relevantMemories, relevantPriorTasks, scheduledRunAt, lastEditedAt, descriptionAttachments, resultAttachments, approvedTools, userToolOverrides, helpRequest, acceptanceCriteria, steps, validation, isTemplate, parentTaskID
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
        approvedTools = try c.decodeIfPresent([String].self, forKey: .approvedTools)
        userToolOverrides = try c.decodeIfPresent([String: Bool].self, forKey: .userToolOverrides)
        helpRequest = try c.decodeIfPresent(String.self, forKey: .helpRequest)
        acceptanceCriteria = try c.decodeIfPresent([AcceptanceCriterion].self, forKey: .acceptanceCriteria) ?? []
        steps = try c.decodeIfPresent([TaskStep].self, forKey: .steps) ?? []
        validation = try c.decodeIfPresent(TaskValidationState.self, forKey: .validation)
        isTemplate = try c.decodeIfPresent(Bool.self, forKey: .isTemplate) ?? false
        parentTaskID = try c.decodeIfPresent(UUID.self, forKey: .parentTaskID)
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
        try c.encodeIfPresent(approvedTools, forKey: .approvedTools)
        try c.encodeIfPresent(userToolOverrides, forKey: .userToolOverrides)
        try c.encodeIfPresent(helpRequest, forKey: .helpRequest)
        if !acceptanceCriteria.isEmpty {
            try c.encode(acceptanceCriteria, forKey: .acceptanceCriteria)
        }
        if !steps.isEmpty {
            try c.encode(steps, forKey: .steps)
        }
        try c.encodeIfPresent(validation, forKey: .validation)
        if isTemplate { try c.encode(true, forKey: .isTemplate) }
        try c.encodeIfPresent(parentTaskID, forKey: .parentTaskID)
    }
}
