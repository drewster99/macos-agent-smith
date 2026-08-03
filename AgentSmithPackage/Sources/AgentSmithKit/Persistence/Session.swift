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

/// A role's model choice — provider + model directly, no shared-config-pool / UUID indirection.
public struct ModelAssignment: Codable, Sendable, Equatable, Hashable {
    public var providerID: String
    public var modelID: String
    public init(providerID: String, modelID: String) {
        self.providerID = providerID
        self.modelID = modelID
    }
}

/// Per-session settings blob persisted to `sessions/<id>/state.json`.
public struct SessionState: Codable, Sendable {
    /// Which model each role runs. Direct `(provider, model)` — the config pool + UUID indirection
    /// was retired 2026-07-31; runtime tuning now lives in the per-(role, model) override store.
    public var agentAssignments: [AgentRole: ModelAssignment]
    /// Decode-only: a pre-retirement session's `[AgentRole: UUID]` config-pool assignments. Carried
    /// so the load path can map each UUID → its config's `(provider, model)` (the pool is still
    /// loaded for exactly this migration) and populate `agentAssignments`. Never encoded.
    public var legacyConfigAssignments: [AgentRole: UUID] = [:]
    public var agentPollIntervals: [AgentRole: TimeInterval]
    public var agentMaxToolCalls: [AgentRole: Int]
    public var agentMessageDebounceIntervals: [AgentRole: TimeInterval]
    public var toolsEnabled: [String: Bool]
    public var autoRunNextTask: Bool
    public var autoRunInterruptedTasks: Bool
    /// Sparse per-session orchestration override, layered over the app-wide effective default. `nil`
    /// (the common case) means this session inherits the app-wide orchestration settings entirely.
    public var orchestrationOverride: OrchestrationSettingsOverride?
    /// The task whose transcript the top pane shows, persisted so the selection survives relaunch.
    /// `nil` = nothing selected (top pane shows the "Select a task" prompt).
    public var selectedTaskID: UUID?
    public init(
        agentAssignments: [AgentRole: ModelAssignment] = [:],
        agentPollIntervals: [AgentRole: TimeInterval] = [:],
        agentMaxToolCalls: [AgentRole: Int] = [:],
        agentMessageDebounceIntervals: [AgentRole: TimeInterval] = [:],
        toolsEnabled: [String: Bool] = [:],
        autoRunNextTask: Bool = true,
        autoRunInterruptedTasks: Bool = true,
        orchestrationOverride: OrchestrationSettingsOverride? = nil,
        selectedTaskID: UUID? = nil
    ) {
        self.agentAssignments = agentAssignments
        self.agentPollIntervals = agentPollIntervals
        self.agentMaxToolCalls = agentMaxToolCalls
        self.agentMessageDebounceIntervals = agentMessageDebounceIntervals
        self.toolsEnabled = toolsEnabled
        self.autoRunNextTask = autoRunNextTask
        self.autoRunInterruptedTasks = autoRunInterruptedTasks
        self.orchestrationOverride = orchestrationOverride
        self.selectedTaskID = selectedTaskID
    }

    private enum CodingKeys: String, CodingKey {
        /// New direct `(provider, model)` assignments. `agentAssignments` (below) is the RETIRED
        /// pool-UUID key, decoded for one-time migration and never written.
        case agentModelAssignments
        case agentAssignments, agentPollIntervals, agentMaxToolCalls
        case agentMessageDebounceIntervals, toolsEnabled, autoRunNextTask
        case autoRunInterruptedTasks, orchestrationOverride, selectedTaskID
        /// Retired. The validator's model used to live in its own scalar because `AgentRole`
        /// had no validator case. Decoded (never encoded) so an existing session file's assignment
        /// survives — into the legacy pool-UUID set, migrated at load like the rest.
        case validatorAssignment
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agentAssignments = try c.decodeIfPresent([AgentRole: ModelAssignment].self, forKey: .agentModelAssignments) ?? [:]
        legacyConfigAssignments = try c.decodeIfPresent([AgentRole: UUID].self, forKey: .agentAssignments) ?? [:]
        agentPollIntervals = try c.decodeIfPresent([AgentRole: TimeInterval].self, forKey: .agentPollIntervals) ?? [:]
        agentMaxToolCalls = try c.decodeIfPresent([AgentRole: Int].self, forKey: .agentMaxToolCalls) ?? [:]
        agentMessageDebounceIntervals = try c.decodeIfPresent([AgentRole: TimeInterval].self, forKey: .agentMessageDebounceIntervals) ?? [:]
        toolsEnabled = try c.decodeIfPresent([String: Bool].self, forKey: .toolsEnabled) ?? [:]
        autoRunNextTask = try c.decodeIfPresent(Bool.self, forKey: .autoRunNextTask) ?? true
        autoRunInterruptedTasks = try c.decodeIfPresent(Bool.self, forKey: .autoRunInterruptedTasks) ?? true
        // `nil` (key absent) is the inherit-everything state, not a default value — no `?? …`.
        orchestrationOverride = try c.decodeIfPresent(OrchestrationSettingsOverride.self, forKey: .orchestrationOverride)
        selectedTaskID = try c.decodeIfPresent(UUID.self, forKey: .selectedTaskID)
        // One-way migration of the retired scalar. An explicit `agentAssignments[.validator]`
        // always wins — once the new key is written the legacy one is stale by definition.
        if legacyConfigAssignments[.validator] == nil,
           let legacy = try c.decodeIfPresent(UUID.self, forKey: .validatorAssignment) {
            legacyConfigAssignments[.validator] = legacy
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(agentAssignments, forKey: .agentModelAssignments)   // legacy pool-UUID key never rewritten
        try c.encode(agentPollIntervals, forKey: .agentPollIntervals)
        try c.encode(agentMaxToolCalls, forKey: .agentMaxToolCalls)
        try c.encode(agentMessageDebounceIntervals, forKey: .agentMessageDebounceIntervals)
        try c.encode(toolsEnabled, forKey: .toolsEnabled)
        try c.encode(autoRunNextTask, forKey: .autoRunNextTask)
        try c.encode(autoRunInterruptedTasks, forKey: .autoRunInterruptedTasks)
        try c.encodeIfPresent(orchestrationOverride, forKey: .orchestrationOverride)
        try c.encodeIfPresent(selectedTaskID, forKey: .selectedTaskID)
    }
}
