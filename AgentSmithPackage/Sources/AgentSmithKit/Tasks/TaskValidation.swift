import Foundation

/// Who authored a task-attached artifact (criterion or step). Authority boundaries hang
/// off this: criteria are requester-side (user/Smith/system), steps are worker-side —
/// and the worker being judged never holds the pen on its own acceptance contract.
public enum TaskAuthorship: String, Codable, Sendable {
    case user
    case smith
    case worker
    /// Synthesized by the runtime (e.g. the implicit default-acceptance criterion
    /// materialized for a criterion-less task).
    case system
}

/// One item of a task's acceptance contract. Judged by an evaluator at `.validating`;
/// the array lives on the task itself — the task is the source of truth.
public struct AcceptanceCriterion: Codable, Sendable, Equatable, Identifiable {
    /// Which evaluation function judges this criterion. `.registry` names a definition
    /// in the user-owned registry; `.inline` embeds a Smith-authored definition whose
    /// capabilities are capped (read-only evidence tools, default model) so authoring
    /// one grants nothing new. Nil → the shipped `default-acceptance` definition.
    public enum Validator: Codable, Sendable, Equatable {
        case registry(String)
        case inline(EvaluatorDefinition)

        private enum CodingKeys: String, CodingKey {
            case registry, inline
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let name = try c.decodeIfPresent(String.self, forKey: .registry) {
                self = .registry(name)
            } else if let definition = try c.decodeIfPresent(EvaluatorDefinition.self, forKey: .inline) {
                self = .inline(definition)
            } else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "criterion validator needs 'registry' or 'inline'"
                ))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .registry(let name): try c.encode(name, forKey: .registry)
            case .inline(let definition): try c.encode(definition, forKey: .inline)
            }
        }
    }

    public let id: UUID
    public var text: String
    /// Whether the validator may WAIVE this criterion as not-applicable. A WAIVE against
    /// a non-waivable criterion is recorded as an ERROR (a validator/author disagreement
    /// escalates; it never silently passes or fails the work).
    public var waivable: Bool
    public var origin: TaskAuthorship
    public var validator: Validator?

    public init(
        id: UUID = UUID(),
        text: String,
        waivable: Bool = false,
        origin: TaskAuthorship,
        validator: Validator? = nil
    ) {
        self.id = id
        self.text = text
        self.waivable = waivable
        self.origin = origin
        self.validator = validator
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

    public init(
        id: UUID = UUID(),
        criterionID: UUID,
        verdict: Verdict,
        validatorName: String,
        validatorHash: String,
        round: Int,
        recordedAt: Date = Date()
    ) {
        self.id = id
        self.criterionID = criterionID
        self.verdict = verdict
        self.validatorName = validatorName
        self.validatorHash = validatorHash
        self.round = round
        self.recordedAt = recordedAt
    }
}

/// One worker mutation of a task's step list, dispatched through
/// `TaskStore.applyStepAction`. Removal and skipping demand a note — the validator
/// reads it.
public enum TaskStepAction: Sendable {
    case add(text: String)
    case update(stepID: UUID, newText: String)
    case setStatus(stepID: UUID, status: TaskStep.Status, note: String?)
}

/// The task's validation ledger: round counter, the append-only verdict audit, and the
/// definitions PINNED (full body, not just hash) at first use so later registry edits
/// apply to future tasks only. Stored on the task — idempotent, restartable validation
/// reconstructs everything it needs from here.
public struct TaskValidationState: Codable, Sendable, Equatable {
    public var round: Int
    public var verdictRecords: [CriterionVerdictRecord]
    public var pinnedDefinitions: [String: EvaluatorDefinition]

    public init(round: Int = 0, verdictRecords: [CriterionVerdictRecord] = [], pinnedDefinitions: [String: EvaluatorDefinition] = [:]) {
        self.round = round
        self.verdictRecords = verdictRecords
        self.pinnedDefinitions = pinnedDefinitions
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
