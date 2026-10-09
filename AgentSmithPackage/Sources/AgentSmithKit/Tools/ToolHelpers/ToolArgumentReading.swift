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

    /// How an optional UUID argument read.
    ///
    /// Three outcomes, not two, because "absent" and "malformed" demand opposite responses: the
    /// first falls through to whatever the tool does without the argument, the second must be
    /// refused so the caller learns it sent garbage. Collapsing them to `UUID?` is what forces a
    /// call site to pick one of those behaviors for both.
    enum OptionalUUID: Equatable {
        /// Not supplied — absent, null, blank, or the all-zero placeholder.
        case absent
        case value(UUID)
        /// Supplied and unparseable. Carries the original text so the error can quote it.
        case malformed(String)
    }

    /// The all-zero UUID, which this system never issues as an id.
    ///
    /// Every task, step, wake and attachment id comes from `UUID()`, whose version-4 layout
    /// cannot produce all zeroes — so a nil UUID on the wire is never something to look up. It
    /// is a model's invented stand-in for "no value", the same reflex that produces `""` and
    /// `[]`, and it is MORE dangerous than those because it parses: `list_tasks` accepted it and
    /// filtered to the children of a task that does not exist, answering "no tasks" to a caller
    /// that meant "no filter". Reserving it here is what makes that unrepresentable.
    private static let placeholderUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")

    /// A UUID argument that a caller may legitimately omit. See `OptionalUUID`.
    static func optionalUUID(_ arguments: [String: AnyCodable], _ key: String) -> OptionalUUID {
        guard let raw = optionalString(arguments, key) else { return .absent }
        guard let parsed = UUID(uuidString: raw) else { return .malformed(raw) }
        return parsed == placeholderUUID ? .absent : .value(parsed)
    }

    /// Whether an argument carries a value at all: false when it is absent, null, a blank string,
    /// an empty array or an empty object; true for anything else, `false` and `0` included. For a
    /// key a tool refuses whatever its value says (a retired parameter): a model that emits every
    /// key it has seen sends the empty placeholder, which says nothing and must not be refused.
    static func isSupplied(_ arguments: [String: AnyCodable], _ key: String) -> Bool {
        switch arguments[key] {
        case nil, .null?:
            return false
        case .string(let raw)?:
            return !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .array(let values)?:
            return !values.isEmpty
        case .dictionary(let entries)?:
            return !entries.isEmpty
        case .bool?, .int?, .double?:
            return true
        }
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

    /// How an optional bool argument read, when reading a wrong-typed value as absent is unsafe.
    ///
    /// Three outcomes for the same reason as `OptionalUUID`: a switch that is irreversible once
    /// acted on (`create_task`'s `requires_user_acceptance` — the task may start at once, after which
    /// the gate can't change) must refuse `"yes"` rather than silently run as if it were `false`.
    enum OptionalBool: Equatable {
        /// Not supplied — absent, null, or a blank-string placeholder.
        case absent
        case value(Bool)
        /// Supplied as something other than a bool. Carries a rendering for the error.
        case malformed(String)
    }

    /// A bool argument whose wrong-typed value must be refused, not dropped. A JSON bool reads as
    /// itself; the strings `"true"`/`"false"` (any case) read as the bool they spell, since a model
    /// that quotes a bool means that bool. See `OptionalBool`.
    static func strictOptionalBool(_ arguments: [String: AnyCodable], _ key: String) -> OptionalBool {
        switch arguments[key] {
        case nil, .null?:
            return .absent
        case .bool(let value)?:
            return .value(value)
        case .string(let raw)?:
            switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "": return .absent
            case "true": return .value(true)
            case "false": return .value(false)
            default: return .malformed("\"\(raw)\"")
            }
        case let other?:
            return .malformed(String(describing: other))
        }
    }

    /// How an optional integer argument read, when reading a wrong-typed value as absent is unsafe.
    /// Three outcomes for the same reason as `OptionalBool`.
    enum OptionalInt: Equatable {
        /// Not supplied — absent, null, or a blank-string placeholder.
        case absent
        case value(Int)
        /// Supplied as something other than a whole number. Carries a rendering for the error.
        case malformed(String)
    }

    /// An integer argument whose wrong-typed value must be refused, not dropped. A JSON integer, or
    /// a double that is exactly integral, reads as itself; a string holding a whole number reads as
    /// that number, since a model that quotes a number means that number. See `OptionalInt`.
    static func strictOptionalInt(_ arguments: [String: AnyCodable], _ key: String) -> OptionalInt {
        switch arguments[key] {
        case nil, .null?:
            return .absent
        case .string(let raw)?:
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return .absent }
            if let value = Int(trimmed) { return .value(value) }
            return .malformed("\"\(raw)\"")
        case .int(let value)?:
            return .value(value)
        case .double(let value)?:
            guard value.rounded() == value, let exact = Int(exactly: value) else { return .malformed(String(value)) }
            return .value(exact)
        case let other?:
            return .malformed(String(describing: other))
        }
    }

    /// How an optional list-of-strings argument read, when dropping part of it silently is unsafe.
    /// Three outcomes for the same reason as `OptionalUUID`.
    enum OptionalStringList: Equatable {
        /// Not supplied — absent, null, a blank string, an empty array, or only blank items.
        case absent
        /// The non-blank items, trimmed, in order.
        case value([String])
        /// Supplied in a shape that can't be read as a list of strings. Carries the reason.
        case malformed(String)
    }

    /// A list of strings whose malformed parts must be refused, not dropped: a step or required
    /// capability that silently vanishes leaves a task without something its author asked for.
    /// Blank items are no items (the placeholder reflex again). A single non-blank string is
    /// refused rather than read as one item, since it may pack several. See `OptionalStringList`.
    static func strictOptionalStringList(_ arguments: [String: AnyCodable], _ key: String) -> OptionalStringList {
        switch arguments[key] {
        case nil, .null?:
            return .absent
        case .string(let raw)?:
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .absent }
            return .malformed("'\(key)' must be an array of strings, not a single string — put each item in its own array element.")
        case .array(let values)?:
            var items: [String] = []
            for (index, value) in values.enumerated() {
                switch value {
                case .null:
                    continue
                case .string(let text):
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { items.append(trimmed) }
                case .bool, .int, .double, .array, .dictionary:
                    return .malformed("'\(key)' item \(index + 1) is not a string — every item must be a string.")
                }
            }
            return items.isEmpty ? .absent : .value(items)
        case .bool?, .int?, .double?, .dictionary?:
            return .malformed("'\(key)' must be an array of strings.")
        }
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
