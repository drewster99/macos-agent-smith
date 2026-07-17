import Foundation
import SwiftLLMKit

/// Headless capability evaluation, driven by a launch argument.
///
/// Runs in the app rather than a CLI target because the API keys live in a Keychain access group
/// tied to the app's bundle ID — a separately-signed binary can't read them, so it would have
/// nothing to call with.
///
/// What it establishes, and why each source is or isn't trusted:
/// - The **provider's own `/models` payload** is believed. It's the vendor describing its own
///   models, and it's the one source with standing to.
/// - **LiteLLM is not consulted at all.** Its capability flags are third-party claims, which is
///   the thing under test; letting them shape a probe would assume the conclusion. The probe is
///   handed an `any LLMProvider`, which carries no capability data, so this holds by construction.
/// - Everything else comes from **calling the model**.
///
/// Usage: `AgentSmith --eval-capabilities [--provider <id>] [--limit <n>] [--verbose]`
@MainActor
enum CapabilityEvalRunner {

    static let flag = "--eval-capabilities"

    static var isRequested: Bool { CommandLine.arguments.contains(flag) }

    /// Runs the evaluation and terminates the process. Never returns.
    static func runAndExit() async -> Never {
        let providerID = value(for: "--provider") ?? "builtin.anthropic"
        let limit = value(for: "--limit").flatMap { Int($0) } ?? 2
        let verbose = CommandLine.arguments.contains("--verbose")

        // Full request/response logging for every call this makes — the whole point is to be able
        // to audit what was actually sent and returned, not to trust a summary of it.
        LLMRequestLogger.logDirectoryName = "AgentSmith-CapabilityEval"
        ModelFetchService.verboseLogging = true
        ModelMetadataService.verboseLogging = true

        print("=== Capability evaluation ===")
        print("provider=\(providerID) limit=\(limit) verbose=\(verbose)")
        print("logs: \(NSTemporaryDirectory())AgentSmith-CapabilityEval/\n")

        let kit = LLMKitManager(
            appIdentifier: "com.nuclearcyborg.AgentSmith",
            keychainServicePrefix: "com.agentsmith.SwiftLLMKit"
        )
        kit.verboseLogging = true
        kit.load()

        // 1. LiteLLM metadata + a live model refresh from every configured provider. Ungated:
        //    refreshIfNeeded() would silently skip on a second run the same day, and this must
        //    always see the provider's current list.
        print("--- refreshing metadata + all provider models ---")
        await kit.refreshAllModels()

        if kit.refreshErrors.isEmpty {
            print("  no refresh errors")
        } else {
            for (name, error) in kit.refreshErrors.sorted(by: { $0.key < $1.key }) {
                print("  ERROR  \(name): \(error)")
            }
        }

        guard let provider = kit.providers.first(where: { $0.id == providerID }) else {
            print("\nFAIL: no provider '\(providerID)'. Known: \(kit.providers.map(\.id).sorted().joined(separator: ", "))")
            exit(1)
        }
        guard let key = kit.apiKey(for: providerID), !key.isEmpty else {
            print("\nFAIL: no API key for '\(providerID)' — nothing can be called.")
            exit(1)
        }
        print("  API key for \(provider.name): present (\(key.count) chars)")

        // 2. What the provider's own payload populated, and what it left empty. This is the field
        //    census: it says which facts we hold because the vendor told us, versus which are
        //    absent and would otherwise be filled by a third party's guess.
        let models = kit.models(for: providerID)
        print("\n--- \(provider.name): \(models.count) models returned ---")
        reportFieldCensus(models)

        let targets = Array(models.prefix(limit))
        print("\n--- probing \(targets.count) model(s), one at a time ---")

        var results: [CapabilityProbe.ToolCallResult] = []
        for (index, model) in targets.enumerated() {
            print("\n[\(index + 1)/\(targets.count)] \(model.modelID)")
            reportProviderClaims(model)

            // A throwaway configuration: unstreamed, capped small, never saved, and — critically —
            // never clamped against the catalog, so no LiteLLM-derived number shapes the request.
            //
            // `temperature: nil` means "omit the field entirely". It is not an oversight and must
            // not be "fixed" to a number: claude-fable-5 answers `temperature` with HTTP 400
            // ("deprecated for this model"), and we hold no behavior flag saying so. Sending it
            // made the probe record "claude-fable-5 cannot call tools" — a false negative
            // manufactured by our own request. The parameter also bought nothing: it was there for
            // determinism, and `tool_choice: required` already forces the call. Every parameter
            // sent is a way for the probe to fail for a reason that has nothing to do with what it
            // measures, so it sends the minimum: model, max_tokens, messages, tools, tool_choice.
            let config = ModelConfiguration(
                name: "probe:\(model.modelID)",
                providerID: providerID,
                modelID: model.modelID,
                temperature: nil,
                maxOutputTokens: 512,
                streaming: false
            )
            let llm = kit.makeProvider(configuration: config, provider: provider)

            let result = await CapabilityProbe.probeToolCalling(
                llm: llm, providerID: providerID, modelID: model.modelID
            )
            results.append(result)
            report(result)
        }

        print("\n=== summary ===")
        for result in results {
            let toolUse = result.toolUse.map { $0 ? "YES" : "no" } ?? "unknown"
            print("  \(result.modelID.padding(toLength: 34, withPad: " ", startingAt: 0)) toolUse=\(toolUse)  (\(result.verdict.rawValue))")
        }
        exit(results.contains { $0.verdict == .inconclusive } ? 2 : 0)
    }

