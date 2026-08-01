import Foundation
import SwiftLLMKit

/// Runs capability probes from inside the app — the GUI counterpart of the headless
/// `--eval-capabilities` runner, sharing its rules: seed from the PURE vendor payload (never the
/// merged catalog), probe only what the seed left unknown, run serially (a capability run is not
/// a load test), and persist through the shared per-record store.
///
/// Probing is manual by design: this runs only when the user explicitly asks (Probe Now /
/// Probe Selected), never on discovery.
@MainActor
@Observable
final class ModelProbeRunner {
    /// One model's place in the current run, keyed `providerID/modelID`.
    enum TargetState: Equatable {
        case pending
        case probing
        case stored(callCount: Int)
        case skipped(reason: String)
        case failed(String)
    }

    private(set) var states: [String: TargetState] = [:]
    private(set) var isRunning = false

    /// Probes the given models serially, storing each completed run. Seeds are fetched once per
    /// provider from the vendor's own `/models` payload. Finishes by refreshing the touched
    /// providers so the merged catalog reflects the new evidence immediately.
    func probe(targets: [(provider: ModelProvider, modelID: String)], kit: LLMKitManager) async {
        guard !isRunning, !targets.isEmpty else { return }
        isRunning = true
        defer { isRunning = false }

        states = Dictionary(uniqueKeysWithValues: targets.map { ("\($0.provider.id)/\($0.modelID)", .pending) })

        // Pure vendor payloads, fetched once per provider — the seed source that keeps LiteLLM's
        // claims from wearing a `decoded` badge. Tri-state facts, not materialized ModelInfo,
        // so unstated fields stay probe-able instead of seeding a fabricated decoded(false).
        var vendorModelsByProvider: [String: [DecodedModelFacts]] = [:]
        let fetchService = ModelFetchService()

        for target in targets {
            let stateKey = "\(target.provider.id)/\(target.modelID)"
            states[stateKey] = .probing

            var seed = ModelProfile(providerID: target.provider.id, modelID: target.modelID)
            do {
                let vendorModels: [DecodedModelFacts]
                if let cached = vendorModelsByProvider[target.provider.id] {
                    vendorModels = cached
                } else {
                    let apiKey = kit.apiKey(for: target.provider.id)
                    vendorModels = try await fetchService.fetchModelFacts(
                        from: target.provider,
                        apiKey: (apiKey?.isEmpty == false) ? apiKey : nil
                    )
                    vendorModelsByProvider[target.provider.id] = vendorModels
                }
                if let decoded = vendorModels.first(where: { $0.modelID == target.modelID }) {
                    seed = ModelProber.seedProfile(fromDecodedFacts: decoded, providerID: target.provider.id)
                }
            } catch {
                // A failed seed fetch means probing everything — same policy as the CLI runner.
            }

            let throwawayConfig = ModelConfiguration(
                name: "probe:\(target.modelID)", providerID: target.provider.id,
                modelID: target.modelID, temperature: nil, maxOutputTokens: 512, streaming: false
            )
            // makeProbeProvider strips the restriction flags the probe measures (see the kit's
            // factory doc) while keeping request-forming necessity flags.
            let llm = kit.makeProbeProvider(configuration: throwawayConfig, provider: target.provider)
            let preferLowImageDetail = target.provider.endpoint.host?.contains("api.openai.com") == true
            var profile = await ModelProber.probe(llm: llm, seed: seed,
                                                  preferLowImageDetail: preferLowImageDetail)
            // Trailing-system support isn't part of ModelProber.probe() (it needs a flag-on provider,
            // which only the caller can build); run it here so the GUI probe measures it too.
            profile = await TrailingSystemTurnProbe.probing(profile, provider: target.provider,
                                                            modelID: target.modelID, kit: kit)

            do {
                let outcome = try kit.storeProbeResult(profile: profile, provider: target.provider, modelID: target.modelID)
                switch outcome {
                case .stored:  states[stateKey] = .stored(callCount: profile.callCount)
                case .pruned:  states[stateKey] = .skipped(reason: "not a chat model — stale record pruned")
                case .skipped: states[stateKey] = .skipped(reason: "no established probed findings")
                }
            } catch {
                states[stateKey] = .failed(error.localizedDescription)
            }
        }

        // One refresh per touched provider folds the new evidence into the merged catalog.
        let touchedProviderIDs = Set(targets.map(\.provider.id))
        for provider in kit.providers where touchedProviderIDs.contains(provider.id) {
            await kit.refreshModels(provider: provider)
        }
    }
}

/// The trailing-system-turn probe, shared by the GUI runner (above) and the CLI capability harness
/// so `supportsTrailingSystemMessage` is measured identically in either path.
///
/// `ModelProber.probe()` can't do this itself: it's handed a ready `llm`, but this needs a provider
/// built with the flag forced ON — on TOP of the model's other resolved flags, so request-forming
/// quirks (mustNeverSendTemperatureParam, useMaxCompletionTokens, …) still apply — so the provider's
/// own consumer emits the REAL trailing shape (base system + trailing turn). It then grades the nonce
/// echo. Forcing the flag shapes only this probe call; the persisted finding is entirely the echo.
///
/// Returns `profile` untouched when there's nothing to do: an unestablished chat, a finding already
/// known, or Gemini — whose consumer folds a trailing turn into `systemInstruction`, which would echo
/// the nonce from the top and fabricate a pass, so we leave the flag unknown rather than assert it.
enum TrailingSystemTurnProbe {
    static func probing(_ profile: ModelProfile, provider: ModelProvider, modelID: String,
                        kit: LLMKitManager) async -> ModelProfile {
        guard provider.apiType != .gemini, profile.chat.value == true,
              profile.trailingSystemMessage == nil else { return profile }
        let test = ModelProber.makeTrailingSystemTurnTest()
        // 5000 max_tokens: thinking + text share the cap on the Opus/Sonnet/Fable 5 family, and a
        // starved budget returns an empty body that misgrades as inconclusive. The reply is nine
        // chars; this is a ceiling, not an allocation, and billing follows tokens produced.
        let config = ModelConfiguration(
            name: "probe:\(modelID):trailing-system", providerID: provider.id,
            modelID: modelID, temperature: nil, maxOutputTokens: 5000, streaming: false
        )
        var flags = kit.behaviorFlags(forProviderID: provider.id, modelID: modelID)
        flags.supportsTrailingSystemMessage = true
        let llm = kit.makeProvider(configuration: config, provider: provider, behaviorFlags: flags)
        var updated = profile
        updated.trailingSystemMessage = await ModelProber.probeTrailingSystemTurn(
            llm: llm, test: test, modelID: modelID)
        updated.callCount += 1
        return updated
    }
}
