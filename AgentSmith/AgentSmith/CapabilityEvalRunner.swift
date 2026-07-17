import Foundation
import SwiftLLMKit

/// Headless capability evaluation, driven by a launch argument.
///
/// Runs in the app rather than a CLI target because the API keys live in a Keychain access group
/// tied to the app's bundle ID — a separately-signed binary can't read them, so it would have
/// nothing to call with.
///
/// The probe never consults the catalog: it is handed an `any LLMProvider`, which carries no
/// capability data. LiteLLM's and the provider's claims are printed alongside each result purely
/// for contrast — where the probe disagrees, the probe is the evidence and the claim is the claim.
///
/// Usage:
///   AgentSmith --eval-capabilities [flags]
///     --list-models                 print every providerID/modelID that --targets accepts, then exit
///     --targets <provID/model,...>  probe these instead of the default diverse set
///     --effort                      with --targets, probe every known effort level per model
///     --no-seed                     probe everything even if the payload already answered it
///     --verbose                     extra request logging
///
/// With no `--targets`, probes a hand-picked diverse set (see `defaultTargets`): the real
/// workhorses plus deliberate false-positive cases.
@MainActor
enum CapabilityEvalRunner {

    static let flag = "--eval-capabilities"
    static var isRequested: Bool { CommandLine.arguments.contains(flag) }

    /// A model to probe, and which effort levels (if any) to attempt for it. Effort is only worth
    /// probing where the provider emits the field unconditionally (Anthropic); elsewhere the field
    /// is flag-gated and a "no error" proves nothing, so the list is empty.
    struct Target {
        let providerID: String
        let modelID: String
        let effortLevels: [String]
        let note: String
    }

    /// Diverse on purpose: two Anthropic (one with effort, one without, to see both the accept and
    /// the reject side), the two Gemini that expose the image-model false positive, the real
    /// Ollama-Cloud / z.ai workhorses that LiteLLM doesn't catalogue at all, and Grok.
    static let defaultTargets: [Target] = [
        .init(providerID: "builtin.anthropic", modelID: "claude-haiku-4-5-20251001",
              effortLevels: ["low", "high", "max"],
              note: "baseline; Anthropic's payload says NO effort — probe should see it rejected"),
        .init(providerID: "builtin.anthropic", modelID: "claude-sonnet-5",
              effortLevels: ["low", "medium", "high", "xhigh", "max"],
              note: "full effort ladder + adaptive thinking; validates probe vs payload"),
        .init(providerID: "builtin.gemini", modelID: "gemini-2.5-flash-lite",
              effortLevels: [], note: "real usage; Gemini path"),
        .init(providerID: "builtin.gemini", modelID: "gemini-2.5-flash-image",
              effortLevels: [], note: "FALSE POSITIVE: image model LiteLLM claims can call tools"),
        .init(providerID: "builtin.zai", modelID: "glm-5.2",
              effortLevels: [], note: "workhorse; LiteLLM has no data — probe is the only truth"),
        .init(providerID: "builtin.ollama-cloud", modelID: "glm-5.2",
              effortLevels: [], note: "same model, different host — compare"),
        .init(providerID: "builtin.ollama-cloud", modelID: "qwen3.5:397b",
              effortLevels: [], note: "workhorse; LiteLLM has no data"),
        .init(providerID: "builtin.xai", modelID: "grok-4.5",
              effortLevels: [], note: "real usage; xAI path"),
        .init(providerID: "builtin.openai", modelID: "gpt-5-mini",
              effortLevels: ["none", "minimal", "low", "medium", "high"],
              note: "OpenAI reasoning model — effort levels PROVEN via forced reasoning_effort"),
        .init(providerID: "builtin.openai", modelID: "gpt-4o-mini",
              effortLevels: ["low"],
              note: "OpenAI NON-reasoning model — expect reasoning_effort rejected")
    ]

