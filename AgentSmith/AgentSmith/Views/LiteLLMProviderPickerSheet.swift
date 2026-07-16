import SwiftUI
import SwiftLLMKit

/// Chooses which `litellm_provider` a provider's models are catalogued under.
///
/// The choices come from LiteLLM's data itself rather than free text, because a value that isn't
/// present upstream can only ever resolve to nothing — and because the correct value is rarely
/// guessable (Alibaba Cloud is `dashscope`, Meta Llama is `meta_llama` with an underscore, and
/// Anthropic's models are catalogued bare under `anthropic` while every `anthropic.`-prefixed key
/// actually belongs to Bedrock).
///
/// When opened from a failing model row, the sheet leads with the providers that genuinely
/// catalogue that model — which is usually the answer.
struct LiteLLMProviderPickerSheet: View {
    @Bindable var shared: SharedAppState
    let target: MappingEditTarget
    let availableNames: [(name: String, modelCount: Int)]
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var selection: String?
    @State private var candidatesForModel: [String] = []
    @State private var searchText = ""
    @State private var saveError: String?
    @State private var showRestartNotice = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("LiteLLM Provider")
                    .font(.title3.bold())
                Text(target.provider.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let modelID = target.modelID {
                Text("Fixing metadata for \(modelID)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if !candidatesForModel.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Providers that have this model")
                        .font(.caption.bold())
                    ForEach(candidatesForModel, id: \.self) { name in
                        Button(action: { selection = name }, label: {
                            HStack {
                                Image(systemName: selection == name ? "largecircle.fill.circle" : "circle")
                                Text(name).font(.body.monospaced())
                                Spacer()
                            }
                        })
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            } else if target.modelID != nil {
                Text("No LiteLLM provider catalogues this model under this name. It may be too new, or simply absent upstream — in which case no mapping will fix it, and the capability flags can be set by hand in the model's Capabilities editor.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Text("All LiteLLM providers")
                .font(.caption.bold())
            TextField("Filter\u{2026}", text: $searchText)
                .textFieldStyle(.roundedBorder)

            List(selection: $selection) {
                // "Not mapped" is offered only where it can actually stick. A built-in whose
                // preset carries a mapping stores nil as "field absent", which seeding then
                // refills from the preset — so offering it here would silently revert on the
                // next launch. Representing "explicitly unmapped" separately from "never set"
                // needs the mapping to become an enum; until then, don't offer the dead state.
                if canUnmap {
                    Text("(not mapped \u{2014} no LiteLLM data)")
                        .foregroundStyle(.secondary)
                        .tag(String?.none)
                }
                ForEach(filteredNames, id: \.name) { entry in
                    HStack {
                        Text(entry.name).font(.body.monospaced())
                        Spacer()
                        Text("\(entry.modelCount)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    .tag(String?.some(entry.name))
                }
            }
            .frame(minHeight: 220)

            HStack {
                if let saveError {
                    Text(saveError).font(.caption).foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == target.provider.liteLLMProviderName)
            }
        }
        .padding(20)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 480)
        .task {
            selection = target.provider.liteLLMProviderName
            if let modelID = target.modelID {
                candidatesForModel = await shared.llmKit.liteLLMProviderNames(matchingModelID: modelID)
            }
        }
        .alert("Restart Required", isPresented: $showRestartNotice) {
            Button("OK") { onSaved(); dismiss() }
        } message: {
            // Deliberately does NOT offer "Refresh Models" as an alternative: that rebuilds the
            // model catalog but not `SharedAppState.pricingSnapshot`, which is only built at
            // startup — so costs would keep using the old prices while limits showed the new
            // ones. Restart is the only action that applies a remapping consistently.
            Text("The mapping was saved. The check marks below update right away, but limits, pricing, and capability flags are rebuilt at launch — restart Agent Smith to apply them.")
        }
    }

    /// Whether "not mapped" is a state this provider can actually hold. A built-in whose preset
    /// declares a mapping cannot: seeding treats a stored nil as "field absent" and refills it
    /// from the preset on the next launch.
    private var canUnmap: Bool {
        guard let preset = BuiltInProviders.preset(id: target.provider.id) else { return true }
        return preset.liteLLMProviderName == nil
    }

    private var filteredNames: [(name: String, modelCount: Int)] {
        guard !searchText.isEmpty else { return availableNames }
        return availableNames.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private func save() {
        var updated = target.provider
        updated.liteLLMProviderName = selection
        do {
            // Passing nil leaves the stored API key untouched — this edit must not disturb it.
            try shared.llmKit.updateProvider(updated, apiKey: nil)
            showRestartNotice = true
        } catch {
            saveError = error.localizedDescription
        }
    }
}
