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
        // claims from wearing a `decoded` badge.
        var vendorModelsByProvider: [String: [ModelInfo]] = [:]
        let fetchService = ModelFetchService()

        for target in targets {
            let stateKey = "\(target.provider.id)/\(target.modelID)"
            states[stateKey] = .probing

            var seed = ModelProfile(providerID: target.provider.id, modelID: target.modelID)
            do {
                let vendorModels: [ModelInfo]
                if let cached = vendorModelsByProvider[target.provider.id] {
                    vendorModels = cached
                } else {
                    let apiKey = kit.apiKey(for: target.provider.id)
                    vendorModels = try await fetchService.fetchModels(
                        from: target.provider,
                        apiKey: (apiKey?.isEmpty == false) ? apiKey : nil
                    )
                    vendorModelsByProvider[target.provider.id] = vendorModels
                }
                if let decoded = vendorModels.first(where: { $0.modelID == target.modelID }) {
                    seed = ModelProber.seedProfile(fromDecoded: decoded, apiType: target.provider.apiType)
                }
            } catch {
                // A failed seed fetch means probing everything — same policy as the CLI runner.
            }

            let throwawayConfig = ModelConfiguration(
                name: "probe:\(target.modelID)", providerID: target.provider.id,
                modelID: target.modelID, temperature: nil, maxOutputTokens: 512, streaming: false
            )
            let llm = kit.makeProvider(configuration: throwawayConfig, provider: target.provider)
            let profile = await ModelProber.probe(llm: llm, seed: seed)

            do {
                let stored = try kit.storeProbeResult(profile: profile, provider: target.provider, modelID: target.modelID)
                states[stateKey] = stored
                    ? .stored(callCount: profile.callCount)
                    : .skipped(reason: "no established probed findings")
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
