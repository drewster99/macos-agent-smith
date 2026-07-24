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

    private enum CodingKeys: String, CodingKey {
        case agentAssignments, agentPollIntervals, agentMaxToolCalls
        case agentMessageDebounceIntervals, toolsEnabled, autoRunNextTask
        case autoRunInterruptedTasks
        /// Retired. The validator's model used to live in its own scalar because `AgentRole`
        /// had no validator case; it is now an ordinary `agentAssignments[.validator]` entry.
        /// Decoded (never encoded) so an existing session file's assignment survives.
        case validatorAssignment
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agentAssignments = try c.decodeIfPresent([AgentRole: UUID].self, forKey: .agentAssignments) ?? [:]
        agentPollIntervals = try c.decodeIfPresent([AgentRole: TimeInterval].self, forKey: .agentPollIntervals) ?? [:]
        agentMaxToolCalls = try c.decodeIfPresent([AgentRole: Int].self, forKey: .agentMaxToolCalls) ?? [:]
        agentMessageDebounceIntervals = try c.decodeIfPresent([AgentRole: TimeInterval].self, forKey: .agentMessageDebounceIntervals) ?? [:]
        toolsEnabled = try c.decodeIfPresent([String: Bool].self, forKey: .toolsEnabled) ?? [:]
        autoRunNextTask = try c.decodeIfPresent(Bool.self, forKey: .autoRunNextTask) ?? true
        autoRunInterruptedTasks = try c.decodeIfPresent(Bool.self, forKey: .autoRunInterruptedTasks) ?? true
        // One-way migration of the retired scalar. An explicit `agentAssignments[.validator]`
        // always wins — once the new key is written the legacy one is stale by definition.
        if agentAssignments[.validator] == nil,
           let legacy = try c.decodeIfPresent(UUID.self, forKey: .validatorAssignment) {
            agentAssignments[.validator] = legacy
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(agentAssignments, forKey: .agentAssignments)
        try c.encode(agentPollIntervals, forKey: .agentPollIntervals)
        try c.encode(agentMaxToolCalls, forKey: .agentMaxToolCalls)
        try c.encode(agentMessageDebounceIntervals, forKey: .agentMessageDebounceIntervals)
        try c.encode(toolsEnabled, forKey: .toolsEnabled)
        try c.encode(autoRunNextTask, forKey: .autoRunNextTask)
        try c.encode(autoRunInterruptedTasks, forKey: .autoRunInterruptedTasks)
    }
}
