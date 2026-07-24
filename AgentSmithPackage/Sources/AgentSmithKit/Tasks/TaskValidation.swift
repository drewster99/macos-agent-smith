import Foundation

/// Who authored a task-attached artifact (criterion or step). Authority boundaries hang
/// off this: criteria are requester-side (user/Smith/system), steps are worker-side —
/// and the worker being judged never holds the pen on its own acceptance contract.
public enum TaskAuthorship: String, Codable, Sendable {
    case user
    case smith
    case worker
    /// Synthesized by the runtime (e.g. the implicit default criterion
    /// materialized for a criterion-less task).
    case system

    /// Forward-compatibility fallback: an authorship rawValue this build doesn't know (written by a
    /// NEWER build) must not brick the decode of the whole task — `.system` is the safe bucket (it
    /// asserts no requester/worker authority, so it can't wrongly let the judged worker edit its own
    /// acceptance contract).
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TaskAuthorship(rawValue: raw) ?? .system
    }
}

/// One item of a task's acceptance contract. Judged by an evaluator at `.validating`;
/// the array lives on the task itself — the task is the source of truth.
public struct AcceptanceCriterion: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    /// Short user-facing label. It is never used as an LLM instruction.
    public var name: String
    /// Required instructions given to the LLM that judges this criterion.
    public var validationPrompt: String
    /// Optional instructions given to an LLM that must return a JSON array of strings.
    /// Each returned string is then judged independently using `validationPrompt`.
    public var inputEnumeratorPrompt: String?
    /// The active enumerator instruction. Nil, empty, and whitespace-only values all
    /// mean that this criterion is a single validation check.
    public var effectiveInputEnumeratorPrompt: String? {
        guard let trimmed = inputEnumeratorPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
    /// Source compatibility for code that still renders criterion text. Persisted data
    /// uses `name`, and this value is display-only.
    public var text: String {
        get { name }
        set { name = newValue }
    }
    /// Whether the validator may WAIVE this criterion as not-applicable. A WAIVE against
    /// a non-waivable criterion is recorded as an ERROR (a validator/author disagreement
    /// escalates; it never silently passes or fails the work).
    public var waivable: Bool
    public var origin: TaskAuthorship

    /// Which validator judges this criterion, keyed entirely on whether it carries an
    /// authored prompt. An EMPTY `validationPrompt` means "judge with the shipped default
    /// validator's general acceptance stance" (the only criterion built that way is the
    /// implicit one materialized for a criterion-less task). A NON-empty prompt means "judge
    /// by this prompt" — a task-scoped custom validator. `set_acceptance_criteria` requires a
    /// non-empty prompt, so user/Smith criteria are always custom; only the system's implicit
    /// criterion is default-judged.
    public var usesDefaultValidator: Bool {
        validationPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public init(
        id: UUID = UUID(),
        name: String,
        validationPrompt: String? = nil,
        inputEnumeratorPrompt: String? = nil,
        waivable: Bool = false,
        origin: TaskAuthorship
    ) {
        self.id = id
        self.name = name
        self.validationPrompt = validationPrompt ?? name
        self.inputEnumeratorPrompt = inputEnumeratorPrompt
        self.waivable = waivable
        self.origin = origin
    }

    // `text` (legacy display key) and `validator`/`prepare` (the removed on-disk registry
    // selection) are decoded-away, not read: extra keys in older task JSON are ignored, so
    // those tasks still load — they just resolve to the prompt-or-default convention above.
    private enum CodingKeys: String, CodingKey {
        case id, name, text, validationPrompt, inputEnumeratorPrompt, waivable, origin
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
            ?? container.decode(String.self, forKey: .text)
        validationPrompt = try container.decodeIfPresent(String.self, forKey: .validationPrompt) ?? name
        inputEnumeratorPrompt = try container.decodeIfPresent(String.self, forKey: .inputEnumeratorPrompt)
        waivable = try container.decodeIfPresent(Bool.self, forKey: .waivable) ?? false
        origin = try container.decode(TaskAuthorship.self, forKey: .origin)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(validationPrompt, forKey: .validationPrompt)
        try container.encodeIfPresent(inputEnumeratorPrompt, forKey: .inputEnumeratorPrompt)
        try container.encode(waivable, forKey: .waivable)
        try container.encode(origin, forKey: .origin)
    }
}

/// One item of the worker's plan — descriptive, churning, worker-owned. "Delete" is a
/// TOMBSTONE (`.removed`): hidden from the worker's active view and progress UI, always
/// visible to validators, so the record underneath the plan is append-only and a worker
/// can grow its obligations but never erase evidence.
public struct TaskStep: Codable, Sendable, Equatable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case pending
        case inProgress
        case completed
        case skipped
        case removed

        /// Forward-compatibility fallback, mirroring `AgentTask.Status`.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: raw) ?? .pending
        }
    }

    public let id: UUID
    public var text: String
    public var status: Status
    /// Required explanation when a step is skipped or removed — the validator reads it.
    public var note: String?
    public var origin: TaskAuthorship

    public init(
        id: UUID = UUID(),
        text: String,
        status: Status = .pending,
        note: String? = nil,
        origin: TaskAuthorship
    ) {
        self.id = id
        self.text = text
        self.status = status
        self.note = note
        self.origin = origin
    }

    /// Steps the worker (and progress UI) should still see.
    public var isActive: Bool { status != .removed }
}

