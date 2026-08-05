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
///     --targets <provID/model,...>  probe these instead of every catalogued model (the default)
///     --no-effort                   skip the effort-ladder probes (they are ON by default)
///     --no-seed                     probe everything even if the payload already answered it
///     --discard-non-chat            drop models the probe establishes can't chat (post-probe)
///     --discard-deprecated          skip models the provider marked deprecated (before probing)
///     --reuse-store                 seed established probed findings from the local record;
///                                   only gaps / new / version-invalidated findings re-probe
///     --reuse-max-age-days <N>      with --reuse-store, records older than N days re-probe fully (default 30)
///     --verbose                     extra request logging
///   Fetch control (compose with any launch, including a normal GUI launch):
///     --force-fetch-models          re-fetch every provider now, ignoring the daily gate
///     --no-fetch-models             never fetch; use the cached catalog
///
/// With no `--targets`, probes EVERY catalogued model across all providers (run `--list-models`
/// to see the exact IDs). Use `--targets` to narrow to specific models or a single provider.
@MainActor
enum CapabilityEvalRunner {

    static let flag = "--eval-capabilities"

    /// Any eval flag puts the app in headless mode — you shouldn't have to pair `--list-models`
    /// with `--eval-capabilities`. Either alone is enough.
    static var isRequested: Bool {
        let args = CommandLine.arguments
        return args.contains(flag) || args.contains("--list-models") || args.contains("--fetch-ollama-library")
    }

    /// A model to probe, and which effort levels to attempt for it.
    ///
    /// The list is the FULL ladder by default for every provider — Anthropic's general effort rides
    /// on `output_config.effort` and is emitted unconditionally, while elsewhere the field is
    /// flag-gated, which is why the non-Anthropic loop forces `reasoning_effort` through
    /// `extraJSONOverrides` rather than trusting a silent success.
    struct Target {
        let providerID: String
        let modelID: String
        let effortLevels: [String]
        let note: String
    }

    /// The effort levels every target is probed against — the FULL ladder unless explicitly
    /// disabled, because a probe run is meant to measure everything the vendor did not already
    /// answer. It costs nothing on a level the payload settled: the decoded ladder seeds
    /// `generalEffortLevels` / `reasoningEffortLevels` with `.decoded` findings (a KNOWN ladder
    /// states "no" for every level it omits), and both probe loops skip any level already present.
    /// So this list is the set of levels to probe only where the vendor stayed silent.
    ///
    /// `--no-effort` exists for the case where that silence covers a large sweep and the calls are
    /// not wanted right now — an opt-OUT, since the default has to be the complete measurement.
    private static var effortLevelsToProbe: [String] {
        CommandLine.arguments.contains("--no-effort") ? [] : EffortRank.allKnown
    }

    /// Every catalogued model, across all providers — the default target set when no `--targets` is
    /// given. Unconfigured / keyless providers are skipped in the probe loop (not filtered here), so
    /// this is "probe everything the catalog knows about."
    private static func allCatalogTargets(kit: LLMKitManager) -> [Target] {
        let levels = effortLevelsToProbe
        return kit.models
            .sorted { ($0.providerID, $0.modelID) < ($1.providerID, $1.modelID) }
            .map { Target(providerID: $0.providerID, modelID: $0.modelID, effortLevels: levels, note: "all catalogued models") }
    }