    /// Runs the evaluation and terminates the process. Never returns.
    static func runAndExit() async -> Never {
        let verbose = CommandLine.arguments.contains("--verbose")
        let noSeed = CommandLine.arguments.contains("--no-seed")
        let targets = parseTargets() ?? defaultTargets

        LLMRequestLogger.logDirectoryName = "AgentSmith-CapabilityEval"
        ModelFetchService.verboseLogging = true
        ModelMetadataService.verboseLogging = true

        print("=== Capability evaluation ===")
        print("targets: \(targets.count)   verbose: \(verbose)")
        print("logs: \(NSTemporaryDirectory())AgentSmith-CapabilityEval/\n")

        let kit = LLMKitManager(appIdentifier: "com.nuclearcyborg.AgentSmith",
                                keychainServicePrefix: "com.agentsmith.SwiftLLMKit")
        kit.verboseLogging = true
        kit.load()

        print("--- refreshing metadata + all provider models (ungated) ---")
        await kit.refreshAllModels()
        if kit.refreshErrors.isEmpty {
            print("  no refresh errors")
        } else {
            for (name, error) in kit.refreshErrors.sorted(by: { $0.key < $1.key }) {
                print("  refresh error  \(name): \(error)")
            }
        }
        print()

        if CommandLine.arguments.contains("--list-models") {
            listModelsAndExit(kit: kit)
        }

        var profiles: [ModelProfile] = []
        for (index, target) in targets.enumerated() {
            print(String(repeating: "─", count: 72))
            print("[\(index + 1)/\(targets.count)] \(target.providerID) / \(target.modelID)")
            print("  intent: \(target.note)")

            guard let provider = kit.providers.first(where: { $0.id == target.providerID }) else {
                print("  SKIP: provider not configured\n"); continue
            }
            guard let key = kit.apiKey(for: target.providerID), !key.isEmpty else {
                print("  SKIP: no API key for \(provider.name)\n"); continue
            }
            reportCatalogClaims(kit: kit, target: target)

            // Throwaway config: unstreamed, small output cap, no temperature pinned, and — the
            // point — never clamped against the catalog. The provider it builds exposes no
            // capability data, so nothing the catalog claims can leak into the measurement.
            let config = ModelConfiguration(
                name: "probe:\(target.modelID)", providerID: target.providerID, modelID: target.modelID,
                temperature: nil, maxOutputTokens: 512, streaming: false
            )
            let llm = kit.makeProvider(configuration: config, provider: provider)

            // Seed from the PURE vendor payload — fetched directly, not from kit.models, whose
            // entries have LiteLLM's claims enriched in and would let third-party data wear a
            // `decoded` badge. --no-seed skips this to re-validate probe-vs-payload agreement.
            var seed = ModelProfile(providerID: target.providerID, modelID: target.modelID)
            if !noSeed {
                do {
                    let decodedModels = try await ModelFetchService().fetchModels(from: provider, apiKey: key)
                    if let decoded = decodedModels.first(where: { $0.modelID == target.modelID }) {
                        seed = ModelProber.seedProfile(fromDecoded: decoded, apiType: provider.apiType)
                    }
                } catch {
                    print("  seed fetch failed (probing everything): \(error.localizedDescription)")
                }
            }

            var profile = await ModelProber.probe(
                llm: llm, seed: seed,
                effortLevelsToProbe: provider.apiType == .anthropic ? target.effortLevels : []
            )

            // Effort on OpenAI-compatible endpoints can't go through LLMCallOverrides — the
            // provider only emits reasoning_effort when the supportsReasoningEffort flag is set,
            // so an unflagged model silently drops it and a "no error" proves nothing. Forcing
            // the field via extraJSONOverrides bypasses the gate, making effort PROVABLE instead
            // of hand-authored: one provider per level, graded on the endpoint's own answer.
            if provider.apiType != .anthropic, !target.effortLevels.isEmpty {
                for level in target.effortLevels where profile.effortLevels[level] == nil {
                    let forcedConfig = ModelConfiguration(
                        name: "probe:\(target.modelID):effort", providerID: target.providerID,
                        modelID: target.modelID, temperature: nil, maxOutputTokens: 512,
                        streaming: false,
                        extraJSONOverrides: ["reasoning_effort": .string(level)]
                    )
                    let forcedLLM = kit.makeProvider(configuration: forcedConfig, provider: provider)
                    profile.effortLevels[level] = await ModelProber.probeParameterAcceptance(
                        llm: forcedLLM,
                        parameterDescription: "reasoning_effort=\(level)",
                        rejectionKeywords: ["reasoning_effort", "reasoning", "effort"]
                    )
                    profile.callCount += 1
                }
            }

            profiles.append(profile)
            report(profile)
        }

        writeProfiles(profiles)
        printSummary(profiles)
        exit(profiles.contains { $0.chat.status == .inconclusive } ? 2 : 0)
    }

    // MARK: - Reporting

    /// What the merged catalog claims — printed only for contrast. The probe never saw this.
    private static func reportCatalogClaims(kit: LLMKitManager, target: Target) {
        guard let info = kit.modelInfo(providerID: target.providerID, modelID: target.modelID) else {
            print("  catalog: (model not in catalog)")
            return
        }
        let c = info.capabilities
        print("  catalog: toolUse=\(c.toolUse) vision=\(c.vision) pdfInput=\(c.pdfInput) reasoning=\(c.reasoning) "
              + "maxOut=\(info.maxOutputTokens.map(String.init) ?? "?") mode=\(info.mode ?? "?")")
        if !info.validEffortLevels.isEmpty || !info.behaviorFlags.isAllDefault {
            print("  catalog: effortLevels=\(info.validEffortLevels) flags=[\(info.behaviorFlags.displayLabels.joined(separator: ","))]")
        }
    }

