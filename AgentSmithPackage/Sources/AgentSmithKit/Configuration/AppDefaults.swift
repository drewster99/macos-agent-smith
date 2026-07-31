import Foundation
import SwiftLLMKit

/// Top-level Codable struct representing the bundled `defaults.json` schema.
///
/// Every field provides a default value for the application. UserDefaults entries
/// (set by the user in the UI) always take precedence over these values.
public struct AppDefaults: Codable, Sendable {
    /// Schema version — bump when the JSON format changes.
    public var version: Int = 2
    /// Registered LLM providers (connection details; API keys live in Keychain).
    public var providers: [ModelProvider]
    /// API keys for providers, keyed by provider ID. Only used in bundled defaults
    /// to bootstrap first-launch state — at runtime keys live in Keychain.
    public var providerAPIKeys: [String: String]
    /// Retired config pool. Still decoded/encoded so a shipped `defaults.json` that still carries
    /// the old UUID `agentAssignments` (into this pool) can be migrated to direct `(provider, model)`
    /// at decode time, and so an existing install's persisted pool keeps seeding legacy-session
    /// migration. The pool + UUID indirection was retired 2026-07-31.
    public var modelConfigurations: [ModelConfiguration]
    /// Each agent role's model, as a direct `(provider, model)`. A shipped `defaults.json` still
    /// carrying UUID `agentAssignments` is migrated here at decode time via ``modelConfigurations``.
    public var agentAssignments: [AgentRole: ModelAssignment]
    /// Per-role agent tuning parameters (poll intervals, tool-call limits, etc.).
    public var agentTuning: [AgentRole: AgentTuningDefaults]
    /// Speech and sound configuration.
    public var speech: SpeechDefaults

    public init(
        version: Int = 2,
        providers: [ModelProvider] = [],
        providerAPIKeys: [String: String] = [:],
        modelConfigurations: [ModelConfiguration] = [],
        agentAssignments: [AgentRole: ModelAssignment] = [:],
        agentTuning: [AgentRole: AgentTuningDefaults],
        speech: SpeechDefaults
    ) {
        self.version = version
        self.providers = providers
        self.providerAPIKeys = providerAPIKeys
        self.modelConfigurations = modelConfigurations
        self.agentAssignments = agentAssignments
        self.agentTuning = agentTuning
        self.speech = speech
    }

    private enum CodingKeys: String, CodingKey {
        case version, providers, providerAPIKeys, modelConfigurations
        /// New direct `(provider, model)` assignments — the only key written from now on.
        case agentModelAssignments
        /// Retired pool-UUID assignments. Decoded only to migrate a pre-retirement bundled file.
        case agentAssignments
        case agentTuning, speech
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 2
        providers = try c.decodeIfPresent([ModelProvider].self, forKey: .providers) ?? []
        providerAPIKeys = try c.decodeIfPresent([String: String].self, forKey: .providerAPIKeys) ?? [:]
        let configs = try c.decodeIfPresent([ModelConfiguration].self, forKey: .modelConfigurations) ?? []
        modelConfigurations = configs
        agentTuning = try c.decodeIfPresent([AgentRole: AgentTuningDefaults].self, forKey: .agentTuning) ?? [:]
        speech = try c.decode(SpeechDefaults.self, forKey: .speech)
        if let direct = try c.decodeIfPresent([AgentRole: ModelAssignment].self, forKey: .agentModelAssignments) {
            agentAssignments = direct
        } else {
            // Migrate the retired pool-UUID form: map each UUID → its config's (provider, model).
            let legacy = try c.decodeIfPresent([AgentRole: UUID].self, forKey: .agentAssignments) ?? [:]
            var mapped: [AgentRole: ModelAssignment] = [:]
            for (role, id) in legacy {
                guard let config = configs.first(where: { $0.id == id }) else { continue }
                mapped[role] = ModelAssignment(providerID: config.providerID, modelID: config.modelID)
            }
            agentAssignments = mapped
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(providers, forKey: .providers)
        try c.encode(providerAPIKeys, forKey: .providerAPIKeys)
        try c.encode(modelConfigurations, forKey: .modelConfigurations)
        try c.encode(agentAssignments, forKey: .agentModelAssignments)
        try c.encode(agentTuning, forKey: .agentTuning)
        try c.encode(speech, forKey: .speech)
    }
}

/// Per-agent tuning parameters that affect the agent's run loop timing.
public struct AgentTuningDefaults: Codable, Sendable {
    /// Seconds between idle poll cycles.
    public var pollInterval: TimeInterval
    /// Maximum tool calls the agent will execute per LLM response.
    public var maxToolCalls: Int
    /// Seconds of channel silence required before processing batched messages.
    public var messageDebounceInterval: TimeInterval