    // MARK: - Reporting

    /// Which fields the provider's payload actually filled in. Absent fields are the interesting
    /// half: they're precisely where a third-party catalog would otherwise be believed.
    private static func reportFieldCensus(_ models: [ModelInfo]) {
        func count(_ label: String, _ predicate: (ModelInfo) -> Bool) {
            let n = models.filter(predicate).count
            print("  \(label.padding(toLength: 22, withPad: " ", startingAt: 0)) \(n)/\(models.count)")
        }
        count("displayName") { !$0.displayName.isEmpty && $0.displayName != $0.modelID }
        count("createdAt") { $0.createdAt != nil }
        count("maxInputTokens") { $0.maxInputTokens != nil }
        count("maxOutputTokens") { $0.maxOutputTokens != nil }
        count("pricing") { $0.pricing != nil }
        count("capabilities.vision") { $0.capabilities.vision }
        count("capabilities.toolUse") { $0.capabilities.toolUse }
        count("capabilities.pdfInput") { $0.capabilities.pdfInput }
    }

    /// The resolved catalog values, printed for contrast only — the probe never sees them. Where
    /// these disagree with the probe, the probe is the evidence and this is the claim.
    private static func reportProviderClaims(_ model: ModelInfo) {
        print("  catalog claims: toolUse=\(model.capabilities.toolUse) vision=\(model.capabilities.vision) pdfInput=\(model.capabilities.pdfInput) mode=\(model.mode ?? "unknown")")
    }

    private static func report(_ result: CapabilityProbe.ToolCallResult) {
        print("  verdict       : \(result.verdict.rawValue)")
        print("  toolUse       : \(result.toolUse.map { $0 ? "true" : "false" } ?? "unknown (nothing learned)")")
        print("  forced choice : \(result.toolChoiceForced)")
        print("  called tools  : \(result.calledTools.isEmpty ? "(none)" : result.calledTools.joined(separator: ", "))")
        print("  identifier    : expected \(result.expectedIdentifier)")
        if let text = result.returnedText {
            print("  returned text : \(text.prefix(120).replacingOccurrences(of: "\n", with: " "))")
        }
        if let error = result.errorDescription {
            print("  error         : \(error.prefix(200))")
        }
        print("  duration      : \(String(format: "%.2fs", result.duration))")
    }

    /// Reads `--name value` from the launch arguments.
    private static func value(for name: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: name),
              index + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[index + 1]
    }
}
