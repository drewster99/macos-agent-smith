import Foundation

/// Lightweight metadata for one conversation tab.
///
/// Each session maps 1:1 to a window/tab and an `AppViewModel` instance. Session
/// data (channel log, tasks, attachments, per-session settings) is stored under
/// `~/Library/Application Support/AgentSmith/sessions/<id>/`.
public struct Session: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Per-session settings blob persisted to `sessions/<id>/state.json`.
public struct SessionState: Codable, Sendable {
    public var agentAssignments: [AgentRole: UUID]
    public var agentPollIntervals: [AgentRole: TimeInterval]
    public var agentMaxToolCalls: [AgentRole: Int]
    public var agentMessageDebounceIntervals: [AgentRole: TimeInterval]
    public var toolsEnabled: [String: Bool]
    public var autoRunNextTask: Bool
    public var autoRunInterruptedTasks: Bool
    /// The `ModelConfiguration.id` the acceptance-validator runs on. Kept OUT of
    /// `agentAssignments` on purpose: `AgentRole` has no validator case, and its
    /// dictionary-key decoding gets no unknown-key fallback (a stray key would clobber an
    /// existing role). Optional — nil means "validation uses the Summarizer's model," the
    /// historical behavior, so older session files (which lack the key) decode unchanged.
    public var validatorAssignment: UUID?

    public init(
        agentAssignments: [AgentRole: UUID] = [:],
        agentPollIntervals: [AgentRole: TimeInterval] = [:],
        agentMaxToolCalls: [AgentRole: Int] = [:],
        agentMessageDebounceIntervals: [AgentRole: TimeInterval] = [:],
        toolsEnabled: [String: Bool] = [:],
        autoRunNextTask: Bool = true,
        autoRunInterruptedTasks: Bool = true,
        validatorAssignment: UUID? = nil
    ) {
        self.agentAssignments = agentAssignments
        self.agentPollIntervals = agentPollIntervals
        self.agentMaxToolCalls = agentMaxToolCalls
        self.agentMessageDebounceIntervals = agentMessageDebounceIntervals
        self.toolsEnabled = toolsEnabled
        self.autoRunNextTask = autoRunNextTask
        self.autoRunInterruptedTasks = autoRunInterruptedTasks
        self.validatorAssignment = validatorAssignment
    }
}