    /// Runs the evaluation and terminates the process. Never returns.
    static func runAndExit() async -> Never {
        if CommandLine.arguments.contains("--fetch-ollama-library") {
            await fetchOllamaLibraryAndExit()
        }
        let verbose = CommandLine.arguments.contains("--verbose")
        let noSeed = CommandLine.arguments.contains("--no-seed")
        let discardNonChat = CommandLine.arguments.contains("--discard-non-chat")
        let discardDeprecated = CommandLine.arguments.contains("--discard-deprecated")
        // Store-seeded re-sweep: reuse established, probed findings from the local record so only
        // gaps (inconclusive last time), new models, or prober-version-invalidated findings cost
        // calls. Off by default — a bare sweep is a full, honest re-measurement.
        let reuseStore = CommandLine.arguments.contains("--reuse-store")
        let reuseMaxAgeDays = argumentValue("--reuse-max-age-days").flatMap(Double.init) ?? 30
        let reuseMaxAge = reuseMaxAgeDays * 86_400

        LLMRequestLogger.logDirectoryName = "AgentSmith-CapabilityEval"
        ModelFetchService.verboseLogging = true
        ModelMetadataService.verboseLogging = true

        print("=== Capability evaluation ===")
        print("verbose: \(verbose)  discard-non-chat: \(discardNonChat)  discard-deprecated: \(discardDeprecated)")
        // Said out loud because it is now ON by default and is the largest single cost in a sweep:
        // up to one call per unstated level per model. What the payload already answered is free.
        print("effort ladders: " + (effortLevelsToProbe.isEmpty
            ? "DISABLED (--no-effort)"
            : "probing \(effortLevelsToProbe.joined(separator: "/")) where the payload is silent"))
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
        let targets = parseTargets(kit: kit) ?? allCatalogTargets(kit: kit)
        print("targets: \(targets.count)\n")
        if targets.isEmpty {
            print("No targets to probe (an explicit --targets matched no catalogued models). Nothing to do.")
            exit(0)
        }

        // Cache the freshly-decoded vendor payload per provider: a provider sweep probes many models
        // from one provider, and each seed only needs that provider's model list fetched once.
        // Tri-state facts, NOT materialized ModelInfo — materialization flattens nil to false,
        // and seeding from it fabricates decoded(false) for fields the vendor never stated.
        var decodedByProvider: [String: [DecodedModelFacts]] = [:]

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
            // makeProbeProvider, not makeProvider: necessity flags stay (a malformed request
            // must not fabricate a capability negative) but the no-temperature restriction is
            // stripped so the temperature probe measures the raw endpoint instead of trivially
            // passing under the very flag it exists to derive.
            let llm = kit.makeProbeProvider(configuration: config, provider: provider)

            // Seed from the PURE vendor payload — fetched directly, not from kit.models, whose
            // entries have LiteLLM's claims enriched in and would let third-party data wear a
            // `decoded` badge. --no-seed skips it to re-validate probe-vs-payload agreement;
            // --no-fetch-models skips it too (a bare seed means "probe everything").
            var seed = ModelProfile(providerID: target.providerID, modelID: target.modelID)
            if !noSeed && fetchPolicy != .none {
                do {
                    let decodedModels: [DecodedModelFacts]
                    if let cached = decodedByProvider[target.providerID] {
                        decodedModels = cached
                    } else {
                        decodedModels = try await ModelFetchService().fetchModelFacts(from: provider, apiKey: key.isEmpty ? nil : key)
                        decodedByProvider[target.providerID] = decodedModels
                    }
                    if let decoded = decodedModels.first(where: { $0.modelID == target.modelID }) {
                        seed = ModelProber.seedProfile(fromDecodedFacts: decoded, providerID: target.providerID)
                    }
                } catch {
                    print("  seed fetch failed (probing everything): \(error.localizedDescription)")
                }
            }

            // Store-seeded re-sweep: overlay prior probed findings onto the decoded seed, gated
            // on the SAME prober version (a bump invalidates the whole record) and a max age
            // (served models drift under fixed IDs). Carried findings keep their own evidence and
            // timestamps; only gaps re-probe.
            var reusedFindingSummary = ""
            if reuseStore {
                let (localRecord, _) = kit.probeRecords(provider: provider, modelID: target.modelID)
                if let record = localRecord {
                    let age = Date().timeIntervalSince(record.recordedAt)
                    // ONLY the current version is reusable. There was a partial-migration branch for
                    // v3 — written when 4 was current, on the basis that v3→v4 changed only the
                    // trailing-system methodology — and it survived two version bumps that
                    // explicitly invalidated everything else. v5 declared every v4 record suspect
                    // and v6 declared every v5 budget finding fabricated, so a v3 record is at
                    // least as stale as the versions those bumps rejected, yet it was the one
                    // vintage still getting a pass.
                    //
                    // It also laundered: `storeProbeResult` stamps the CURRENT prober version, so
                    // carried v3 findings were re-persisted as v6, and the evidence combiner
                    // prefers a higher prober version over a newer timestamp — letting the
                    // laundered data outrank a correct measurement.
                    if record.proberVersion != ModelProber.proberVersion {
                        reusedFindingSummary = "  reuse: SKIP — record is prober v\(record.proberVersion), current is v\(ModelProber.proberVersion); full re-probe"
                    } else if age > reuseMaxAge {
                        reusedFindingSummary = "  reuse: SKIP — record is \(Int(age / 86_400))d old (> \(Int(reuseMaxAgeDays))d); full re-probe"
                    } else {
                        seed.seedProbedFindings(from: record.profile)
                        reusedFindingSummary = "  reuse: seeded probed findings from a \(Int(age / 86_400))d-old prober-v\(record.proberVersion) record"
                    }
                } else {
                    reusedFindingSummary = "  reuse: no prior record — full probe"
                }
                print(reusedFindingSummary)
            }

            // Deprecated models are skipped BEFORE probing so no calls are spent on a model the
            // provider is retiring. The seed carries the vendor's own deprecation date.
            if discardDeprecated, let deprecatedOn = seed.deprecatedOn {
                print("  SKIP: deprecated \(Self.dateOnly.string(from: deprecatedOn))\n"); continue
            }

            // detail:'low' bills OpenAI image input at a flat ~85 tokens instead of tile math —
            // scoped to api.openai.com, the one host documented to accept the field (the vision
            // probe still retries hint-free before grading any failure, so it can't misfire).
            let preferLowImageDetail = provider.endpoint.host?.contains("api.openai.com") == true
            var profile = await ModelProber.probe(
                llm: llm, seed: seed,
                effortLevelsToProbe: target.effortLevels,
                // Anthropic emits output_config.effort whatever the model claims; a flag-gated
                // endpoint would silently drop it and turn "no error" into a false positive.
                supportsUnconditionalGeneralEffortEmission: provider.apiType == .anthropic,
                preferLowImageDetail: preferLowImageDetail,
                // The record the provider itself gates on, so the tool-calling probe can tell a
                // forced call from a free one instead of assuming tool_choice went out.
                modelCapabilities: kit.modelInfo(providerID: target.providerID,
                                                 modelID: target.modelID)?.capabilities ?? ModelCapabilities()
            )

            // An empty wallet is ACCOUNT-wide, not a fact about this model: every remaining call
            // fails identically. Left running, the sweep spends a call per model and prints one
            // indistinguishable "?" per row, burying the single fact that explains all of them —
            // and the evidence column truncates the message before the useful half. Observed live
            // on an 11-model Anthropic sweep, where the operator could not tell from the summary
            // that the account simply needed topping up. Stop, say so in full, and leave the
            // stored records alone (nothing was established, so nothing is written).
            // Scans every step-1 finding, not just `chat`. Gemini and Mistral DECODE `capabilities.chat`
            // from their /models payload, so the seed makes it `.decoded(true, "provider /models
            // payload")` and `probe()` skips the chat call entirely — the billing failure then lands
            // in `acceptsTemperature` and the breaker never fired, which is exactly the sweep-wide
            // burn its comment above says must not happen. Gemini's quota body even contains one of
            // the phrases this matches.
            let firstStepEvidence = [profile.chat, profile.acceptsTemperature, profile.isAvailable]
                .compactMap(\.evidence)
            if let billingEvidence = firstStepEvidence.first(where: CapabilityProbe.textIndicatesBillingProblem) {
                let remaining = targets.count - index - 1
                print("")
                print(String(repeating: "!", count: 100))
                print("  BILLING PROBLEM — \(target.providerID) refused the call for payment reasons.")
                print("  This says NOTHING about any model; every call fails the same way until it is resolved.")
                print("")
                print("  \(billingEvidence)")
                print("")
                if remaining > 0 {
                    print("  Stopping the sweep: \(remaining) further model(s) skipped rather than re-learning this.")
                }
                print("  Probe records are untouched — nothing was established, so nothing was written.")
                print(String(repeating: "!", count: 100))
                print("")
                profiles.append(profile)
                break
            }

            // Effort on OpenAI-compatible endpoints can't go through LLMCallOverrides — the
            // provider only emits reasoning_effort when the supportsReasoningEffort flag is set,
            // so an unflagged model silently drops it and a "no error" proves nothing. Forcing
            // the field via extraJSONOverrides bypasses the gate, making effort PROVABLE instead
            // of hand-authored: one provider per level, graded on the endpoint's own answer.
            //
            // Gated on `chat` like the battery below it. It used to sit outside that gate, which was
            // inert while effort probing was opt-in and an empty list — but once the full ladder
            // became the default it meant up to 7 paid calls each on every model `probe()` had
            // already abandoned: unavailable, access-denied, inconclusive-chat, or established
            // non-chat (embeddings, tts, whisper, babbage-002) across a ~1,700-model catalog.
            if profile.chat.value == true, provider.apiType != .anthropic, !target.effortLevels.isEmpty {
                for level in target.effortLevels where profile.reasoningEffortLevels[level] == nil {
                    let forcedConfig = ModelConfiguration(
                        name: "probe:\(target.modelID):effort", providerID: target.providerID,
                        modelID: target.modelID, temperature: nil, maxOutputTokens: 512,
                        streaming: false,
                        extraJSONOverrides: ["reasoning_effort": .string(level)]
                    )
                    let forcedLLM = kit.makeProvider(configuration: forcedConfig, provider: provider)
                    profile.reasoningEffortLevels[level] = await ModelProber.probeParameterAcceptance(
                        llm: forcedLLM,
                        parameterDescription: "reasoning_effort=\(level)",
                        rejectionKeywords: ["reasoning_effort", "reasoning", "effort"]
                    )
                    profile.callCount += 1
                }
            }

            // Capability probes that need the raw field forced past a production gate. Each is
            // gated on `chat` (a model that can't answer can't answer these either) and skipped
            // when the store already settled it, so a re-run costs nothing for known facts.
            if profile.chat.value == true {
                // The catalog entry supplies the limits that BOUND the budget search; the probed
                // values win where they exist, since they were measured on this very endpoint.
                let catalogEntry = kit.modelInfo(providerID: target.providerID, modelID: target.modelID)
                /// One throwaway provider per forced payload — the same pattern the effort probe
                /// uses, and the reason none of this needs probe-only code in the request builders.
                ///
                /// Explicitly `@MainActor`: the factory it calls is main-actor isolated, and the
                /// probes are not. Annotating the closure keeps the hop at this boundary instead of
                /// pushing the caller's isolation into the library's signature.
                let forcing: @MainActor @Sendable ([String: AnyCodable]) async -> any LLMProvider = { overrides in
                    kit.makeProvider(
                        configuration: ModelConfiguration(
                            name: "probe:\(target.modelID)", providerID: target.providerID,
                            modelID: target.modelID, temperature: nil, maxOutputTokens: 512,
                            streaming: false, extraJSONOverrides: overrides),
                        provider: provider)
                }

                // Structured output — graded on the RESPONSE, not on acceptance: an endpoint that
                // ignores response_format returns 200 and would otherwise record as supporting it.
                let structuredModes: [LLMResponseFormat] = [
                    .jsonObject,
                    .jsonSchema(name: "probe", schema: ["type": .string("object")])
                ]
                for mode in structuredModes where profile[mode.requiredCapability] == nil {
                    // nil = this provider family has no `response_format`; no call is spent.
                    guard let finding = await ModelProber.probeStructuredOutput(
                        mode, apiType: provider.apiType, makeProviderForcing: forcing) else { continue }
                    profile[mode.requiredCapability] = finding
                    profile.callCount += 1
                }

                // tool_choice options, each independently — "accepts the parameter" does not mean
                // "accepts every value of it".
                // Reasoning on/off — separate probes because neither direction implies the other.
                // Both are RUN even when one is already answered: they are read together below, and
                // a conclusion drawn from one observation and one blank would be drawn from a
                // baseline that was never measured. Only an already-answered PAIR skips.
                if profile[.reasoningCanBeEnabled] == nil || profile[.reasoningCanBeDisabled] == nil {
                    // Discovers the mechanism rather than assuming one. OpenAI, Moonshot and
                    // DeepSeek are all `.openAICompatible` and do not share a way to switch
                    // reasoning, so asking every endpoint for a `thinking` block earned OpenAI's
                    // "Unknown parameter: 'thinking'" and recorded 60+ reasoning models as unable
                    // to reason — literally what the endpoint said, and completely wrong.
                    let mechanismCalls = ProbeCallCounter()
                    let found = await ModelProber.probeReasoningMechanism(
                        apiType: provider.apiType, makeProviderForcing: forcing, calls: mechanismCalls)
                    let (on, off) = (found.on, found.off)
                    profile.callCount += mechanismCalls.value
                    // The mechanism itself is a fact worth keeping: nothing else establishes
                    // `reasoningControl`, which is why the thinking.keep probe could never fire.
                    // Only when DEMONSTRATED. A model that reasons unconditionally emits reasoning
                    // whatever it is sent, so every candidate "demonstrates" acceptance and the
                    // winner would be decided by the order of the candidate list — pinning a
                    // request-builder branch on list order and calling it established.
                    if let control = found.control, found.mechanismWasDemonstrated {
                        profile.reasoningControl = .established(
                            control, "the endpoint reasoned when asked via \(control.editorTitle)")
                    }
                    // Acceptance says the endpoint took the switch; the reply says whether it DID
                    // anything. `thinking` is an unknown key to most OpenAI-compatible endpoints and
                    // unknown keys are ignored rather than refused, so a model that carried on
                    // thinking was being recorded as one whose reasoning can be turned off.
                    let conclusions = ModelProber.concludeReasoning(on: on, off: off,
                                                                    mechanism: found.control)
                    // Never downgrade: the pair RUNS when either side is missing, so a re-run whose
                    // calls all failed (a 429 storm) would otherwise overwrite a stored established
                    // measurement with an inconclusive and re-persist the loss.
                    func keepBetter(_ capability: ModelCapability, _ candidate: ProbeFinding<Bool>) {
                        guard profile[capability]?.status != .established
                                || candidate.status == .established else { return }
                        profile[capability] = candidate
                    }
                    keepBetter(.reasoningCanBeEnabled, on.finding)
                    keepBetter(.reasoningCanBeDisabled, conclusions.canBeDisabled)
                    // Observed reasoning is the only thing that establishes the model reasons at
                    // all; a decoded vendor claim already present is left alone.
                    if profile[.reasoning] == nil, conclusions.reasons.status == .established {
                        profile[.reasoning] = conclusions.reasons
                    }
                }

                // The capability comes from the choice itself — a hand-paired list here was an
                // ARRAY literal, so a new LLMToolChoice case would break every switch loudly and
                // leave this silently one probe short.
                let toolChoices: [LLMToolChoice] = [
                    .required, .textOnly, .specific(name: CapabilityProbe.probeToolName)
                ]
                // Thinking is turned off first where the model allows it: Moonshot and DeepSeek
                // both reject `required` and named-function choices as "incompatible with thinking
                // enabled", so probing with it on measures that incompatibility rather than the
                // option. Requires the reasoning probes above to have run.
                //
                // `!= false`, NOT `== true`, and the asymmetry is load-bearing. The two outcomes are
                // not equally bad: sending the disable when it does not work costs nothing (the
                // field is ignored, which is precisely how it earned a `false`), while NOT sending
                // it when it would have worked produces a confounded tool-choice finding — the same
                // confound that cost nine findings a re-probe on 2026-08-03. So it attempts the
                // disable unless the switch is KNOWN useless. This became load-bearing when the OFF
                // verdict stopped being acceptance-graded: `inconclusive` is now a real outcome (a
                // model whose thinking only partly reduced), and under `== true` those models would
                // silently have been probed with thinking left on.
                //
                // The payload is the DISCOVERED mechanism's own, never a shape assumed for every
                // endpoint. Passing a bare Bool made the probe force `thinking: {type: disabled}`
                // at OpenAI, which has no such field: it answered "Unrecognized request argument
                // supplied: thinking", and since that names neither tool_choice nor any of its
                // values, all three findings fell through to inconclusive — 45 records locally.
                let discoveredMechanism = profile.reasoningControl?.value ?? catalogEntry?.reasoningControl
                let disablePayload = profile[.reasoningCanBeDisabled]?.value == false
                    ? nil
                    : discoveredMechanism.flatMap { $0.reasoningDisableOverrides }
                for choice in toolChoices where profile[choice.requiredCapability] == nil {
                    // The probe derives this provider's own shape; nil = no such field here.
                    guard let finding = await ModelProber.probeToolChoice(
                        choice, apiType: provider.apiType,
                        disableReasoningWith: disablePayload,
                        makeProviderForcing: forcing) else { continue }
                    profile[choice.requiredCapability] = finding
                    profile.callCount += 1
                }
                // nil unless the model's mechanism actually has a `keep` key — acceptance-grading
                // it everywhere recorded `true` on any endpoint that ignores unknown body keys.
                if profile[.thinkingSupportsKeepAll] == nil,
                   let finding = await ModelProber.probeThinkingKeep(
                       reasoningControl: catalogEntry?.reasoningControl,
                       // Measured stand-in for an undeclared mechanism: nothing decodes
                       // `reasoningControl`, so without this the probe never runs at all.
                       acceptedThinkingBlock: profile[.reasoningCanBeEnabled]?.value == true,
                       makeProviderForcing: forcing) {
                    profile[.thinkingSupportsKeepAll] = finding
                    profile.callCount += 1
                }
                // nil where the family has no `strict` concept — no call is spent there.
                if profile[.toolDefinitionsSupportStrict] == nil,
                   let strict = await ModelProber.probeStrictToolDefinitions(
                       apiType: provider.apiType, makeProviderForcing: forcing) {
                    profile[.toolDefinitionsSupportStrict] = strict
                    profile.callCount += 1
                }
                // Behaviour-graded, so each takes the ORDINARY provider rather than a forcing one:
                // what is being measured is how the endpoint treats a normal request shape, and a
                // forced body would be measuring something the production path never sends.
                if profile[.systemMessages] == nil {
                    profile[.systemMessages] = await ModelProber.probeSystemMessages(llm: llm)
                    profile.callCount += 1
                }
                if profile[.assistantPrefill] == nil {
                    profile[.assistantPrefill] = await ModelProber.probeAssistantPrefill(llm: llm)
                    profile.callCount += 1
                }
                // Needs tool calling to work at all, or it measures that instead. An established
                // non-tool-caller is skipped; an unmeasured one still gets asked.
                if profile[.parallelToolCalls] == nil, profile.toolCalling.value != false {
                    profile[.parallelToolCalls] = await ModelProber.probeParallelToolCalls(llm: llm)
                    profile.callCount += 1
                }

                // Budget range LAST: it is the only multi-call probe here, and running it after the
                // single-call facts means an interrupted sweep still banks those.
                //
                // Requires POSITIVE evidence that there is a reasoning budget to measure. The old
                // gate was `thinkingSupportsTokenBudget != false`, and nothing ever establishes that
                // capability — so it passed for every model alive. An endpoint with no budget
                // parameter ignores one silently and accepts every value, so the searches converge
                // on nonsense: on 2026-08-04 that wrote a 1-token floor and a fabricated ceiling for
                // 72 models including gpt-4-turbo and babbage-002, which have no thinking at all.
                //
                // Observed reasoning is the evidence, since a model that does not reason cannot have
                // a reasoning-token budget. A vendor claim counts too, for the models the toggle
                // probe cannot reach (OpenAI's reasoning models take `reasoning_effort`, not a
                // `thinking` block, so nothing observes their reasoning here).
                // "It reasons" is NOT sufficient on its own: OpenAI's reasoning models reason
                // demonstrably and have no token budget at all — depth there is a named effort
                // level. Gating on reasoning alone would rebuild the same 72-model bug one layer up
                // now that the mechanism probe makes those models demonstrate reasoning.
                // The mechanism gate is now MANDATORY rather than one operand of an `||`, and it
                // fails CLOSED (`?? false`). As an operand a single hand-authored
                // `thinkingSupportsTokenBudget` override on a `.reasoningEffortOnly` model bypassed
                // it entirely and re-opened the bug it names; and `?? true` let a `--reuse-store`
                // record with no stored mechanism through the same hole.
                let mechanism = profile.reasoningControl?.value ?? catalogEntry?.reasoningControl
                let reasonsDemonstrably = profile[.reasoning]?.value == true
                let vendorClaimsBudget = catalogEntry?.capabilities.state(of: .thinkingSupportsTokenBudget) == true
                // Nothing to force the budget into means nothing worth spending calls on: the
                // request would carry no budget at all and every value would "succeed", which is
                // exactly how the fabricated ceilings got written.
                if profile.maxThinkingBudgetTokens == nil,
                   profile[.thinkingSupportsTokenBudget]?.value != false,
                   reasonsDemonstrably || vendorClaimsBudget,
                   let mechanism, mechanism.carriesTokenBudget {
                    let calls = ProbeCallCounter()
                    profile.maxThinkingBudgetTokens = await ModelProber.probeThinkingBudgetRange(
                        accounting: catalogEntry?.thinkingBudgetAccounting,
                        maxOutputTokens: profile.maxOutputTokens.value ?? catalogEntry?.maxOutputTokens,
                        maxContextTokens: profile.maxContextTokens.value ?? catalogEntry?.maxInputTokens,
                        makeProviderWithBudget: { @MainActor budget, pairedMax in
                            // FORCED, like every other probe here. Through a ModelConfiguration the
                            // value is gated (no budget on the wire at all for thinking-block
                            // models) and floored (1023 became 1024), so the probe measured its own
                            // clamp rather than the model.
                            await forcing(mechanism.budgetForcingOverrides(
                                budget: budget, pairedMaxTokens: pairedMax) ?? [:])
                        },
                        calls: calls)
                    profile.callCount += calls.value

                    // The floor, searched for separately. It needs a known-accepted budget to bound
                    // the search from above, which is exactly what the range probe just established
                    // — so it runs here rather than standing alone, and is skipped when that probe
                    // found no usable range (there is nothing below zero to look for).
                    if profile.minThinkingBudgetTokens == nil,
                       let accepted = profile.maxThinkingBudgetTokens?.value, accepted > 0 {
                        let minCalls = ProbeCallCounter()
                        profile.minThinkingBudgetTokens = await ModelProber.probeThinkingBudgetMinimum(
                            knownAcceptedBudget: accepted,
                            makeProviderWithBudget: { @MainActor budget, pairedMax in
                                await forcing(mechanism.budgetForcingOverrides(
                                    budget: budget, pairedMaxTokens: pairedMax) ?? [:])
                            },
                            calls: minCalls)
                        profile.callCount += minCalls.value
                    }
                }
            }

            // Trailing {"role":"system"} steering-turn support — shared with the GUI probe via
            // TrailingSystemTurnProbe so the flag is measured identically. It runs AFTER probe()
            // returns (gated on an established chat), excludes Gemini, forces the flag on for the one
            // call, and probes the real production shape (base system + trailing turn). The helper
            // carries the full rationale.
            profile = await TrailingSystemTurnProbe.probing(profile, provider: provider,
                                                            modelID: target.modelID, kit: kit)

            // Non-chat models are dropped AFTER probing (chat is a probed result, not known up
            // front). We'll likely discard these downstream anyway; the flag makes that explicit.
            if discardNonChat, profile.chat.value == false {
                print("  DISCARD: not a chat model\n"); continue
            }

            // Persist through the SAME per-record store the GUI reads — never a private file.
            // The store rejects runs with no established probed findings (an aborted run must
            // not clobber a real record), so "skipped" here is a verdict, not an error.
            if reuseStore && profile.callCount == 0 {
                // Every finding came from the store; nothing was measured this run. Re-storing
                // would refresh recordedAt on data we didn't re-verify, so leave the record as is.
                print("  probe record unchanged (fully reused; no new measurements)")
            } else {
                do {
                    let outcome = try kit.storeProbeResult(profile: profile, provider: provider, modelID: target.modelID)
                    switch outcome {
                    case .stored:  print("  probe record stored")
                    case .pruned:  print("  stale probe record PRUNED (payload says non-chat; no capability measurement held)")
                    case .skipped: print("  probe record skipped (no established probed findings)")
                    }
                } catch {
                    print("  probe record store FAILED: \(error.localizedDescription)")
                }
            }

            profiles.append(profile)
            report(profile)
        }