/// The recorded outcome of judging one criterion in one validation round. Append-only on
/// the task (the audit trail); the latest record per criterion is the live verdict.
public struct CriterionVerdictRecord: Codable, Sendable, Equatable, Identifiable {
    public enum Verdict: Codable, Sendable, Equatable {
        case accepted
        case rejected(reason: String)
        case waived(reason: String)
        /// Timeout, turn exhaustion, provider failure, unparseable output, or a WAIVE
        /// against a non-waivable criterion. NEVER conflated with rejection — errors
        /// retry once, then escalate.
        case error(message: String)

        /// Sticky-final: this criterion is settled for the task attempt and is not
        /// re-validated in later rounds (prevents verdict-flip oscillation and halves
        /// cost). Editing the criterion resets it.
        public var isFinal: Bool {
            switch self {
            case .accepted, .waived: return true
            case .rejected, .error: return false
            }
        }
    }

    public let id: UUID
    public let criterionID: UUID
    public let verdict: Verdict
    /// Registry name or the inline definition's name — plus the content hash of what
    /// actually ran, so edited definitions can't rewrite what a report meant.
    public let validatorName: String
    public let validatorHash: String
    public let round: Int
    public let recordedAt: Date
    /// The fully rendered input the validator's model actually saw (capped) — with the
    /// pinned definition body this makes any verdict reproducible and debuggable.
    /// Optional-and-synthesized: records written before the field decode unchanged.
    public let renderedInput: String?
    /// The FULL system message the validator's model actually saw (capped) — the composed
    /// prompt including the criterion and the response-format contract, not just the pinned
    /// definition's base text. Optional-and-synthesized for pre-field records.
    public let renderedSystemPrompt: String?
    /// The validator's turn-by-turn output (capped): tool rounds as call→result
    /// previews, text turns verbatim including grammar-retry rounds. For dynamic
    /// criteria this is the prepare exchange followed by each item's exchange.
    public let responseLog: String?

    public init(
        id: UUID = UUID(),
        criterionID: UUID,
        verdict: Verdict,
        validatorName: String,
        validatorHash: String,
        round: Int,
        recordedAt: Date = Date(),
        renderedInput: String? = nil,
        renderedSystemPrompt: String? = nil,
        responseLog: String? = nil
    ) {
        self.id = id
        self.criterionID = criterionID
        self.verdict = verdict
        self.validatorName = validatorName
        self.validatorHash = validatorHash
        self.round = round
        self.recordedAt = recordedAt
        self.renderedInput = renderedInput
        self.renderedSystemPrompt = renderedSystemPrompt
        self.responseLog = responseLog
    }
}

public extension CriterionVerdictRecord.Verdict {
    /// Short human label for UI chips ("Accepted", "Rejected", …).
    var displayLabel: String {
        switch self {
        case .accepted: return "Accepted"
        case .rejected: return "Rejected"
        case .waived: return "Waived"
        case .error: return "Error"
        }
    }

