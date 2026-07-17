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
/// Usage — either `--eval-capabilities` or `--list-models` puts the app in headless mode:
///   AgentSmith --list-models                       print every providerID/modelID, then exit
///   AgentSmith --eval-capabilities [flags]
///     --targets <provID/model,...>  probe these instead of the default diverse set
///     --effort                      with --targets, probe every known effort level per model
///     --no-seed                     probe everything even if the payload already answered it
///     --discard-non-chat            drop models the probe establishes can't chat (post-probe)
///     --discard-deprecated          skip models the provider marked deprecated (before probing)
///     --verbose                     extra request logging
///   Fetch control (compose with any launch, including a normal GUI launch):
///     --force-fetch-models          re-fetch every provider now, ignoring the daily gate
///     --no-fetch-models             never fetch; use the cached catalog
///
/// With no `--targets`, probes a hand-picked diverse set (see `defaultTargets`): the real
/// workhorses plus deliberate false-positive cases.
@MainActor
enum CapabilityEvalRunner {

    static let flag = "--eval-capabilities"

    /// Any eval flag puts the app in headless mode — you shouldn't have to pair `--list-models`
    /// with `--eval-capabilities`. Either alone is enough.
    static var isRequested: Bool {
        let args = CommandLine.arguments
        return args.contains(flag) || args.contains("--list-models")
    }

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
        let discardNonChat = CommandLine.arguments.contains("--discard-non-chat")
        let discardDeprecated = CommandLine.arguments.contains("--discard-deprecated")

        LLMRequestLogger.logDirectoryName = "AgentSmith-CapabilityEval"
        ModelFetchService.verboseLogging = true
        ModelMetadataService.verboseLogging = true

        print("=== Capability evaluation ===")
        print("verbose: \(verbose)  discard-non-chat: \(discardNonChat)  discard-deprecated: \(discardDeprecated)")
        print("logs: \(NSTemporaryDirectory())AgentSmith-CapabilityEval/\n")

        let kit = LLMKitManager(appIdentifier: "com.nuclearcyborg.AgentSmith",
                                keychainServicePrefix: "com.agentsmith.SwiftLLMKit")
        kit.verboseLogging = true
        kit.load()

        // Model-list refresh follows the same policy as a normal launch: gated (once/day) by
        // default, overridable with --force-fetch-models / --no-fetch-models. This is what stops
        // every eval run from re-fetching all ~14 providers (and waiting on the unreachable ones).
        let fetchPolicy = LaunchFetchPolicy.fromArguments
        print("--- model fetch policy: \(fetchPolicy) ---")
        await fetchPolicy.apply(to: kit)
        if !kit.refreshErrors.isEmpty {
            for (name, error) in kit.refreshErrors.sorted(by: { $0.key < $1.key }) {
                print("  refresh error  \(name): \(error)")
            }
        }
        print()

        if CommandLine.arguments.contains("--list-models") {
            listModelsAndExit(kit: kit)
        }

        // Computed after the fetch so a bare-provider `--targets builtin.alibabacloud` can expand
        // against a populated catalog.
        let targets = parseTargets(kit: kit) ?? defaultTargets
        print("targets: \(targets.count)\n")
        if targets.isEmpty {
            print("No targets to probe (an explicit --targets matched no catalogued models). Nothing to do.")
            exit(0)
        }

        // Cache the freshly-decoded vendor payload per provider: a provider sweep probes many models
        // from one provider, and each seed only needs that provider's model list fetched once.
        var decodedByProvider: [String: [ModelInfo]] = [:]

