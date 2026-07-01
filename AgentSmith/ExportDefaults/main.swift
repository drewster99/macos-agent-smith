import Foundation
import AgentSmithKit
import SwiftLLMKit

/// CLI tool that reads the user's current AgentSmith settings and outputs a `defaults.json`
/// to stdout (or a file path passed as the first argument).
///
/// Usage:
///   ExportDefaults                              # prints to stdout
///   ExportDefaults path/to/defaults.json        # writes to file

// MARK: - Read SwiftLLMKit state

let appIdentifier = "com.nuclearcyborg.AgentSmith"

let (exportProviders, exportConfigs) = await MainActor.run {
    let kit = LLMKitManager(
        appIdentifier: appIdentifier,
        keychainServicePrefix: "com.agentsmith.SwiftLLMKit"
    )
    kit.load()
    return (kit.providers, kit.configurations)
}

// MARK: - Read UserDefaults for speech and assignment settings

let ud = UserDefaults.standard

func readBool(_ key: String, default defaultValue: Bool) -> Bool {
    ud.object(forKey: key) as? Bool ?? defaultValue
}

func readString(_ key: String) -> String {
    ud.string(forKey: key) ?? ""
}

// Agent assignments
var agentAssignments: [AgentRole: UUID] = [:]
if let data = ud.data(forKey: "agentAssignments") {
    do {
        agentAssignments = try JSONDecoder().decode([AgentRole: UUID].self, from: data)
    } catch {
        // Migration: legacy alternating array format from before CodingKeyRepresentable.
        if let array = try? JSONDecoder().decode([String].self, from: data) {
            for i in stride(from: 0, to: array.count - 1, by: 2) {
                if let role = AgentRole(rawValue: array[i]),
                   let uuid = UUID(uuidString: array[i + 1]) {
                    agentAssignments[role] = uuid
                }
            }
        } else {
            fputs("Warning: Failed to decode agent assignments: \(error)\n", stderr)
        }
    }
}

// Speech settings
let globalEnabled = readBool("speech.globalEnabled", default: true)

let categoryKeys = ["toUser", "toAgent", "public", "tool", "error"]

var agentSpeechDefaults: [AgentRole: AgentSpeechDefaults] = [:]
for role in AgentRole.allCases {
    let key = role.rawValue
    let enabled = readBool("speech.\(key).enabled", default: false)
    let voice = readString("speech.\(key).voice")

    var categories: [String: SoundConfigDefaults] = [:]
    for catKey in categoryKeys {
        let soundName = readString("speech.\(key).\(catKey).sound")
        let speakEnabled = readBool("speech.\(key).\(catKey).speak", default: false)
        categories[catKey] = SoundConfigDefaults(soundName: soundName, speakEnabled: speakEnabled)
    }

    agentSpeechDefaults[role] = AgentSpeechDefaults(
        enabled: enabled,
        voiceIdentifier: voice,
        categories: categories
    )
}

let speech = SpeechDefaults(
    globalEnabled: globalEnabled,
    agents: agentSpeechDefaults,
    user: UserSpeechDefaults(
        soundName: readString("speech.user.sound"),
        speakEnabled: readBool("speech.user.speak", default: false),
        voiceIdentifier: readString("speech.user.voice")
    ),
    narrator: NarratorDefaults(
        enabled: readBool("speech.narrator.enabled", default: false),
        voiceIdentifier: readString("speech.narrator.voice")
    ),
    security: SecuritySoundDefaults(
        safeSoundName: readString("speech.security.safe"),
        warnSoundName: readString("speech.security.warn"),
        denySoundName: readString("speech.security.deny"),
        abortSoundName: readString("speech.security.abort")
    )
)

// MARK: - Read tuning defaults

let bundledTuning: [AgentRole: AgentTuningDefaults]? = {
    let candidates: [URL] = [
        Bundle.main.url(forResource: "defaults", withExtension: "json"),
        URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("../AgentSmith.app/Contents/Resources/defaults.json")
    ].compactMap { $0 }

    for url in candidates {
        guard FileManager.default.fileExists(atPath: url.path) else { continue }
        do {
            let data = try Data(contentsOf: url)
            let defaults = try JSONDecoder().decode(AppDefaults.self, from: data)
            return defaults.agentTuning
        } catch {
            fputs("Warning: Failed to read bundled defaults from \(url.path): \(error)\n", stderr)
        }
    }
    return nil
}()

let fallbackTuning: [AgentRole: AgentTuningDefaults] = [
    .smith: AgentTuningDefaults(pollInterval: 20, maxToolCalls: 100, messageDebounceInterval: 1),
    .brown: AgentTuningDefaults(pollInterval: 25, maxToolCalls: 100, messageDebounceInterval: 1),
    .securityAgent: AgentTuningDefaults(pollInterval: 13, maxToolCalls: 100, messageDebounceInterval: 1)
]

let agentTuning = bundledTuning ?? fallbackTuning

// MARK: - Build and encode

let appDefaults = AppDefaults(
    providers: exportProviders,
    providerAPIKeys: [:],
    modelConfigurations: exportConfigs,
    agentAssignments: agentAssignments,
    agentTuning: agentTuning,
    speech: speech
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

let jsonData: Data
do {
    jsonData = try encoder.encode(appDefaults)
} catch {
    fputs("Error: Failed to encode defaults: \(error)\n", stderr)
    exit(1)
}

// MARK: - Output

if CommandLine.arguments.count > 1 {
    let outputPath = CommandLine.arguments[1]
    let outputURL = URL(fileURLWithPath: outputPath)
    do {
        try jsonData.write(to: outputURL, options: .atomic)
        fputs("Wrote defaults to \(outputURL.path)\n", stderr)
    } catch {
        fputs("Error: Failed to write to \(outputPath): \(error)\n", stderr)
        exit(1)
    }
} else {
    guard let jsonString = String(data: jsonData, encoding: .utf8) else {
        fputs("Error: Failed to convert JSON data to string\n", stderr)
        exit(1)
    }
    print(jsonString)
}