    /// The reason/message text, when the verdict carries one.
    var detailText: String? {
        switch self {
        case .accepted: return nil
        case .rejected(let reason): return reason
        case .waived(let reason): return reason
        case .error(let message): return message
        }
    }
}

/// One mutation of a task's step list, dispatched through `TaskStore.applyStepAction`.
/// Issued by the worker (Brown) on its own task, or by the orchestrator (Smith) on a task
/// with no active worker. Removal and skipping demand a note — the validator reads it.
public enum TaskStepAction: Sendable {
    /// `origin` records who authored the step (`.worker` when Brown adds it, `.smith` when
    /// Smith seeds/edits a task's plan) — the same authorship recorded for seeded steps.
    case add(text: String, origin: TaskAuthorship)
    case update(stepID: UUID, newText: String)
    /// Moves a step between the REVERSIBLE statuses. `.removed` is rejected here on purpose:
    /// tombstoning is irreversible and terminal, unlike the four states this covers, so it gets
    /// its own verb (`delete`) rather than hiding as a one-way trapdoor in a status setter.
    case setStatus(stepID: UUID, status: TaskStep.Status, note: String?)
    /// Tombstones a step — the SOLE producer of `.removed`. Requires a note; the step leaves the
    /// active list but stays on the record for validators.
    case delete(stepID: UUID, note: String)
    /// HARD-deletes a step: the row is gone, no tombstone, no record. Authoring only — the
    /// caller must have established that the task has no validation history (see
    /// `AgentTask.isStepPlanPurgeable`), because on a task that has been judged this would
    /// destroy evidence rather than tidy a draft. Tombstoning (`delete`) is what a worker
    /// gets; purging is for shaping a plan that has not yet been run against.
    case purge(stepID: UUID)
    /// Repositions ONE active step. Cheap and race-tolerant: unlike `reorder` it doesn't require
    /// the caller to restate the whole list, so a concurrently-added step can't invalidate it.
    case move(stepID: UUID, destination: TaskStepDestination)
    /// Reorders the ACTIVE steps to match `orderedActiveIDs` (which must be exactly the current
    /// active step ids, in the desired order). Removed tombstones keep their record but are not
    /// reorderable. Prefer `move` for single-step adjustments.
    case reorder(orderedActiveIDs: [UUID])
}

/// Where a moved step should land, expressed relative to the ACTIVE step list.
public enum TaskStepDestination: Sendable, Equatable {
    case before(stepID: UUID)
    case after(stepID: UUID)
    /// 1-based index among the active steps, matching the numbering the worker sees.
    case position(Int)
}

/// The task's validation ledger: round counter and the append-only verdict audit. Stored
/// on the task — idempotent, restartable validation reconstructs everything it needs from
/// here (each round re-resolves its validators from the criteria, which are cheap and
/// deterministic: the shipped default, an inline definition, or a custom one built from the
/// criterion's own prompt).
public struct TaskValidationState: Codable, Sendable, Equatable {
    public var round: Int
    public var verdictRecords: [CriterionVerdictRecord]
    /// Consecutive rejection rounds in which NOTHING newly settled. This — not the
    /// absolute round count — is the convergence test: 50 criteria may take many rounds
    /// while progressing, but three straight rounds with zero new acceptances means the
    /// worker and validator disagree irreconcilably and the task FAILS (never parked on
    /// Smith). Optional so records written before the field decode unchanged.
    public var consecutiveStallRounds: Int?

    public init(round: Int = 0, verdictRecords: [CriterionVerdictRecord] = [], consecutiveStallRounds: Int? = nil) {
        self.round = round
        self.verdictRecords = verdictRecords
        self.consecutiveStallRounds = consecutiveStallRounds
    }

    /// The live verdict for a criterion (latest record wins).
    public func latestVerdict(for criterionID: UUID) -> CriterionVerdictRecord? {
        verdictRecords.last { $0.criterionID == criterionID }
    }

    /// Criteria whose latest verdict is sticky-final (accepted/waived).
    public func settledCriterionIDs() -> Set<UUID> {
        var settled: Set<UUID> = []
        var seen: Set<UUID> = []
        for record in verdictRecords.reversed() where !seen.contains(record.criterionID) {
            seen.insert(record.criterionID)
            if record.verdict.isFinal { settled.insert(record.criterionID) }
        }
        return settled
    }
}
