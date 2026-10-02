import Foundation

/// The three things a Security Agent verdict on a tool call can mean to a reader: the call went
/// ahead, it was held with a warning, or it was refused or never judged. The transcript filter
/// offers one checkbox per class.
///
/// Classified from the `securityDisposition` wire tag that `SecurityDisposition.channelTag` writes —
/// the closed set every verdict carries, including legacy rows that predate `messageKind`.
/// `SecurityVerdictClassTests` pins this mapping against `SecurityDisposition.approved` itself, so a
/// new outcome cannot land in a class that disagrees with whether the call actually ran.
public enum SecurityVerdictClass: String, CaseIterable, Sendable, Hashable {
    /// The call ran: approved, auto-approved, or approved with review switched off.
    case accept
    /// Held with a warning; an identical retry is approved.
    case warn
    /// Refused, or blocked without a verdict (reviewer unavailable, review cancelled).
    case block

    public var displayName: String {
        switch self {
        case .accept: return "Accepted"
        case .warn: return "Warnings"
        case .block: return "Denied or blocked"
        }
    }

    /// The class a `securityDisposition` tag belongs to. An unrecognized tag — a newer build's
    /// outcome — reads as `.block`: a value this build hasn't heard of is most likely a newer block,
    /// and filing it under "accepted" is the one wrong answer that would hide a call that never ran.
    public static func forDispositionTag(_ tag: String) -> SecurityVerdictClass {
        switch tag {
        case "approved", "autoApproved", "reviewDisabled": return .accept
        case "warning": return .warn
        default: return .block
        }
    }
}
