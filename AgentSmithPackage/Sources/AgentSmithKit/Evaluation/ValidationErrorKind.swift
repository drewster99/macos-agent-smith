import Foundation

/// Why a validation judgment ended in an ERROR verdict. Declared by the code that produced the
/// error, at the moment it produced it, and carried as a typed value from there — never read back
/// out of the error's message, which is written for a person and gets reworded.
///
/// Raw values are the wire strings in `validation_metrics.jsonl` (`errorKind`,
/// `firstAttemptErrorKind`); they predate this type, so they keep their old spellings. Renaming a
/// case is free; changing a raw value changes the file format. When retiring a case, move it to
/// the Retired section: the file outlives the code that wrote it.
public enum ValidationErrorKind: String, Codable, Sendable, CaseIterable {
    /// The run passed its deadline.
    case timeout = "timeout"
    /// The run's task was cancelled.
    case cancelled = "cancelled"
    /// The provider call failed and wasn't retried (a permanent error, or a cancelled wait).
    case transport = "transport"
    /// The validator role was given a different model while the run waited on its provider.
    case modelChanged = "model_changed"
    /// The validator returned nothing to parse.
    case emptyResponse = "empty_response"
    /// Every allowed re-prompt still produced text that doesn't fit the output grammar.
    case unparseable = "unparseable"
    /// The forced final turn, and its one repair, produced no conforming result.
    case forcedVerdictFailed = "forced_verdict_failed"
    /// A rejection claimed a file was missing that a file_read in the same run read successfully.
    case contradictionGuard = "contradiction_guard"
    /// The validator WAIVED a criterion (or one item of it) that isn't waivable.
    case waiveNonWaivable = "waive_non_waivable"
    /// The validator answered with a token its grammar doesn't define.
    case unexpectedVerdictToken = "unexpected_verdict_token"
    /// A verdict was required and the validator returned a list of items.
    case itemsWhereVerdict = "items_where_verdict"
    /// A dynamic criterion's input enumerator couldn't be built, returned a verdict instead of a
    /// list, enumerated more items than allowed, or enumerated none for a non-waivable criterion.
    case enumeratorFailure = "enumerator_failure"
    /// The criterion's authored validator prompt couldn't be turned into a validator.
    case invalidValidatorPrompt = "invalid_validator_prompt"
    /// No model is assigned to the Validator role.
    case noModel = "no_model"
    /// The worker's tool scope, which a feasibility judgment needs, is unavailable.
    case noWorkerScope = "no_worker_scope"

    // MARK: Retired — no longer written, still in the file

    /// A run out of turns. Since #17 a run out of turns ends in a forced verdict turn instead.
    case turnExhaustion = "turn_exhaustion"
    /// An error message the old text classifier didn't recognize.
    case other = "other"
}