        var profiles: [ModelProfile] = []
        for (index, target) in targets.enumerated() {
            print(String(repeating: "─", count: 72))
            print("[\(index + 1)/\(targets.count)] \(target.providerID) / \(target.modelID)")
            print("  intent: \(target.note)")

            guard let provider = kit.providers.first(where: { $0.id == target.providerID }) else {
                print("  SKIP: provider not configured\n"); continue
            }
            let key = kit.apiKey(for: target.providerID) ?? ""
            // A missing key only blocks a provider that needs one. Local servers (mlx, LM Studio,
            // Ollama on localhost) are keyless — probe them anyway; if the server isn't running the
            // probe reports a connection failure, which is the honest answer rather than a guess.
            if providerNeedsKey(provider) && key.isEmpty {
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
            // `decoded` badge. --no-seed skips it to re-validate probe-vs-payload agreement;
            // --no-fetch-models skips it too (a bare seed means "probe everything").
            var seed = ModelProfile(providerID: target.providerID, modelID: target.modelID)
            if !noSeed && fetchPolicy != .none {
                do {
                    let decodedModels: [ModelInfo]
                    if let cached = decodedByProvider[target.providerID] {
                        decodedModels = cached
                    } else {
                        decodedModels = try await ModelFetchService().fetchModels(from: provider, apiKey: key.isEmpty ? nil : key)
                        decodedByProvider[target.providerID] = decodedModels
                    }
                    if let decoded = decodedModels.first(where: { $0.modelID == target.modelID }) {
                        seed = ModelProber.seedProfile(fromDecoded: decoded, apiType: provider.apiType)
                    }
                } catch {
                    print("  seed fetch failed (probing everything): \(error.localizedDescription)")
                }
            }

            // Deprecated models are skipped BEFORE probing so no calls are spent on a model the
            // provider is retiring. The seed carries the vendor's own deprecation date.
            if discardDeprecated, let deprecatedOn = seed.deprecatedOn {
                print("  SKIP: deprecated \(Self.dateOnly.string(from: deprecatedOn))\n"); continue
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

            // Non-chat models are dropped AFTER probing (chat is a probed result, not known up
            // front). We'll likely discard these downstream anyway; the flag makes that explicit.
            if discardNonChat, profile.chat.value == false {
                print("  DISCARD: not a chat model\n"); continue
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
        func plain(_ label: String, _ value: String) {
            print("    \(label.padding(toLength: 18, withPad: " ", startingAt: 0)) \(value)")
        }
        line("isAvailable", p.isAvailable)
        line("isAccessDenied", p.isAccessDenied)
        line("chat", p.chat)
        line("acceptsTemp", p.acceptsTemperature)
        line("toolCalling", p.toolCalling)
        line("toolRoundTrip", p.toolResultRoundTrip)
        line("vision", p.vision)
        line("pdfInput", p.pdfInput)
        line("maxContextTokens", p.maxContextTokens)
        line("maxOutputTokens", p.maxOutputTokens)
        if let maxTemperature = p.maxTemperature {
            plain("maxTemperature", "\(maxTemperature)")
        }
        if let defaults = p.samplingDefaults, !defaults.isEmpty {
            var parts: [String] = []
            if let t = defaults.temperature { parts.append("temp \(t)") }
            if let tp = defaults.topP { parts.append("topP \(tp)") }
            if let tk = defaults.topK { parts.append("topK \(tk)") }
            if let fp = defaults.frequencyPenalty { parts.append("freqPen \(fp)") }
            if let pp = defaults.presencePenalty { parts.append("presPen \(pp)") }
            if let rp = defaults.repetitionPenalty { parts.append("repPen \(rp)") }
            plain("samplingDefaults", parts.joined(separator: ", "))
        }
        if let isFree = p.isFree {
            plain("isFree", "\(isFree)")
        }
        if let pricing = p.pricing, pricing.base.hasAnyRate {
            plain("pricing", "\(formatPrice(pricing)) (USD per 1M tokens, in/out)")
        }
        if let benchmarks = p.benchmarks, !benchmarks.isEmpty {
            var parts: [String] = []
            if let aa = benchmarks.artificialAnalysis {
                if let i = aa.intelligenceIndex { parts.append("intelligence \(i)") }
                if let c = aa.codingIndex { parts.append("coding \(c)") }
                if let a = aa.agenticIndex { parts.append("agentic \(a)") }
            }
            if let top = benchmarks.designArena?.first, let elo = top.elo {
                parts.append("elo \(Int(elo)) (\(top.arena ?? "?"))")
            }
            if !parts.isEmpty { plain("benchmarks", parts.joined(separator: ", ")) }
        }
        if let deprecatedOn = p.deprecatedOn {
            plain("deprecated", Self.dateOnly.string(from: deprecatedOn))
        }
        if !p.effortLevels.isEmpty {
            let accepted = p.establishedEffortLevels
            let rejected = p.effortLevels.filter { $0.value.value == false }.keys.sorted()
            print("    effort             accepted=[\(accepted.joined(separator: ","))] rejected=[\(rejected.joined(separator: ","))]")
        }
        print("    — \(p.callCount) calls, \(String(format: "%.1fs", p.duration))")
    }

    /// yyyy-MM-dd, for deprecation dates — the time-of-day is noise in a capability table.
    private static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Compact token counts: 131072 → "131k", 1048576 → "1.0M". Precision isn't the point in a
    /// scan-at-a-glance table; magnitude is.
    private static func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return "\(n / 1_000)k" }
        return "\(n)"
    }

    /// Base-tier input/output as USD per 1M tokens, e.g. "$1.40/$4.40". Pricing is stored per single
    /// token, so ×1e6. Output falls back to "?" when only input is known.
    private static func formatPrice(_ pricing: ModelPricing) -> String {
        let inStr = pricing.base.input.map { String(format: "$%.2f", $0 * 1_000_000) } ?? "?"
        let outStr = pricing.base.output.map { String(format: "$%.2f", $0 * 1_000_000) } ?? "?"
        return "\(inStr)/\(outStr)"
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
        func intCell(_ f: ProbeFinding<Int>) -> String {
            f.value.map(formatTokens) ?? (f.status == .inconclusive ? "?" : "-")
        }
        // Full-length column titles, each wide enough for its header and its cells.
        let columns: [(title: String, cell: (ModelProfile) -> String)] = [
            ("available",      { cell($0.isAvailable) }),
            ("access-denied",  { cell($0.isAccessDenied) }),
            ("chat",           { cell($0.chat) }),
            ("tool-call",      { cell($0.toolCalling) }),
            ("tool-result",    { cell($0.toolResultRoundTrip) }),
            ("vision",         { cell($0.vision) }),
            ("pdf-input",      { cell($0.pdfInput) }),
            ("temperature",    { cell($0.acceptsTemperature) }),
            ("max-context",    { intCell($0.maxContextTokens) }),
            ("max-output",     { intCell($0.maxOutputTokens) }),
            ("price-in/out",   { profile in
                guard let pricing = profile.pricing, pricing.base.hasAnyRate else { return "-" }
                return formatPrice(pricing)
            }),
            ("deprecated",     { $0.deprecatedOn.map { Self.dateOnly.string(from: $0) } ?? "-" })
        ]
        let modelWidth = max(40, (profiles.map { $0.modelID.count }.max() ?? 0) + 2)

        // Each column is as wide as its header OR its widest cell — never narrower, because
        // padding(toLength:) TRUNCATES an over-long string (e.g. "$15.00/$75.00" is 13 chars but a
        // fixed width-12 price column would silently drop the last digit).
        let columnWidths: [Int] = columns.map { col in
            let widestCell = profiles.map { col.cell($0).count }.max() ?? 0
            return max(col.title.count, widestCell)
        }

        func row(_ model: String, _ cells: [String]) -> String {
            var line = "  " + model.padding(toLength: modelWidth, withPad: " ", startingAt: 0)
            for (width, value) in zip(columnWidths, cells) {
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

    /// Whether a provider needs an API key to probe. The signal is the ENDPOINT HOST, not the
    /// apiType: a local server (mlx, LM Studio, Ollama on localhost) is keyless, but Ollama Cloud
    /// is the SAME `.ollama` apiType pointed at ollama.com and very much needs a key. So exempting
    /// by apiType would wrongly wave through the cloud one — check the host.
    static func providerNeedsKey(_ provider: ModelProvider) -> Bool {
        let host = provider.endpoint.host?.lowercased() ?? ""
        let localHosts: Set<String> = ["localhost", "127.0.0.1", "0.0.0.0", "::1"]
        return !(localHosts.contains(host) || host.hasSuffix(".local"))
    }

    /// Prints every `providerID/modelID` that `--targets` will accept — the exact strings, one
    /// per line, grouped by provider — then exits. A cloud provider without a key is flagged (its
    /// models can't be probed); a keyless LOCAL provider is not — it just needs to be running.
    private static func listModelsAndExit(kit: LLMKitManager) -> Never {
        print(String(repeating: "═", count: 72))
        print("AVAILABLE MODELS  (copy a providerID/modelID into --targets)")
        for provider in kit.providers.sorted(by: { $0.id < $1.id }) {
            let models = kit.models(for: provider.id)
            guard !models.isEmpty else { continue }
            let needsKey = providerNeedsKey(provider)
            let hasKey = (kit.apiKey(for: provider.id)?.isEmpty == false)
            let note: String
            if needsKey && !hasKey {
                note = " — NO API KEY, can't probe"
            } else if !needsKey {
                note = " — local, no key needed (must be running)"
            } else {
                note = ""
            }
            print("\n\(provider.id)   (\(provider.name)\(note))  \(models.count) models")
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

    /// Parses `--targets`. Each comma-separated spec is either `providerID/modelID` (one model) or a
    /// bare `providerID` (every model that provider currently lists in the catalog) — the latter so
    /// you can sweep, say, all of Alibaba Cloud without hand-listing model IDs. Returns nil when
    /// `--targets` is absent, so the caller falls back to the diverse default set.
    private static func parseTargets(kit: LLMKitManager) -> [Target]? {
        guard let index = CommandLine.arguments.firstIndex(of: "--targets"),
              index + 1 < CommandLine.arguments.count else { return nil }
        let effort = CommandLine.arguments.contains("--effort")
        let levels = effort ? EffortRank.allKnown : []
        return CommandLine.arguments[index + 1].split(separator: ",").flatMap { spec -> [Target] in
            let parts = spec.split(separator: "/", maxSplits: 1)
            if parts.count == 2 {
                return [Target(providerID: String(parts[0]), modelID: String(parts[1]),
                               effortLevels: levels, note: "cli target")]
            }
            // Bare provider ID: expand to every model the catalog lists for it.
            let providerID = String(parts[0])
            let models = kit.models(for: providerID).sorted { $0.modelID < $1.modelID }
            if models.isEmpty {
                print("  (no catalogued models for \(providerID) — nothing to expand)")
            }
            return models.map {
                Target(providerID: providerID, modelID: $0.modelID,
                       effortLevels: levels, note: "cli target (provider sweep)")
            }
        }
    }
}
