import Foundation
import SwiftLLMKit

/// How bad a channel message is — an axis entirely separate from `ChannelMessageKind`.
///
/// Kind answers *what this message is* (a tool call, a task lifecycle event, a validation
/// verdict). Severity answers *how bad it is*. They are orthogonal: a `toolOutput` can be a
/// routine result or a hard failure, and a `securityReview` can be SAFE or ABORT. Encoding
/// badness into the kind enum instead — a `.toolFailed` case beside `.toolOutput` — was
/// considered and rejected: it needs a new case for every failure flavour, it splits each
/// family's rows across two kinds so every existing reader has to learn both, and it still
/// leaves the transcript filter unable to express "show me anything bad", which is the actual
/// thing that was missing.
///
/// ## Why this exists
///
/// A user who hid `tool_output` to quiet the transcript also, unavoidably, hid every FAILED
/// tool call — because a failure was posted with the identical kind as a success and the typed
/// `ToolExecutionResult.succeeded` fact was dropped at the post site. On 2026-09-20 that hid
/// seven consecutive `create_task` failures: the user saw nothing, and the request they had
/// made was silently abandoned. `TranscriptFilter` now takes a severity FLOOR that re-admits
/// anything at or above it, so a noise filter can never again be a failure filter.
///
/// ## Ordering is load-bearing
///
/// `Comparable` is what makes a floor expressible (`severity >= floor`). The order is
/// info < warning < error; adding a level means placing it in `allCases` at the right rank.
///
/// ## Wire compatibility
///
/// Severity is persisted in `metadata["severity"]`, which is the ONLY key written going forward.
/// Before this type existed, producers stamped bare `isError: true` and `isWarning: true`
/// booleans and the persisted corpus is full of those rows, so `ChannelMessage.severity` derives
/// their corresponding levels when no `severity` key is present — the same way `kind` derives
/// `.securityReview` for rows written before that kind existed. The derivation lives in the
/// accessor, never at a read site, and nothing dual-writes: one slot, one writer.
public enum MessageSeverity: String, Codable, Sendable, Hashable, CaseIterable, Comparable {

    /// Ordinary traffic. The overwhelming majority of messages; never stamped explicitly, since
    /// a message with no severity key already reads as `.info`.
    case info = "info"

    /// Something the user should notice but that did not stop the work: a security WARN verdict,
    /// a retry that eventually succeeded, a clamped output, a dropped tool call.
    case warning = "warning"

    /// Something failed. A tool call that returned `succeeded == false`, an agent that could not
    /// recover, a validator that errored out, a provider that gave up.
    case error = "error"

    /// The level for a legacy security-review row, keyed off its `securityDisposition` wire tag.
    ///
    /// Only for rows written before severity existed; current producers stamp `severity` from
    /// `SecurityDisposition.severity` and never reach this. The two must agree, which is why the
    /// tags are mapped here rather than re-judged: `SecurityDispositionSeverityTests` pins the
    /// live mapping and `legacySecurityRowsMatchLiveSeverity` pins this one against it.
    ///
    /// An unrecognized tag answers `.info` rather than `.error`: unlike a malformed `severity`
    /// value — which is corrupt data and fails toward visible — an unknown disposition tag is
    /// just a row this build does not know about, and painting every one of them red would be
    /// worse than leaving it plain.
    static func forSecurityDispositionTag(_ tag: String) -> MessageSeverity {
        switch tag {
        case "denied", "abort", "unavailable": return .error
        case "warning", "cancelled":           return .warning
        default:                               return .info
        }
    }

    /// Rank used for both `Comparable` and the filter floor. Explicit rather than derived from
    /// `allCases` order so reordering the cases cannot silently reorder severity.
    private var rank: Int {
        switch self {
        case .info:    return 0
        case .warning: return 1
        case .error:   return 2
        }
    }

    public static func < (lhs: MessageSeverity, rhs: MessageSeverity) -> Bool {
        lhs.rank < rhs.rank
    }
}

extension MessageSeverity: CustomStringConvertible {
    public var description: String { rawValue }
}

public extension AnyCodable {
    /// Wraps a severity for the `metadata["severity"]` slot, so a post site names the level
    /// rather than spelling its wire string: `"severity": .severity(.error)`.
    static func severity(_ severity: MessageSeverity) -> AnyCodable {
        .string(severity.rawValue)
    }
}