        writeProfiles(profiles)
        exportProbeRecords(kit: kit)
        printSummary(profiles, kit: kit)
        exit(profiles.contains { $0.chat.status == .inconclusive } ? 2 : 0)
    }

    /// Writes the accumulated local probe store — every run ever, not just this one — in the
    /// EXACT shape the downloaded-probe slot consumes (account-scoped findings stripped). This
    /// file is the shipped-data artifact: re-probing a model updates its record in the store,
    /// and the next export reflects the full corrected set.
    private static func exportProbeRecords(kit: LLMKitManager) {
        let records = kit.exportableProbeRecords()
        guard !records.isEmpty else { return }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentSmith-CapabilityEval")
        let url = directory.appendingPathComponent("probe_records_export.json")
        do {
            // The request logger usually creates this directory as a side effect of the first
            // logged call — but a quiet run (e.g. --no-fetch-models with an early failure) may
            // never log, so ensure it exists rather than depend on the coincidence.
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(records).write(to: url, options: .atomic)
            print("  \(records.count) probe records exported (shipped format) to \(url.path)")
        } catch {
            print("  failed to export probe records: \(error)")
        }
    }

    // MARK: - Reporting

    /// What the merged catalog claims — printed only for contrast. The probe never saw this.
    private static func reportCatalogClaims(kit: LLMKitManager, target: Target) {
        guard let info = kit.modelInfo(providerID: target.providerID, modelID: target.modelID) else {
            print("  catalog: (model not in catalog)")
            return
        }
        print("  catalog: maxOut=\(info.maxOutputTokens.map(String.init) ?? "?") mode=\(info.mode ?? "?")")
        // EVERY capability the catalog states an opinion on, not a hand-picked four. Twelve of them
        // (batch, promptCaching, audioInput, videoInput, webSearch, parallelToolCalls, …) have no
        // probe and appear on no other surface, so a fixed list left them invisible everywhere —
        // there was no way to tell a vendor claiming `audioInput: false` from one that never said.
        // Tri-state, so an unstated capability is OMITTED rather than printed as false.
        let stated = ModelCapability.allCases.compactMap { capability -> String? in
            // Unprobed capabilities are flagged inline: the vendor is the ONLY source for these,
            // so a reader must not weigh them the same as a claim a probe could have overturned.
            info.capabilities.state(of: capability).map {
                "\(capability.rawValue)=\($0)" + (capability.isEmpiricallyProbed ? "" : "*")
            }
        }
        if stated.contains(where: { $0.hasSuffix("*") }) {
            print("  catalog: (* = vendor-declared only; no probe can confirm or refute it)")
        }
        for chunk in stride(from: 0, to: stated.count, by: 6).map({ Array(stated[$0..<min($0 + 6, stated.count)]) }) {
            print("  catalog: " + chunk.joined(separator: " "))
        }
        if info.generalEffort != nil || info.reasoningEffort != nil || !info.behaviorFlags.isAllDefault {
            let general = info.generalEffort.map(\.editorSummary) ?? "-"
            let reasoning = info.reasoningEffort.map(\.editorSummary) ?? "-"
            print("  catalog: generalEffort=[\(general)] reasoningEffort=[\(reasoning)] "
                  + "flags=[\(info.behaviorFlags.displayLabels.joined(separator: ","))]")
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
        // Optional (added after the first records were written), so absent on older profiles rather
        // than printing a misleading "-" that would read as "asked, no answer".
        if let trailingSystemMessage = p.trailingSystemMessage {
            line("trailingSystem", trailingSystemMessage)
        }
        line("maxContextTokens", p.maxContextTokens)
        line("maxOutputTokens", p.maxOutputTokens)
        // Iterated rather than listed one by one: a capability added later appears here with no
        // change to this function, which is the whole reason the findings live in one dictionary.
        // Sorted so two runs of the same model are diffable.
        for raw in p.capabilityFindings.keys.sorted() {
            guard let finding = p.capabilityFindings[raw] else { continue }
            line(ModelCapability(rawValue: raw)?.label ?? raw, finding)
        }
        if let budget = p.maxThinkingBudgetTokens {
            line("maxThinkBudget", budget)
        }
        if let budget = p.minThinkingBudgetTokens {
            line("minThinkBudget", budget)
        }
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
        // Reported per construct: a general-effort ladder and a reasoning-effort ladder measure
        // different parameters, so merging them into one line would misreport both.
        for (label, ladder, accepted) in [
            ("general  ", p.generalEffortLevels, p.establishedGeneralEffortLevels),
            ("reasoning", p.reasoningEffortLevels, p.establishedReasoningEffortLevels)
        ] where !ladder.isEmpty {
            let rejected = ladder.filter { $0.value.value == false }.keys.sorted()
            print("    effort \(label)   accepted=[\(accepted.joined(separator: ","))] rejected=[\(rejected.joined(separator: ","))]")
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

    private static func printSummary(_ profiles: [ModelProfile], kit: LLMKitManager) {
        print("\n" + String(repeating: "═", count: 100))
        print("SUMMARY   (yes / no = established · ? = inconclusive · - = not attempted · (parens) = vendor-declared, not measured)")
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
        /// Names the accepted members of a related set instead of one yes/no per member.
        ///
        /// Keeps the three-way distinction the single-value cells make, which a bare join would
        /// lose: "measured, none of them work" and "never asked" are different answers and must
        /// not both render as an empty cell.
        func acceptedSet(_ profile: ModelProfile,
                         _ members: [(ModelCapability, String)]) -> String {
            let findings = members.compactMap { capability, label in
                profile[capability].map { (label: label, finding: $0) }
            }
            guard !findings.isEmpty else { return "-" }
            let accepted = findings
                .filter { $0.finding.status == .established && $0.finding.value == true }
                .map(\.label)
            if !accepted.isEmpty { return accepted.joined(separator: ",") }
            return findings.contains { $0.finding.status == .established } ? "no" : "?"
        }
        func declared(for profile: ModelProfile) -> ModelInfo? {
            kit.modelInfo(providerID: profile.providerID, modelID: profile.modelID)
        }
        /// Measured ladder if we have one, else the vendor's in parens, else `-`.
        ///
        /// `.unsupported` renders "none" rather than an empty cell: a vendor saying the knob does
        /// not exist is an answer, and collapsing it into the same blank as "never asked" throws
        /// away the one state that lets a caller stop sending the field.
        func declaredOrMeasuredEffort(_ measured: [String], _ vendor: EffortSupport?) -> String {
            if !measured.isEmpty { return measured.joined(separator: ",") }
            switch vendor {
            case .levels(let ladder):        return "(\(ladder.values.joined(separator: ",")))"
            case .supportedLevelsUnknown:    return "(yes,levels?)"
            case .unsupported:               return "(none)"
            case nil:                        return "-"
            }
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
            ("trailing-system", { $0.trailingSystemMessage.map(cell) ?? "-" }),
            // Established effort levels, shallow → deep. Spelled out rather than abbreviated: the
            // whole point is which ladder rungs this model actually accepts, and "med" or "xh"
            // makes that a guess. Absent levels were never attempted, not rejected.
            //
            // Falls back to the ladder the VENDOR declares, parenthesized. A freshly probed profile
            // is seeded from the decoded payload, so a published ladder normally arrives in the
            // measured list already; the fallback covers the profile that has one and the seed did
            // not — a `--reuse-store` record written before the vendor published it, most of all.
            // Parens keep declared and measured distinguishable rather than passing one off as the
            // other.
            ("gen-effort",     { declaredOrMeasuredEffort($0.establishedGeneralEffortLevels,
                                                          declared(for: $0)?.generalEffort) }),
            ("rsn-effort",     { declaredOrMeasuredEffort($0.establishedReasoningEffortLevels,
                                                          declared(for: $0)?.reasoningEffort) }),
            // Set-valued, like the effort ladders above: the useful fact is WHICH members of the
            // set the model accepts, and one yes/no column each would add nine columns to a grid
            // that is already wide. "no" means measured-and-none-work; "?" only inconclusive;
            // "-" never attempted — the same three-way distinction the single cells make.
            ("tool-choice",    { acceptedSet($0, [(.toolChoiceSupportsValueRequired, "req"),
                                                  (.toolChoiceSupportsValueNone, "none"),
                                                  (.toolChoiceSupportsNamedFunction, "fn")]) }),
            ("structured-out", { acceptedSet($0, [(.structuredOutputSupportsJSONObject, "obj"),
                                                  (.structuredOutputSupportsJSONSchema, "schema")]) }),
            // Does it reason at all — established only by OBSERVING reasoning, so a blank means
            // undemonstrated. Distinct from the switches beside it: a thinking-only model reasons
            // and cannot be turned off, and rejecting both switches does not mean it never reasons.
            ("reasons",        { $0[.reasoning].map(cell) ?? "-" }),
            // Which mechanism the endpoint actually speaks. Discovered, not assumed — and the only
            // thing that establishes it, so a blank here means no candidate was accepted.
            ("reasoning-via",  { $0.reasoningControl?.value?.rawValue ?? "-" }),
            ("reasoning-ctl",  { acceptedSet($0, [(.reasoningCanBeEnabled, "on"),
                                                  (.reasoningCanBeDisabled, "off")]) }),
            ("strict-tools",   { $0[.toolDefinitionsSupportStrict].map(cell) ?? "-" }),
            ("system-msgs",    { $0[.systemMessages].map(cell) ?? "-" }),
            ("prefill",        { $0[.assistantPrefill].map(cell) ?? "-" }),
            // Establishes yes only — a single tool call is a model's choice, so "no" is not a
            // reachable answer here and an absent cell means undemonstrated, not incapable.
            ("parallel-tools", { $0[.parallelToolCalls].map(cell) ?? "-" }),
            ("keep-thinking",  { $0[.thinkingSupportsKeepAll].map(cell) ?? "-" }),
            ("think-budget-min", { $0.minThinkingBudgetTokens.map(intCell) ?? "-" }),
            ("think-budget-max", { $0.maxThinkingBudgetTokens.map(intCell) ?? "-" }),
            ("max-context",    { intCell($0.maxContextTokens) }),
            // maxOutputBoundedByContext is mutually exclusive with maxOutputTokens — when the
            // endpoint has no independent output cap, that one stays inconclusive and this holds
            // the governing context length. Folded into one column rather than adding a second
            // that is empty on nearly every row; "ctx-bound" says which of the two answers it is.
            ("max-output",     { profile in
                if let bounded = profile.maxOutputBoundedByContext, bounded.status == .established {
                    return "ctx-bound"
                }
                return intCell(profile.maxOutputTokens)
            }),
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
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentSmith-CapabilityEval")
        let url = directory.appendingPathComponent("profiles.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
    /// The downloaded-overrides file shape. MUST mirror BundledModelMetadataRegistry's file format
    /// — this tool round-trips the file, so any top-level key not represented here is dropped on
    /// write. Keep in sync if the registry format gains a field (currently: version, description,
    /// entries, providerEntries, providerDefaults).
    private struct OverridesFile: Codable {
        var version: Int = 2
        var description: String?
        var entries: [String: ModelMetadataOverride]?
        var providerEntries: [String: ModelMetadataOverride]?
        var providerDefaults: [String: ModelMetadataOverride]?
    }

    /// `--fetch-ollama-library`: scrapes each Ollama Cloud model's ollama.com/library page for the
    /// context window + parameter size that `/api/tags` omits, and MERGES them into
    /// `downloaded_overrides.json` as provider-scoped overrides. This is deliberately a one-shot
    /// curation tool — the app never scrapes on a normal fetch/probe; it reads these persisted,
    /// force-applied overrides. Re-run when Ollama changes a model's window (rare).
    static func fetchOllamaLibraryAndExit() async -> Never {
        LLMRequestLogger.logDirectoryName = "AgentSmith-CapabilityEval"
        let kit = LLMKitManager(appIdentifier: "com.nuclearcyborg.AgentSmith",
                                keychainServicePrefix: "com.agentsmith.SwiftLLMKit")
        kit.load()
        let providerID = "builtin.ollama-cloud"
        guard let provider = kit.providers.first(where: { $0.id == providerID }) else {
            print("Ollama Cloud provider (\(providerID)) not configured."); exit(1)
        }
        let key = kit.apiKey(for: providerID) ?? ""

        print("=== Ollama Cloud library scrape ===")
        print("Fetching cloud model list from \(provider.endpoint.absoluteString)…")
        let models: [DecodedModelFacts]
        do {
            models = try await ModelFetchService().fetchModelFacts(from: provider, apiKey: key.isEmpty ? nil : key)
        } catch {
            print("Model list fetch FAILED: \(error.localizedDescription)"); exit(1)
        }
        print("Scraping \(models.count) library pages (fail-soft per model)…\n")

        var newEntries: [String: ModelMetadataOverride] = [:]
        for model in models.sorted(by: { $0.modelID < $1.modelID }) {
            let facts = await OllamaLibraryScraper.scrape(modelID: model.modelID)
            let label = model.modelID.padding(toLength: 26, withPad: " ", startingAt: 0)
            guard !facts.isEmpty else {
                print("  \(label)  (no library data)")
                continue
            }
            var override = ModelMetadataOverride()
            override.maxInputTokens = facts.contextTokens
            override.sizeLabel = facts.sizeLabel
            newEntries["\(providerID)/\(model.modelID)"] = override
            let ctx = facts.contextTokens.map { "\($0)" } ?? "?"
            print("  \(label)  ctx=\(ctx)  size=\(facts.sizeLabel ?? "?")")
        }

        // Merge into downloaded_overrides.json: overwrite THIS provider's entries, preserve the rest.
        let baseDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwiftLLMKit/com.nuclearcyborg.AgentSmith", isDirectory: true)
        let url = baseDir.appendingPathComponent("downloaded_overrides.json")
        var file: OverridesFile
        if let data = try? Data(contentsOf: url) {
            // The file EXISTS. A decode failure here means it's corrupt or hand-edited-broken —
            // silently falling back to a blank file would wipe every other provider's overrides
            // on write. Refuse instead.
            do {
                file = try JSONDecoder().decode(OverridesFile.self, from: data)
            } catch {
                print("\nExisting \(url.lastPathComponent) is present but unreadable: \(error.localizedDescription)")
                print("Refusing to overwrite it — fix or remove the file and re-run.")
                exit(1)
            }
        } else {
            file = OverridesFile()   // absent → start fresh
        }
        var providerEntries = file.providerEntries ?? [:]
        for (modelKey, scraped) in newEntries {
            // Update ONLY the two scraped fields, preserving any hand-added pricing/flags/etc. on
            // an existing entry for this model.
            var entry = providerEntries[modelKey] ?? ModelMetadataOverride()
            entry.maxInputTokens = scraped.maxInputTokens
            entry.sizeLabel = scraped.sizeLabel
            providerEntries[modelKey] = entry
        }
        file.providerEntries = providerEntries
        file.description = file.description ?? "Downloaded/curated model-metadata overrides (App Support overlay)."

        do {
            try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(file).write(to: url, options: .atomic)
            print("\nWrote \(newEntries.count) Ollama Cloud overrides to \(url.path)")
            print("Restart the app (or refresh models) to pick them up in the downloaded-overrides layer.")
        } catch {
            print("\nWrite FAILED: \(error.localizedDescription)"); exit(1)
        }
        exit(0)
    }

    /// The value following a `--flag value` argument, or nil if the flag is absent or last.
    private static func argumentValue(_ flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag),
              index + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[index + 1]
    }

    private static func parseTargets(kit: LLMKitManager) -> [Target]? {
        guard let index = CommandLine.arguments.firstIndex(of: "--targets"),
              index + 1 < CommandLine.arguments.count else { return nil }
        let levels = effortLevelsToProbe
        return CommandLine.arguments[index + 1].split(separator: ",").flatMap { spec -> [Target] in
            let parts = spec.split(separator: "/", maxSplits: 1)
            // `split` omits empty subsequences, so a spec of "/" yields NOTHING and indexing traps.
            guard !parts.isEmpty else {
                print("  (ignoring empty --targets entry)")
                return []
            }
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
