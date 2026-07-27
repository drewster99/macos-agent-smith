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
    /// Whether `other` puts the SAME question to the judge — the single definition of "this
    /// criterion changed", shared by `setAcceptanceCriteria` (which verdicts to retire) and
    /// `recordCriterionVerdicts` (which mid-round verdicts may land). Those were two hand-copied
    /// three-field comparisons 200 lines apart that had to agree forever.
    ///
    /// `name` counts ONLY for a default-validated criterion, because that is exactly when the name
    /// IS the judging instruction — `composeValidatorSystemPrompt` renders `criterion.text` as the
    /// validation instructions for the default validator, while an authored prompt is told the name
    /// is display-only. Comparing it unconditionally would discard a sticky ACCEPT on a cosmetic
    /// rename, and `validatorHash` cannot catch the default-validator case because the shipped
    /// definition's hash is identical across renames.
    public func statesSameContract(as other: AcceptanceCriterion) -> Bool {
        validationPrompt == other.validationPrompt
            && inputEnumeratorPrompt == other.inputEnumeratorPrompt
            && waivable == other.waivable
            && (!usesDefaultValidator || name == other.name)
    }

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

/// One mutation of a task's acceptance contract, dispatched through `TaskStore.applyCriterionActions`
/// as a batch so a multi-criterion edit stays one call.
///
/// These exist because WHOLESALE REPLACE MINTS NEW UUIDs, and a new UUID is a new criterion: its
/// verdicts are retired, its rejection history no longer points at anything live, and there is no
/// way to diff what changed. `update` naming a `criterionID` is the entire point — identity survives
/// the edit. (Not a concurrency argument: Smith is single-threaded and owns the criteria outright.)
///
/// There is deliberately no `insert` or `move`. Criteria are judged independently — nothing in
/// `Evaluation/` sorts, indexes, or first-wins over `acceptanceCriteria` — so their order is
/// display-only. If display ordering is ever wanted it becomes a field on the criterion, never a
/// delete-and-re-add, which would destroy the identity these verbs exist to preserve.
public enum CriterionAction: Sendable {
    case add(name: String, validationPrompt: String, inputEnumeratorPrompt: String?, waivable: Bool, origin: TaskAuthorship)
    /// Restates a criterion's content while PRESERVING its `criterionID` and `origin`. Whether the
    /// restated content actually changed the contract is `statesSameContract(as:)`'s call, made once
    /// in the store — an update that changes nothing keeps its sticky verdict.
    case update(criterionID: UUID, name: String, validationPrompt: String, inputEnumeratorPrompt: String?, waivable: Bool)
    /// Removes the criterion. Its verdicts go with it (they judged a contract that no longer
    /// exists); its REJECTION HISTORY does not — that is task-level and append-only.
    case delete(criterionID: UUID)
}

/// Identifies ONE validation round: which attempt it is, and which version of the acceptance
/// contract it judged. Captured atomically when the round begins and handed to every store mutation
/// that round makes, so each mutation can refuse if the world moved while the round awaited an LLM.
///
/// Both halves are load-bearing and neither substitutes for the other. `round` catches a SECOND RUN
/// on the same ledger (`performStopAll` clears the reentrancy guard without awaiting in-flight runs,
/// and a restart re-enqueues every `.validating` task). `contractVersion` catches an EDIT to the
/// criteria, which `round` cannot: `resetValidationRound` zeroes `round` while keeping the ledger on
/// user Re-validate and Send-Back, so the same round number recurs at different times against
/// different contracts.
public struct ValidationRoundToken: Sendable, Equatable {
    /// 1-based attempt number within the current convergence budget.
    public let round: Int
    /// The acceptance contract's version at round start. See `TaskValidationState.contractVersion`.
    public let contractVersion: Int

    public init(round: Int, contractVersion: Int) {
        self.round = round
        self.contractVersion = contractVersion
    }
}

/// One criterion's rejection, captured as the validator saw it. Append-only and task-level, so it
/// outlives the criterion: a criterion that is edited, replaced, or deleted takes its verdicts with
/// it (deliberately — they were judged against a contract that no longer exists), and the record of
/// having been rejected would go with them.
///
/// This is what makes criteria-WEAKENING detectable. Smith's standing habit after a validation
/// failure is to loosen the criteria and retry; diffing a rejection's captured prompts against the
/// criterion's current text says whether the bar moved. No separate revision log is needed, because
/// the interesting edits are exactly the ones that follow a rejection.
///
/// Deliberately NOT a `CriterionVerdictRecord`: a distinct type structurally cannot leak into
/// settled counts, sticky resolution, or the "N of M" display. It is also two orders of magnitude
/// smaller than a verdict record (which carries the rendered prompts and the full response log
/// — ~52KB apiece against an `inactive_tasks.json` already in the tens of megabytes).
public struct CriterionRejection: Codable, Sendable, Equatable {
    public let criterionID: UUID
    /// The criterion's name AT REJECTION TIME. Captured because for a default-validated criterion
    /// the name IS the judging instruction (`composeValidatorSystemPrompt` renders `criterion.text`
    /// as the validation instructions), so a rename can weaken the bar on its own.
    public let name: String
    public let recordedAt: Date
    /// The judging instructions as given, so a later edit can be diffed against them.
    public let validationPrompt: String
    public let inputEnumeratorPrompt: String?
    /// The validator's stated reason for rejecting.
    public let rejectionText: String

