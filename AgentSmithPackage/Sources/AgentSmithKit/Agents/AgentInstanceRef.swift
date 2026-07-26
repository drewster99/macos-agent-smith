import Foundation

/// Identifies a specific agent *instance* for inspector telemetry.
///
/// This replaces the old role-only keying, which collapsed every concurrent worker (and
/// every per-task evaluator) of a role into a single bucket — so two Browns running at
/// once overwrote each other's "thinking" indicator, turn records, and context.
///
/// - `instanceID` is the `AgentActor.id` for the real actors (Smith, Brown).
/// - The stateless evaluator roles (Security, Validator, Summarizer) are not actors.
///   Security is keyed by the id of the agent whose call it is guarding, so
///   "Security for Brown X" and "Security for Brown Y" stay distinct.
/// - `taskID` is the subject task when one applies (nil for Smith's taskless work).
///
/// The `(role, instanceID)` pair is the identity; `taskID` is carried metadata, not part
/// of equality's discriminator beyond what `instanceID` already provides.
public struct AgentInstanceRef: Hashable, Sendable {
    public let role: AgentRole
    public let instanceID: UUID
    public let taskID: UUID?

    public init(role: AgentRole, instanceID: UUID, taskID: UUID? = nil) {
        self.role = role
        self.instanceID = instanceID
        self.taskID = taskID
    }

    /// Builds a ref for `role`, using the concrete `instanceID` when the caller has one
    /// (real actors) or a process-stable per-role sentinel when it doesn't (e.g. the
    /// Summarizer, or aggregate "agent started / available tools" notices that aren't
    /// tied to a single spawn). `(role, instanceID)` still keeps roles distinct.
    public static func forRole(_ role: AgentRole, instanceID: UUID?) -> AgentInstanceRef {
        AgentInstanceRef(role: role, instanceID: instanceID ?? roleSentinelID(for: role))
    }

    /// A deterministic, valid, per-role sentinel UUID (no force-unwrap): the final byte
    /// encodes the role's `CaseIterable` index, so each role gets a distinct, stable id.
    public static func roleSentinelID(for role: AgentRole) -> UUID {
        let index = AgentRole.allCases.firstIndex(of: role) ?? 0
        let last = UInt8(truncatingIfNeeded: index)
        return UUID(uuid: (0xA6, 0xE7, 0x5E, 0x27, 0x00, 0x00, 0x00, 0x00,
                           0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, last))
    }
}