    public init(
        pollInterval: TimeInterval,
        maxToolCalls: Int,
        messageDebounceInterval: TimeInterval
    ) {
        self.pollInterval = pollInterval
        self.maxToolCalls = maxToolCalls
        self.messageDebounceInterval = messageDebounceInterval
    }
}

/// Sound and speech defaults for the entire application.
public struct SpeechDefaults: Codable, Sendable {
    /// Whether sound/speech is globally enabled.
    public var globalEnabled: Bool
    /// Per-agent sound/speech settings keyed by role.
    public var agents: [AgentRole: AgentSpeechDefaults]
    /// User message sound/speech settings.
    public var user: UserSpeechDefaults
    /// Narrator voice settings.
    public var narrator: NarratorDefaults
    /// Security review sounds.
    public var security: SecuritySoundDefaults

    public init(
        globalEnabled: Bool,
        agents: [AgentRole: AgentSpeechDefaults],
        user: UserSpeechDefaults,
        narrator: NarratorDefaults,
        security: SecuritySoundDefaults
    ) {
        self.globalEnabled = globalEnabled
        self.agents = agents
        self.user = user
        self.narrator = narrator
        self.security = security
    }
}

/// Per-agent speech and sound configuration.
public struct AgentSpeechDefaults: Codable, Sendable {
    /// Whether speech is enabled for this agent.
    public var enabled: Bool
    /// The voice identifier string for this agent's speech synthesis.
    public var voiceIdentifier: String
    /// Sound/speech config per category. Keys are `AgentSoundCategory` storage keys
    /// (e.g. `"toUser"`, `"toAgent"`, `"public"`, `"tool"`, `"error"`).
    public var categories: [String: SoundConfigDefaults]

    public init(
        enabled: Bool,
        voiceIdentifier: String,
        categories: [String: SoundConfigDefaults]
    ) {
        self.enabled = enabled
        self.voiceIdentifier = voiceIdentifier
        self.categories = categories
    }
}

/// Sound + speech-enable pair for a single message category.
public struct SoundConfigDefaults: Codable, Sendable {
    /// System sound name, or empty string for none.
    public var soundName: String
    /// Whether text-to-speech is enabled for this category.
    public var speakEnabled: Bool

    public init(soundName: String, speakEnabled: Bool) {
        self.soundName = soundName
        self.speakEnabled = speakEnabled
    }
}

/// User message sound/speech settings.
public struct UserSpeechDefaults: Codable, Sendable {
    /// System sound name for user messages.
    public var soundName: String
    /// Whether text-to-speech is enabled for user messages.
    public var speakEnabled: Bool
    /// Voice identifier for user speech synthesis.
    public var voiceIdentifier: String

    public init(soundName: String, speakEnabled: Bool, voiceIdentifier: String) {
        self.soundName = soundName
        self.speakEnabled = speakEnabled
        self.voiceIdentifier = voiceIdentifier
    }
}

/// Narrator voice configuration.
public struct NarratorDefaults: Codable, Sendable {
    /// Whether narrator speech is enabled.
    public var enabled: Bool
    /// Voice identifier for narrator speech synthesis.
    public var voiceIdentifier: String

    public init(enabled: Bool, voiceIdentifier: String) {
        self.enabled = enabled
        self.voiceIdentifier = voiceIdentifier
    }
}

/// Security review sound configuration.
public struct SecuritySoundDefaults: Codable, Sendable {
    /// Sound name for approved tool requests.
    public var safeSoundName: String
    /// Sound name for approved-with-warning tool requests.
    public var warnSoundName: String
    /// Sound name for denied tool requests.
    public var denySoundName: String
    /// Sound name for abort (emergency shutdown).
    public var abortSoundName: String

    public init(safeSoundName: String, warnSoundName: String, denySoundName: String, abortSoundName: String = "") {
        self.safeSoundName = safeSoundName
        self.warnSoundName = warnSoundName
        self.denySoundName = denySoundName
        self.abortSoundName = abortSoundName
    }
}