    public init(
        criterionID: UUID,
        name: String,
        recordedAt: Date,
        validationPrompt: String,
        inputEnumeratorPrompt: String?,
        rejectionText: String
    ) {
        self.criterionID = criterionID
        self.name = name
        self.recordedAt = recordedAt
        self.validationPrompt = validationPrompt
        self.inputEnumeratorPrompt = inputEnumeratorPrompt
        self.rejectionText = rejectionText
    }

    /// The rejection a criterion earned, as the judged contract. Built from what the validator was
    /// actually shown, never from the criterion's current state.
    public init(judged criterion: AcceptanceCriterion, rejectionText: String, recordedAt: Date) {
        self.init(
            criterionID: criterion.id,
            name: criterion.name,
            recordedAt: recordedAt,
            validationPrompt: criterion.validationPrompt,
            inputEnumeratorPrompt: criterion.inputEnumeratorPrompt,
            rejectionText: rejectionText
        )
    }

    /// Whether `criterion` still puts the same question to the judge as it did when this rejection
    /// was recorded. `false` means the contract moved after a rejection — the edit worth looking at.
    public func statesSameContract(as criterion: AcceptanceCriterion) -> Bool {
        validationPrompt == criterion.validationPrompt
            && inputEnumeratorPrompt == criterion.inputEnumeratorPrompt
            && (!criterion.usesDefaultValidator || name == criterion.name)
    }
}

/// What `TaskStore.recordCriterionVerdicts` did with a wave of verdicts. The two outcomes are
/// distinct because they demand OPPOSITE things of the caller, and a bare `[]` meant both: a
/// validation run that has been superseded must ABANDON its round, while a run that simply had
/// every record filtered out is still the live run and continues into stall accounting. Conflating
/// them let a zombie run burn a round of the LIVE run's convergence budget on a contract it never
/// judged.
public enum VerdictRecordingOutcome: Sendable, Equatable {
    /// The write was made by the run that owns the ledger. The payload is what actually LANDED —
    /// possibly empty, when every record's criterion was edited mid-round and dropped by the
    /// contract-match filter. Progress is measured from this, never from the records offered.
    case recorded([CriterionVerdictRecord])
    /// This run no longer owns the task's ledger: another run has moved it on (or an edit reset
    /// its counters), or the task is gone. NOTHING was written, and the caller must return
    /// immediately rather than draw any conclusion from the round it just ran.
    case superseded
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
    /// while progressing, but enough straight rounds with zero new acceptances means the
    /// worker and validator disagree irreconcilably and the task FAILS (never parked on
    /// Smith). Optional so records written before the field decode unchanged.
    public var consecutiveStallRounds: Int?
    /// Append-only history of every rejection this task's criteria have earned, outliving the
    /// criteria themselves. Nothing prunes it: a criterion edit retires that criterion's VERDICTS
    /// (they were judged against a contract that no longer exists) but must never retire the
    /// evidence that it was rejected before the edit. Optional so ledgers written before the field
    /// decode unchanged — Swift's synthesized decoder does not fall back to property defaults, and
    /// a hand-written one would have to remember every future field. Read via `rejectionHistory`.
    public var criterionRejections: [CriterionRejection]?
    /// Monotonic counter bumped every time the acceptance criteria actually change. Optional for
    /// forward-compatible decoding; read via `contractVersion`.
    public var acceptanceContractVersion: Int?

    public init(
        round: Int = 0,
        verdictRecords: [CriterionVerdictRecord] = [],
        consecutiveStallRounds: Int? = nil,
        criterionRejections: [CriterionRejection]? = nil,
        acceptanceContractVersion: Int? = nil
    ) {
        self.round = round
        self.verdictRecords = verdictRecords
        self.consecutiveStallRounds = consecutiveStallRounds
        self.criterionRejections = criterionRejections
        self.acceptanceContractVersion = acceptanceContractVersion
    }

    /// The version of the acceptance contract these verdicts were judged against. Ledgers written
    /// before the field read as 0, which is correct: they have never seen an edit this build tracked.
    public var contractVersion: Int { acceptanceContractVersion ?? 0 }

    /// The single mutation of `contractVersion` — called wherever the criteria actually change.
    public mutating func bumpContractVersion() {
        acceptanceContractVersion = contractVersion + 1
    }

    /// Whether `token` still identifies the live round. False means the caller has been superseded
    /// and must not act on what it computed.
    public func isCurrentRound(_ token: ValidationRoundToken) -> Bool {
        round == token.round && contractVersion == token.contractVersion
    }

    /// The token identifying this ledger's current round.
    public var currentRoundToken: ValidationRoundToken {
        ValidationRoundToken(round: round, contractVersion: contractVersion)
    }

    /// Every rejection recorded on this task, oldest first. The persistence-shaped optional never
    /// escapes into the domain model.
    public var rejectionHistory: [CriterionRejection] { criterionRejections ?? [] }

    /// The rejections one criterion has earned, oldest first.
    public func rejectionHistory(for criterionID: UUID) -> [CriterionRejection] {
        rejectionHistory.filter { $0.criterionID == criterionID }
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
