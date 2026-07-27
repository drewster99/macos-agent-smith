import Foundation
import SwiftLLMKit

/// A debug snapshot of one context-compaction event: the agent's FULL conversation
/// history immediately before the splice and immediately after, plus provenance.
///
/// Captured only when compaction-diff debugging is enabled (or for a one-shot forced
/// compaction) — never on a hot path. The message arrays are the complete, UNFILTERED
/// history of every role (system, user, assistant, tool), exactly as the model saw it,
/// so the diff window can show what compaction actually removed and what it injected.
public struct CompactionDiffCapture: Identifiable, Sendable {

    /// What initiated the compaction that produced this capture.
    public enum Trigger: String, Sendable, Codable {
        /// User-invoked `/compact`.
        case manual
        /// Task-boundary automatic compaction (`autoCompactSmithIfNeeded`).
        case auto
        /// One-shot debug action that forced a compaction purely to inspect the diff.
        case forcedDebug

        /// Short human-readable label for the diff window's capture list.
        public var displayLabel: String {
            switch self {
            case .manual: return "Manual /compact"
            case .auto: return "Auto (task boundary)"
            case .forcedDebug: return "Forced (debug)"
            }
        }
    }

    public let id: UUID
    public let capturedAt: Date
    public let agentRole: AgentRole
    public let trigger: Trigger
    /// Full history before the splice — every message, every role, unfiltered.
    public let before: [LLMMessage]
    /// Full history after the splice.
    public let after: [LLMMessage]

    public var beforeCount: Int { before.count }
    public var afterCount: Int { after.count }

    public init(
        id: UUID,
        capturedAt: Date,
        agentRole: AgentRole,
        trigger: Trigger,
        before: [LLMMessage],
        after: [LLMMessage]
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.agentRole = agentRole
        self.trigger = trigger
        self.before = before
        self.after = after
    }
}
