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

    public init(
        agentAssignments: [AgentRole: UUID] = [:],
        agentPollIntervals: [AgentRole: TimeInterval] = [:],
        agentMaxToolCalls: [AgentRole: Int] = [:],
        agentMessageDebounceIntervals: [AgentRole: TimeInterval] = [:],
        toolsEnabled: [String: Bool] = [:],
        autoRunNextTask: Bool = true,
        autoRunInterruptedTasks: Bool = true
    ) {
        self.agentAssignments = agentAssignments
        self.agentPollIntervals = agentPollIntervals
        self.agentMaxToolCalls = agentMaxToolCalls
        self.agentMessageDebounceIntervals = agentMessageDebounceIntervals
        self.toolsEnabled = toolsEnabled
        self.autoRunNextTask = autoRunNextTask
        self.autoRunInterruptedTasks = autoRunInterruptedTasks
    }
}
