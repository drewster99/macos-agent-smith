import SwiftUI
import SwiftLLMKit

/// Per-(provider, model) pricing override editor — the third twin alongside
/// `BehaviorFlagsEditorSheet` and `CapabilitiesEditorSheet`.
///
/// Pricing normally arrives from the provider's `/models` payload (xAI, OpenRouter, HuggingFace)
/// or LiteLLM, but many models have neither (z.ai, Ollama Cloud) — so cost estimates silently run
/// at $0. This sheet shows what the catalog resolved and lets the user force base input/output
/// rates, entered in USD per **1M tokens** (the industry-standard quoting unit); storage stays
/// USD per single token like everything else in `ModelPricing`.
struct PricingEditorSheet: View {
    @Bindable var shared: SharedAppState
    let providerID: String
    let modelID: String

    @Environment(\.dismiss) private var dismiss

    /// USD per 1M tokens, as typed. nil/empty = no override for that rate.
    @State private var inputPerMillion: Double?
    @State private var outputPerMillion: Double?
    @State private var initialInput: Double?
    @State private var initialOutput: Double?

    private var key: String { "\(providerID)/\(modelID)" }

    private var resolvedPricing: ModelPricing? {
        shared.llmKit.modelInfo(providerID: providerID, modelID: modelID)?.pricing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pricing Override")
                .font(.title3.bold())
            Text("\(modelID) — rates in USD per 1M tokens. Overrides force-replace the catalog's pricing for cost estimates.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox("Resolved (catalog)") {
                HStack {
                    if let base = resolvedPricing?.base, base.input != nil || base.output != nil {
                        Text("Input: \(Self.perMillionLabel(base.input))")
                        Text("Output: \(Self.perMillionLabel(base.output))")
                    } else {
                        Text("No pricing known — cost estimates for this model run at $0.")
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                }
                .font(.caption)
                .padding(4)
            }

            GroupBox("Override (USD per 1M tokens)") {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Input") {
                        TextField("e.g. 3.00", value: $inputPerMillion, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)
                    }
                    LabeledContent("Output") {
                        TextField("e.g. 15.00", value: $outputPerMillion, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)
                    }
                    Button("Clear Override") {
                        inputPerMillion = nil
                        outputPerMillion = nil
                    }
                    .controlSize(.small)
                    .disabled(inputPerMillion == nil && outputPerMillion == nil)
                }
                .padding(4)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear(perform: loadFromShared)
    }

    private static func perMillionLabel(_ perToken: Double?) -> String {
        guard let perToken else { return "—" }
        return String(format: "$%.2f", perToken * 1_000_000)
    }

    private func loadFromShared() {
        let existing = shared.userModelOverrides[key]?.pricing?.base
        inputPerMillion = existing?.input.map { $0 * 1_000_000 }
        outputPerMillion = existing?.output.map { $0 * 1_000_000 }
        initialInput = inputPerMillion
        initialOutput = outputPerMillion
    }

    private func save() {
        guard inputPerMillion != initialInput || outputPerMillion != initialOutput else { return }
        var pricingOverride: ModelPricing?
        if inputPerMillion != nil || outputPerMillion != nil {
            pricingOverride = ModelPricing(base: PricingTier(
                input: inputPerMillion.map { $0 / 1_000_000 },
                output: outputPerMillion.map { $0 / 1_000_000 }
            ))
        }
        // Preserve every non-pricing field on the existing override; edit only `pricing`.
        let existing = shared.userModelOverrides[key]
        let merged = ModelMetadataOverride(
            displayName: existing?.displayName,
            maxInputTokens: existing?.maxInputTokens,
            maxOutputTokens: existing?.maxOutputTokens,
            sizeLabel: existing?.sizeLabel,
            capabilities: existing?.capabilities,
            pricing: pricingOverride,
            supportsChatCompletions: existing?.supportsChatCompletions,
            behaviorFlags: existing?.behaviorFlags,
            hidden: existing?.hidden,
            isAvailable: existing?.isAvailable,
            isAccessDenied: existing?.isAccessDenied
        )
        shared.setUserModelOverride(providerID: providerID, modelID: modelID, override: merged)
    }
}
