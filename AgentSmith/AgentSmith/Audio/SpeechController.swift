import AVFoundation
import AppKit
import AgentSmithKit
import os

nonisolated private let speechLogger = Logger(subsystem: "com.agentsmith", category: "Speech")

/// A sound-effect + speech-enable pair for a single message category.
struct SoundConfig {
    var soundName: String = ""       // "" = none
    var speakEnabled: Bool = false
}

/// Manages per-agent text-to-speech synthesis and notification sounds.
///
/// Each agent gets its own `AVSpeechSynthesizer` so their utterances queue independently —
/// one agent's speech never cancels another's (but multiple agents CAN speak simultaneously).
/// Turning off global or per-agent speech immediately stops any in-progress utterances.
@Observable
@MainActor
final class SpeechController {

    // MARK: - Static config

    /// System sound names available for notifications.
    static let systemSoundNames: [String] = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"
    ]

    // MARK: - Global

    var isGloballyEnabled: Bool = false

    // MARK: - Per-agent config

    var agentEnabled: [AgentRole: Bool] = [:]
    var agentVoiceIdentifier: [AgentRole: String] = [:]

    private var agentToUser: [AgentRole: SoundConfig] = [:]
    private var agentToAgent: [AgentRole: SoundConfig] = [:]
    private var publicMessage: [AgentRole: SoundConfig] = [:]
    private var toolActivity: [AgentRole: SoundConfig] = [:]
    private var agentError: [AgentRole: SoundConfig] = [:]

    // MARK: - User config

    var userSound: SoundConfig = SoundConfig()
    var userVoiceIdentifier: String = ""

    // MARK: - Narrator config

    var narratorEnabled: Bool = false
    var narratorVoiceIdentifier: String = ""

    // MARK: - Security config

    var securitySafeSoundName: String = ""
    var securityWarnSoundName: String = ""
    var securityDenySoundName: String = ""
    var securityAbortSoundName: String = ""

    // MARK: - Private

    private var synthesizers: [AgentRole: AVSpeechSynthesizer] = [:]
    private var userSynthesizer = AVSpeechSynthesizer()
    private var narratorSynthesizer = AVSpeechSynthesizer()

    // MARK: - Init

    init() {
        for role in AgentRole.allCases {
            synthesizers[role] = AVSpeechSynthesizer()
        }
        loadSettings()
    }

    // MARK: - Message handling

    /// Call for each incoming channel message. Routes to the appropriate handler.
    func handle(_ message: ChannelMessage) {
        guard isGloballyEnabled else {
            debugLog("globally disabled (isGloballyEnabled=\(isGloballyEnabled), UD=\(String(describing: UserDefaults.standard.object(forKey: "speech.globalEnabled"))))")
            return
        }

        switch message.sender {
        case .agent(let role):
            handleAgentMessage(message, from: role)
        case .user:
            handleUserMessage(message)
        case .system:
            handleSystemMessage(message)
        }
    }

    /// Immediately stops all active and queued speech across every synthesizer.
    func stopAll() {
        for synthesizer in synthesizers.values {
            synthesizer.stopSpeaking(at: .immediate)
        }
        userSynthesizer.stopSpeaking(at: .immediate)
        narratorSynthesizer.stopSpeaking(at: .immediate)
    }

    /// Plays the named system sound for preview purposes, bypassing all enable guards.
    func previewSound(named name: String) {
        playSound(named: name)
    }

    /// Speaks a short preview sentence using the agent's configured voice.
    func previewSpeech(for role: AgentRole) {
        speak("Hello, I am Agent \(role.displayName).", for: role)
    }

    /// Speaks a short preview sentence using the user's configured voice.
    func previewUserSpeech() {
        speakWith(userSynthesizer, text: "Hello, this is the user voice.", voiceID: userVoiceIdentifier)
    }

    /// Speaks a short preview sentence using the narrator's configured voice.
    func previewNarratorSpeech() {
        speakWith(narratorSynthesizer, text: "Hello, I am the narrator.", voiceID: narratorVoiceIdentifier)
    }

    // MARK: - Per-agent sound config accessors

    func soundConfig(for role: AgentRole, category: AgentSoundCategory) -> SoundConfig {
        switch category {
        case .messageToUser: return agentToUser[role] ?? SoundConfig()
        case .agentToAgent: return agentToAgent[role] ?? SoundConfig()
        case .publicMessage: return publicMessage[role] ?? SoundConfig()
        case .toolActivity: return toolActivity[role] ?? SoundConfig()
        case .error: return agentError[role] ?? SoundConfig()
        }
    }

    func setSoundConfig(_ config: SoundConfig, for role: AgentRole, category: AgentSoundCategory) {
        let key = "speech.\(role.rawValue).\(category.storageKey)"
        switch category {
        case .messageToUser: agentToUser[role] = config
        case .agentToAgent: agentToAgent[role] = config
        case .publicMessage: publicMessage[role] = config
        case .toolActivity: toolActivity[role] = config
        case .error: agentError[role] = config
        }
        UserDefaults.standard.set(config.soundName, forKey: "\(key).sound")
        UserDefaults.standard.set(config.speakEnabled, forKey: "\(key).speak")
    }

    func setSoundName(_ name: String, for role: AgentRole, category: AgentSoundCategory) {
        var config = soundConfig(for: role, category: category)
        config.soundName = name
        setSoundConfig(config, for: role, category: category)
    }

    func setSpeakEnabled(_ enabled: Bool, for role: AgentRole, category: AgentSoundCategory) {
        var config = soundConfig(for: role, category: category)
        config.speakEnabled = enabled
        setSoundConfig(config, for: role, category: category)
    }

    // MARK: - Settings mutators

    func setGloballyEnabled(_ enabled: Bool) {
        isGloballyEnabled = enabled
        if !enabled { stopAll() }
        UserDefaults.standard.set(enabled, forKey: "speech.globalEnabled")
    }

    func setEnabled(_ enabled: Bool, for role: AgentRole) {
        agentEnabled[role] = enabled
        if !enabled { synthesizers[role]?.stopSpeaking(at: .immediate) }
        UserDefaults.standard.set(enabled, forKey: "speech.\(role.rawValue).enabled")
    }

    func setVoice(_ identifier: String, for role: AgentRole) {
        agentVoiceIdentifier[role] = identifier
        UserDefaults.standard.set(identifier, forKey: "speech.\(role.rawValue).voice")
    }

    func setUserVoice(_ identifier: String) {
        userVoiceIdentifier = identifier
        UserDefaults.standard.set(identifier, forKey: "speech.user.voice")
    }

    func setUserSound(_ config: SoundConfig) {
        userSound = config
        UserDefaults.standard.set(config.soundName, forKey: "speech.user.sound")
        UserDefaults.standard.set(config.speakEnabled, forKey: "speech.user.speak")
    }

    func setNarratorEnabled(_ enabled: Bool) {
        narratorEnabled = enabled
        if !enabled { narratorSynthesizer.stopSpeaking(at: .immediate) }
        UserDefaults.standard.set(enabled, forKey: "speech.narrator.enabled")
    }

    func setNarratorVoice(_ identifier: String) {
        narratorVoiceIdentifier = identifier
        UserDefaults.standard.set(identifier, forKey: "speech.narrator.voice")
    }

    func setSecuritySafeSound(_ name: String) {
        securitySafeSoundName = name
        UserDefaults.standard.set(name, forKey: "speech.security.safe")
    }

    func setSecurityWarnSound(_ name: String) {
        securityWarnSoundName = name
        UserDefaults.standard.set(name, forKey: "speech.security.warn")
    }

    func setSecurityDenySound(_ name: String) {
        securityDenySoundName = name
        UserDefaults.standard.set(name, forKey: "speech.security.deny")
    }

    func setSecurityAbortSound(_ name: String) {
        securityAbortSoundName = name
        UserDefaults.standard.set(name, forKey: "speech.security.abort")
    }

    // MARK: - Private: message routing

    private func handleAgentMessage(_ message: ChannelMessage, from role: AgentRole) {
        guard agentEnabled[role] == true else {
            debugLog("agent \(role.rawValue) disabled")
            return
        }

        if isToolRelated(message) {
            let config = toolActivity[role] ?? SoundConfig()
            playSound(named: config.soundName)
            debugLog("agent \(role.rawValue) tool → sound='\(config.soundName)'")
            return
        }

        if message.recipientID != nil {
            if case .user = message.recipient {
                let config = agentToUser[role] ?? SoundConfig()
                playAndSpeak(config, text: message.content, for: role)
                debugLog("agent \(role.rawValue) → user, sound='\(config.soundName)' speak=\(config.speakEnabled)")
            } else {
                let config = agentToAgent[role] ?? SoundConfig()
                playAndSpeak(config, text: message.content, for: role)
                debugLog("agent \(role.rawValue) → agent, sound='\(config.soundName)' speak=\(config.speakEnabled)")
            }
        } else {
            let config = publicMessage[role] ?? SoundConfig()
            playAndSpeak(config, text: message.content, for: role)
            debugLog("agent \(role.rawValue) public, sound='\(config.soundName)' speak=\(config.speakEnabled)")
        }
    }

    private func handleUserMessage(_ message: ChannelMessage) {
        playSound(named: userSound.soundName)
        if userSound.speakEnabled {
            speakWith(userSynthesizer, text: message.content, voiceID: userVoiceIdentifier)
        }
        debugLog("user message, sound='\(userSound.soundName)' speak=\(userSound.speakEnabled)")
    }

    private func handleSystemMessage(_ message: ChannelMessage) {
        // Security review results
        if case .string(let result) = message.metadata?["securityDisposition"] {
            // Approved tool calls are the overwhelming common case; playing a
            // "safe" sound here doesn't convey useful information to the user
            // and regularly collides with an already-playing NSSound, producing
            // "Already playing" warnings. Suppress both the sound and the log
            // line for approvals — only surface the interesting verdicts
            // (warning / denied / abort).
            guard result != "approved" else { return }
            switch result {
            case "warning":
                playSound(named: securityWarnSoundName)
            case "denied":
                playSound(named: securityDenySoundName)
            case "abort":
                playSound(named: securityAbortSoundName)
            default:
                break
            }
            debugLog("security \(result)")
            return
        }

        // Error messages with agent role metadata
        if message.metadata?["isError"] != nil,
           case .string(let roleName) = message.metadata?["agentRole"],
           let role = AgentRole(rawValue: roleName) {
            guard agentEnabled[role] == true else { return }
            let config = agentError[role] ?? SoundConfig()
            playAndSpeak(config, text: message.content, for: role)
            debugLog("error for \(role.rawValue), sound='\(config.soundName)'")
        }
    }

    // MARK: - Private helpers

    private func isToolRelated(_ message: ChannelMessage) -> Bool {
        if let mv = message.metadata?["messageKind"], case .string(let kind) = mv {
            // Only the initial tool request triggers the sound — not the tool output
            // posted after approval, which also carries metadata["tool"].
            return kind == "tool_request"
        }
        return false
    }

    /// Plays the sound and optionally speaks text using the agent's synthesizer.
    private func playAndSpeak(_ config: SoundConfig, text: String, for role: AgentRole) {
        playSound(named: config.soundName)
        if config.speakEnabled {
            speak(text, for: role)
        }
    }

    private func speak(_ text: String, for role: AgentRole) {
        guard let synthesizer = synthesizers[role] else { return }
        speakWith(synthesizer, text: text, voiceID: agentVoiceIdentifier[role] ?? "")
    }

    private func speakWith(_ synthesizer: AVSpeechSynthesizer, text: String, voiceID: String) {
        let utterance = AVSpeechUtterance(string: text)
        if !voiceID.isEmpty {
            utterance.voice = AVSpeechSynthesisVoice(identifier: voiceID)
        }
        synthesizer.speak(utterance)
    }

    private func playSound(named name: String?) {
        guard let name, !name.isEmpty else { return }
        if let sound = NSSound(named: NSSound.Name(name)) {
            sound.play()
        } else {
            let url = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
            NSSound(contentsOf: url, byReference: false)?.play()
        }
    }

    private func debugLog(_ text: String) {
        #if DEBUG
        speechLogger.debug("\(text, privacy: .public)")
        #endif
    }

    // MARK: - Persistence

    // MARK: - Bundled defaults

    /// Applies values from the bundled `defaults.json`, but only where UserDefaults
    /// has no entry. This ensures user-configured settings always win.
    func applyBundledDefaults(_ defaults: SpeechDefaults) {
        let ud = UserDefaults.standard

        if ud.object(forKey: "speech.globalEnabled") == nil {
            isGloballyEnabled = defaults.globalEnabled
        }

        for (role, agentDefaults) in defaults.agents {
            let key = role.rawValue
            if ud.object(forKey: "speech.\(key).enabled") == nil {
                agentEnabled[role] = agentDefaults.enabled
            }
            if ud.object(forKey: "speech.\(key).voice") == nil {
                agentVoiceIdentifier[role] = agentDefaults.voiceIdentifier
            }
            for category in AgentSoundCategory.allCases {
                guard let catDefaults = agentDefaults.categories[category.storageKey] else { continue }
                let catKey = "speech.\(key).\(category.storageKey)"
                var config = soundConfig(for: role, category: category)
                if ud.object(forKey: "\(catKey).sound") == nil {
                    config.soundName = catDefaults.soundName
                }
                if ud.object(forKey: "\(catKey).speak") == nil {
                    config.speakEnabled = catDefaults.speakEnabled
                }
                setSoundConfigWithoutPersisting(config, for: role, category: category)
            }
        }

        // User
        if ud.object(forKey: "speech.user.sound") == nil {
            userSound.soundName = defaults.user.soundName
        }
        if ud.object(forKey: "speech.user.speak") == nil {
            userSound.speakEnabled = defaults.user.speakEnabled
        }
        if ud.object(forKey: "speech.user.voice") == nil {
            userVoiceIdentifier = defaults.user.voiceIdentifier
        }

        // Narrator
        if ud.object(forKey: "speech.narrator.enabled") == nil {
            narratorEnabled = defaults.narrator.enabled
        }
        if ud.object(forKey: "speech.narrator.voice") == nil {
            narratorVoiceIdentifier = defaults.narrator.voiceIdentifier
        }

        // Security
        if ud.object(forKey: "speech.security.safe") == nil {
            securitySafeSoundName = defaults.security.safeSoundName
        }
        if ud.object(forKey: "speech.security.warn") == nil {
            securityWarnSoundName = defaults.security.warnSoundName
        }
        if ud.object(forKey: "speech.security.deny") == nil {
            securityDenySoundName = defaults.security.denySoundName
        }
        if ud.object(forKey: "speech.security.abort") == nil {
            securityAbortSoundName = defaults.security.abortSoundName
        }
    }

    /// Sets the in-memory sound config without writing to UserDefaults.
    /// Used by `applyBundledDefaults` to fill gaps without persisting.
    private func setSoundConfigWithoutPersisting(_ config: SoundConfig, for role: AgentRole, category: AgentSoundCategory) {
        switch category {
        case .messageToUser: agentToUser[role] = config
        case .agentToAgent: agentToAgent[role] = config
        case .publicMessage: publicMessage[role] = config
        case .toolActivity: toolActivity[role] = config
        case .error: agentError[role] = config
        }
    }

    private func loadSettings() {
        isGloballyEnabled = UserDefaults.standard.object(forKey: "speech.globalEnabled") as? Bool ?? true
        for role in AgentRole.allCases {
            let key = role.rawValue
            agentEnabled[role] = UserDefaults.standard.object(forKey: "speech.\(key).enabled") as? Bool ?? false
            agentVoiceIdentifier[role] = UserDefaults.standard.string(forKey: "speech.\(key).voice") ?? ""
            for category in AgentSoundCategory.allCases {
                let catKey = "speech.\(key).\(category.storageKey)"
                let soundName = UserDefaults.standard.string(forKey: "\(catKey).sound") ?? ""
                let speakEnabled = UserDefaults.standard.object(forKey: "\(catKey).speak") as? Bool ?? false
                let config = SoundConfig(soundName: soundName, speakEnabled: speakEnabled)
                switch category {
                case .messageToUser: agentToUser[role] = config
                case .agentToAgent: agentToAgent[role] = config
                case .publicMessage: publicMessage[role] = config
                case .toolActivity: toolActivity[role] = config
                case .error: agentError[role] = config
                }
            }
        }

        // User
        userSound.soundName = UserDefaults.standard.string(forKey: "speech.user.sound") ?? ""
        userSound.speakEnabled = UserDefaults.standard.object(forKey: "speech.user.speak") as? Bool ?? false
        userVoiceIdentifier = UserDefaults.standard.string(forKey: "speech.user.voice") ?? ""

        // Narrator
        narratorEnabled = UserDefaults.standard.object(forKey: "speech.narrator.enabled") as? Bool ?? false
        narratorVoiceIdentifier = UserDefaults.standard.string(forKey: "speech.narrator.voice") ?? ""

        // Security
        securitySafeSoundName = UserDefaults.standard.string(forKey: "speech.security.safe") ?? ""
        securityWarnSoundName = UserDefaults.standard.string(forKey: "speech.security.warn") ?? ""
        securityDenySoundName = UserDefaults.standard.string(forKey: "speech.security.deny") ?? ""
        securityAbortSoundName = UserDefaults.standard.string(forKey: "speech.security.abort") ?? ""
    }
}

// MARK: - Agent sound categories

/// Enumerates the per-agent sound/speech categories.
enum AgentSoundCategory: String, CaseIterable, Codable {
    case messageToUser
    case agentToAgent
    case publicMessage
    case toolActivity
    case error

    var displayName: String {
        switch self {
        case .messageToUser: return "Messages to user"
        case .agentToAgent: return "Agent-to-agent messages"
        case .publicMessage: return "Public messages"
        case .toolActivity: return "Tool activity"
        case .error: return "Errors"
        }
    }

    var storageKey: String {
        switch self {
        case .messageToUser: return "toUser"
        case .agentToAgent: return "toAgent"
        case .publicMessage: return "public"
        case .toolActivity: return "tool"
        case .error: return "error"
        }
    }

    /// Whether this category supports speech (some are sound-only).
    var supportsSpeech: Bool {
        switch self {
        case .toolActivity: return false
        default: return true
        }
    }
}