    private static func report(_ p: ModelProfile) {
        func line(_ label: String, _ f: ProbeFinding<some Any>) {
            let v: String
            switch f.status {
            case .established:  v = "\(f.value.map { "\($0)" } ?? "?")"
            case .inconclusive: v = "inconclusive"
            case .notAttempted: v = "—"
            }
            let ev = f.evidence.map { "  (\($0.prefix(80)))" } ?? ""
            print("    \(label.padding(toLength: 18, withPad: " ", startingAt: 0)) \(v)\(ev)")
        }
        line("chat", p.chat)
        line("acceptsTemp", p.acceptsTemperature)
        line("toolCalling", p.toolCalling)
        line("toolRoundTrip", p.toolResultRoundTrip)
        line("vision", p.vision)
        line("pdfInput", p.pdfInput)
        line("maxOutputTokens", p.maxOutputTokens)
        if !p.effortLevels.isEmpty {
            let accepted = p.establishedEffortLevels
            let rejected = p.effortLevels.filter { $0.value.value == false }.keys.sorted()
            print("    effort             accepted=[\(accepted.joined(separator: ","))] rejected=[\(rejected.joined(separator: ","))]")
        }
        print("    — \(p.callCount) calls, \(String(format: "%.1fs", p.duration))")
    }

    private static func printSummary(_ profiles: [ModelProfile]) {
        print("\n" + String(repeating: "═", count: 100))
        print("SUMMARY   (yes / no = established · ? = inconclusive · - = not attempted)")
        print("")
        func cell(_ f: ProbeFinding<Bool>) -> String {
            switch f.status {
            case .established:  return f.value == true ? "yes" : "no"
            case .inconclusive: return "?"
            case .notAttempted: return "-"
            }
        }
        // Full-length column titles, each wide enough for its header and its cells.
        let columns: [(title: String, cell: (ModelProfile) -> String)] = [
            ("chat",           { cell($0.chat) }),
            ("tool-call",      { cell($0.toolCalling) }),
            ("tool-result",    { cell($0.toolResultRoundTrip) }),
            ("vision",         { cell($0.vision) }),
            ("pdf-input",      { cell($0.pdfInput) }),
            ("temperature",    { cell($0.acceptsTemperature) }),
            ("max-output",     {
                $0.maxOutputTokens.value.map(String.init)
                    ?? ($0.maxOutputTokens.status == .inconclusive ? "?" : "-")
            })
        ]
        let modelWidth = max(40, (profiles.map { $0.modelID.count }.max() ?? 0) + 2)

        func row(_ model: String, _ cells: [String]) -> String {
            var line = "  " + model.padding(toLength: modelWidth, withPad: " ", startingAt: 0)
            for (col, value) in zip(columns, cells) {
                let width = max(col.title.count, 11)
                line += value.padding(toLength: width, withPad: " ", startingAt: 0) + "  "
            }
            return line
        }

        print(row("model", columns.map(\.title)))
        for p in profiles {
            print(row(p.modelID, columns.map { $0.cell(p) }))
        }
        let calls = profiles.reduce(0) { $0 + $1.callCount }
        print("\n  \(profiles.count) models, \(calls) total API calls")
    }

    /// Prints every `providerID/modelID` that `--targets` will accept — the exact strings, one
    /// per line, grouped by provider — then exits. Providers without a key are noted (their models
    /// can't be probed), and providers that failed to refresh show nothing.
    private static func listModelsAndExit(kit: LLMKitManager) -> Never {
        print(String(repeating: "═", count: 72))
        print("AVAILABLE MODELS  (copy a providerID/modelID into --targets)")
        for provider in kit.providers.sorted(by: { $0.id < $1.id }) {
            let models = kit.models(for: provider.id)
            let hasKey = (kit.apiKey(for: provider.id)?.isEmpty == false)
            guard !models.isEmpty else { continue }
            print("\n\(provider.id)   (\(provider.name)\(hasKey ? "" : " — NO API KEY, can't probe"))  \(models.count) models")
            for model in models.sorted(by: { $0.modelID < $1.modelID }) {
                print("  \(provider.id)/\(model.modelID)")
            }
        }
        print("\nExample:")
        print("  --targets builtin.anthropic/claude-sonnet-5,builtin.openai/gpt-5-mini")
        exit(0)
    }

    private static func writeProfiles(_ profiles: [ModelProfile]) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentSmith-CapabilityEval")
            .appendingPathComponent("profiles.json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(profiles).write(to: url)
            print("\n  profiles written to \(url.path)")
        } catch {
            print("\n  failed to write profiles: \(error)")
        }
    }

    // MARK: - Args

    private static func parseTargets() -> [Target]? {
        guard let index = CommandLine.arguments.firstIndex(of: "--targets"),
              index + 1 < CommandLine.arguments.count else { return nil }
        let effort = CommandLine.arguments.contains("--effort")
        return CommandLine.arguments[index + 1].split(separator: ",").compactMap { spec in
            let parts = spec.split(separator: "/", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return Target(providerID: String(parts[0]), modelID: String(parts[1]),
                          effortLevels: effort ? EffortRank.allKnown : [], note: "cli target")
        }
    }
}
