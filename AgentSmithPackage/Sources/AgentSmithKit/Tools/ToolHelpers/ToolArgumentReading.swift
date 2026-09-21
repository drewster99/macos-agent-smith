import Foundation
import SwiftLLMKit

/// Reading OPTIONAL tool arguments, where an argument supplied as an empty placeholder means
/// ABSENT.
///
/// ## The problem
///
/// Some models emit every optional property on every call rather than omitting the ones they do
/// not mean. `gpt-5.6-sol` on the Codex endpoint does it unprompted — with no `strict` flag set
/// and only `title`/`description` in `required`, it still sent `scheduled_run_at: ""`,
/// `template_inputs: []`, `attachment_ids: []` and `template_instance_title_template: ""` on
/// every single `create_task` call.
///
/// Those sentinels carry no intent. An empty array defines no template inputs and a blank string
/// names no timestamp, which is exactly what omitting the key means. But a tool that
/// pattern-matches on PRESENCE — `if case .string(let s) = arguments[key]` — reads the sentinel
/// as a deliberate value and then rejects it, and the caller has no way to comply because it
/// cannot stop sending the key.
///
/// That is not hypothetical. On 2026-09-20 it dead-ended `create_task` seven times in a row:
/// first `Invalid scheduled_run_at: '' is not a valid ISO-8601 timestamp`, then — after the model
/// guessed a literal date to get past it, including one in the past — six rounds of
/// `template_inputs are valid only when is_template is true`. The user's request was abandoned.
///
/// ## Why these are opt-in, per call site
///
/// There is deliberately no blanket "empty means absent" rule, and normalizing arguments
/// centrally at the dispatch boundary would be a bug. For some arguments empty IS the meaning:
/// `FileEditTool`'s `new_string: ""` is a deletion, not an omission. A required argument keeps
/// `guard case .string` and keeps rejecting empty. These accessors are chosen by a call site that
/// knows its own argument is optional.
///
/// ## The semantics are not new
///
/// `ListTasksTool.parseDateFilters` has read its optional dates exactly this way all along, which
/// is why `list_tasks` absorbed `created_after: ""` from the same model, on the same turn, that
/// `create_task` rejected `scheduled_run_at: ""`. This hoists that behavior out of the one tool
/// that had it so every tool can share it.
enum ToolArguments {

    /// A meaningful string, or `nil` when the argument is absent, null, blank, or not a string.
    ///
    /// Whitespace is trimmed before the blank test — `"  "` names a value no more than `""`
    /// does — but the RETURNED string is trimmed too, so a caller never has to re-trim and two
    /// callers can never disagree about whether it was.
    static func optionalString(_ arguments: [String: AnyCodable], _ key: String) -> String? {
        guard case .string(let raw)? = arguments[key] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A non-empty array, or `nil` when the argument is absent, null, empty, or not an array.
    static func optionalArray(_ arguments: [String: AnyCodable], _ key: String) -> [AnyCodable]? {
        guard case .array(let values)? = arguments[key], !values.isEmpty else { return nil }
        return values
    }

    /// A bool, or `nil` when the argument is absent, null, or not a bool.
    ///
    /// No emptiness notion applies — `false` is a real value a caller can mean, and must never
    /// read as absent. Present so that optional-argument reading has one home rather than two
    /// conventions.
    static func optionalBool(_ arguments: [String: AnyCodable], _ key: String) -> Bool? {
        guard case .bool(let value)? = arguments[key] else { return nil }
        return value
    }

    /// An integer, or `nil` when the argument is absent, null, or not numeric.
    ///
    /// Accepts a `.double` that is exactly integral, because a JSON number that arrives as `5.0`
    /// is the integer 5 — the wire type is the encoder's choice, not the caller's. A fractional
    /// double is rejected rather than truncated: silently turning 2.7 into 2 is the kind of
    /// quiet default this codebase does not take.
    static func optionalInt(_ arguments: [String: AnyCodable], _ key: String) -> Int? {
        switch arguments[key] {
        case .int(let value):
            return value
        case .double(let value):
            guard value.rounded() == value, let exact = Int(exactly: value.rounded()) else { return nil }
            return exact
        default:
            return nil
        }
    }
}
