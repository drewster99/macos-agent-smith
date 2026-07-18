import SwiftUI
import SwiftLLMKit

// TODO(agent-smith UI): expose recently-added ModelConfiguration fields in this editor.
//   - `thinkingEffort: String?` (swift-llm-kit 0.0.27) — picker over
//     "low"/"medium"/"high"/"xhigh"/"max" (xhigh only on Opus 4.7/4.8;
//     max only on Opus 4.5+/Sonnet 4.6+). nil = use provider default.
//   - `extraJSONOverrides: [String: AnyCodable]?` — power-user escape
//     hatch; could be a JSON text editor with validation.
//
// Until exposed, users must edit ~/Library/Application Support/agent-smith/
// <appname>/configurations.json directly to set these fields. The
// mutate-from-existing pattern in save() preserves them on edit, so
// once set via JSON they survive UI saves.
//
// (Tool choice is per-call, not per-config, so it doesn't belong here —
// it would belong on a future "agent task config" surface if/when we
// want per-task tool selection control.)

/// Sheet for creating or editing a `ModelConfiguration`.
struct ModelConfigurationEditorView: View {
    let llmKit: LLMKitManager
    let existingConfig: ModelConfiguration?
    let onSave: (ModelConfiguration) -> Void
    let onDismiss: () -> Void

    @State private var name: String = ""
    /// The auto-suggested name we last applied. While `name == autoSuggestedName` the
    /// name field is "tracking" the provider+model and refreshes when either changes.
    /// As soon as the user types something else, tracking stops until they re-match.
    @State private var autoSuggestedName: String? = nil
    @State private var selectedProviderID: String = ""
    @State private var selectedModelID: String = ""
    @State private var temperature: Double = 0.7
    @State private var maxOutputTokens: Int = 4096
    @State private var maxContextTokens: Int = 128_000
    @State private var thinkingBudget: Int = 0
    @State private var extendedCacheTTL: Bool = false
    @State private var useDefaultTemperature: Bool = false
    @State private var streaming: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existingConfig == nil ? "New Configuration" : "Edit Configuration")
                .font(.title2.bold())

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    nameSection()
                    providerSection()
                    modelSection()
                    parametersSection()
                    if selectedProviderAPIType == .anthropic || selectedProviderAPIType == .alibabaCloud {
                        thinkingSection()
                    }
                    if isAnthropicLineage {
                        cacheTTLSection()
                    }
                    streamingSection()
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(existingConfig == nil ? "Create" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty || selectedProviderID.isEmpty || selectedModelID.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 600, minHeight: 450)
        .onAppear { populateFromExisting() }
        .onChange(of: selectedProviderID) { _, _ in
            DispatchQueue.main.async { refreshAutoNameIfTracking() }
        }
        .onChange(of: selectedModelID) { _, _ in
            DispatchQueue.main.async { refreshAutoNameIfTracking() }
        }
    }

    // MARK: - Sections

    @ViewBuilder

    private func nameSection() -> some View {
        LabeledContent("Name") {
            TextField("e.g. Claude Heavy, Local Fast", text: $name)
                .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder

    private func providerSection() -> some View {
        LabeledContent("Provider") {
            Picker("", selection: $selectedProviderID) {
                Text("Select a provider...").tag("")
                ForEach(llmKit.providers) { provider in
                    Text(provider.name).tag(provider.id)
                }
            }
            .labelsHidden()
        }
    }

    @ViewBuilder

    private func modelSection() -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Model") {
                HStack(spacing: 4) {
                    TextField("model ID", text: $selectedModelID)
                        .textFieldStyle(.roundedBorder)

                    if !providerModels.isEmpty {
                        modelPickerMenu()
                    }
                }
            }

            if let info = selectedModelInfo {
                modelInfoBar(for: info)
            }
        }
    }

    /// Whether Anthropic extended thinking is active, which locks temperature to 1.0.
    /// Alibaba Cloud thinking does NOT lock temperature.
    private var isThinkingActive: Bool {
        selectedProviderAPIType == .anthropic && thinkingBudget > 0
    }

    @ViewBuilder

    private func parametersSection() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Temperature") {
                HStack {
                    Slider(value: $temperature, in: 0...2, step: 0.1)
                        .disabled(isThinkingActive || useDefaultTemperature)
                    Text(String(format: "%.1f", temperature))
                        .monospacedDigit()
                        .frame(width: 30)
                        .foregroundStyle((isThinkingActive || useDefaultTemperature) ? .secondary : .primary)
                }
            }
            .onChange(of: temperature) { _, newValue in
                // Project rule: don't mutate @State directly inside .onChange.
                if selectedProviderAPIType == .anthropic && newValue != 1.0 {
                    DispatchQueue.main.async { self.thinkingBudget = 0 }
                }
            }

            Toggle("Use model default temperature", isOn: $useDefaultTemperature)
                .font(.caption)
                .foregroundStyle(.secondary)
                .disabled(isThinkingActive)

            LabeledContent("Max Output Tokens") {
                TextField("4096", value: $maxOutputTokens, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .onChange(of: maxOutputTokens) { _, newValue in
                        // Project rule: clamp on next runloop tick.
                        if newValue < 1 {
                            DispatchQueue.main.async { self.maxOutputTokens = 1 }
                        }
                    }
            }

            LabeledContent("Max Context Tokens") {
                TextField("128000", value: $maxContextTokens, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .onChange(of: maxContextTokens) { _, newValue in
                        if newValue < 1 {
                            DispatchQueue.main.async { self.maxContextTokens = 1 }
                        }
                    }
            }
        }
    }

    @ViewBuilder

    private func thinkingSection() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Thinking Budget") {
                HStack(spacing: 8) {
                    TextField("0 = disabled", value: $thinkingBudget, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .onChange(of: thinkingBudget) { _, newValue in
                            // Project rule: defer @State mutations to next runloop tick.
                            // The clamp re-fires this onChange with the corrected value;
                            // no special atomicity is needed because this view persists
                            // via an explicit Save button (no commit-per-keystroke).
                            if newValue > 0 {
                                DispatchQueue.main.async {
                                    self.thinkingBudget = max(1024, newValue)
                                    // Anthropic requires temperature = 1.0 when thinking is enabled.
                                    if self.selectedProviderAPIType == .anthropic {
                                        self.temperature = 1.0
                                    }
                                }
                            } else if newValue < 0 {
                                DispatchQueue.main.async { self.thinkingBudget = 0 }
                            }
                        }

                    Button("1K") { thinkingBudget = 1_024 }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("4K") { thinkingBudget = 4_096 }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("16K") { thinkingBudget = 16_384 }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Off") { thinkingBudget = 0 }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            if isThinkingActive {
                Text("Thinking enabled — temperature locked to 1.0 (Anthropic requirement). Minimum budget: 1,024 tokens.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if selectedProviderAPIType == .alibabaCloud && thinkingBudget > 0 {
                Text("Thinking enabled for Alibaba Cloud (Qwen3/3.5). Minimum budget: 1,024 tokens.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("Extended thinking token budget. Set to 0 to disable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if selectedProviderAPIType == .anthropic && !isThinkingActive {
                Text("Changing temperature away from 1.0 disables thinking.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder

    private func cacheTTLSection() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Extended Prompt Cache (1 hour)", isOn: $extendedCacheTTL)
            Text("Use 1-hour cache TTL instead of the default 5-minute. Cached input tokens cost 2x the base price.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder

    private func streamingSection() -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Streaming", isOn: $streaming)
                .disabled(true)
            Text("Streaming is not yet supported.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Model Picker

    private var providerModels: [ModelInfo] {
        // Hidden is presentation, not deletion: filtered here, fully visible in the
        // Model Metadata inspector. The CURRENTLY SELECTED model is always kept even when
        // hidden — filtering it out would leave the picker unable to render its own
        // selection (a blank control), breaking existing configs visually.
        llmKit.models(for: selectedProviderID)
            .filter { $0.hidden != true || $0.modelID == selectedModelID }
    }

    private var selectedModelInfo: ModelInfo? {
        llmKit.modelInfo(providerID: selectedProviderID, modelID: selectedModelID)
    }

    private var selectedProviderAPIType: ProviderAPIType? {
        llmKit.providers.first { $0.id == selectedProviderID }?.apiType
    }

    /// True when the editor is configuring an Anthropic-lineage model — direct
    /// Anthropic provider OR an Anthropic-prefixed model routed via OpenRouter.
    /// OpenRouter passes top-level `cache_control` through to Anthropic, so the
    /// extended-cache toggle is meaningful for those configurations too.
    private var isAnthropicLineage: Bool {
        if selectedProviderAPIType == .anthropic { return true }
        if selectedProviderAPIType == .openRouter,
           selectedModelID.lowercased().hasPrefix("anthropic/") {
            return true
        }
        return false
    }

    @ViewBuilder

    private func modelPickerMenu() -> some View {
        Menu(
            content: {
                ForEach(providerModels) { model in
                    Button(action: { selectModel(model) }) {
                        modelMenuLabel(for: model)
                    }
                }
            },
            label: {
                Image(systemName: "chevron.down.circle")
                    .foregroundStyle(.secondary)
            }
        )
        .menuStyle(.borderlessButton)
        .frame(width: 24)
        .help("Select from available models")
    }

    private func modelMenuLabel(for model: ModelInfo) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(model.displayName)
                HStack(spacing: 6) {
                    if let size = model.sizeLabel {
                        Text(size).foregroundStyle(.secondary)
                    }
                    if let quant = model.quantizationLabel {
                        Text(quant).foregroundStyle(.secondary)
                    }
                    if !model.capabilities.enabledLabels.isEmpty {
                        Text(model.capabilities.enabledLabels.joined(separator: ", "))
                            .foregroundStyle(.secondary)
                    }
                    if let pricing = model.pricing, pricing.base.hasAnyRate {
                        Text(PricingFormatter.summary(pricing))
                            .foregroundStyle(.green)
                    }
                }
                .font(.caption)
            }
            Spacer()
            if model.isNew {
                Text("New")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
        }
    }

    private func modelInfoBar(for info: ModelInfo) -> some View {
        HStack(spacing: 8) {
            if let maxOut = info.maxOutputTokens {
                let exceeds = maxOutputTokens > maxOut
                Text("Max output: \(formatTokenCount(maxOut))")
                    .foregroundStyle(exceeds ? .red : .secondary)
            }
            if let maxIn = info.maxInputTokens {
                Text("Context: \(formatTokenCount(maxIn))")
                    .foregroundStyle(.secondary)
            }
            ForEach(info.capabilities.enabledLabels, id: \.self) { label in
                Text(label)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            if let pricing = info.pricing, pricing.base.hasAnyRate {
                Text(PricingFormatter.summary(pricing))
                    .foregroundStyle(.green)
            }
        }
        .font(.caption)
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Actions

    private func selectModel(_ model: ModelInfo) {
        selectedModelID = model.modelID
        // Auto-populate token limits from model info
        if let maxOut = model.maxOutputTokens {
            maxOutputTokens = maxOut
        }
        if let maxIn = model.maxInputTokens {
            maxContextTokens = maxIn
        }
        // Name auto-update is handled by .onChange(of: selectedModelID) → refreshAutoNameIfTracking().
    }

    /// Computes the auto-suggested name for the currently selected provider+model.
    /// Returns nil when the model field is empty (nothing to suggest yet).
    private func currentSuggestedName() -> String? {
        let providerName = llmKit.providers.first { $0.id == selectedProviderID }?.name
        let modelDisplay = selectedModelInfo?.displayName ?? selectedModelID
        guard !modelDisplay.isEmpty else { return nil }
        if let providerName, !providerName.isEmpty {
            return "\(providerName) — \(modelDisplay)"
        }
        return modelDisplay
    }

    /// If the user hasn't customized the name (it matches the last auto-suggestion or is
    /// empty), refresh it for the current provider+model. Always advances the tracker so
    /// the user can resume tracking by typing a name back to the new suggestion.
    private func refreshAutoNameIfTracking() {
        guard let newSuggested = currentSuggestedName() else { return }
        if name.isEmpty || name == autoSuggestedName {
            name = newSuggested
        }
        autoSuggestedName = newSuggested
    }

    private func populateFromExisting() {
        guard let config = existingConfig else { return }
        name = config.name
        selectedProviderID = config.providerID
        selectedModelID = config.modelID
        temperature = config.temperature ?? 0.7
        maxOutputTokens = config.maxOutputTokens
        maxContextTokens = config.maxContextTokens
        thinkingBudget = config.thinkingBudget ?? 0
        extendedCacheTTL = config.extendedCacheTTL
        useDefaultTemperature = config.temperature == nil
        streaming = false
        // If the loaded name still matches what we'd auto-suggest for this provider+model,
        // treat it as untouched and let it track future provider/model changes. If it
        // differs, the user customized it — leave the tracker nil so we don't overwrite.
        if let suggested = currentSuggestedName(), suggested == name {
            autoSuggestedName = suggested
        }
    }


    private func save() {
        let supportsThinking = selectedProviderAPIType == .anthropic || selectedProviderAPIType == .alibabaCloud
        let effectiveThinkingBudget: Int? = (supportsThinking && thinkingBudget > 0) ? thinkingBudget : nil

        // Mutation-from-existing pattern: start from the existing config (if
        // editing) and mutate only the fields the UI exposes. Guarantees we
        // preserve every field the UI doesn't show — including future
        // additions (thinkingEffort, extraJSONOverrides today). Rebuilding
        // from scratch via named init would silently drop them.
        //
        // useDefaultTemperature == true means "omit temperature from the
        // request entirely" — encoded in 0.0.21+ as `temperature = nil`.
        var config = existingConfig ?? ModelConfiguration(
            name: name,
            providerID: selectedProviderID,
            modelID: selectedModelID
        )
        config.name = name
        config.providerID = selectedProviderID
        config.modelID = selectedModelID
        config.temperature = useDefaultTemperature ? nil : temperature
        config.maxOutputTokens = maxOutputTokens
        config.maxContextTokens = maxContextTokens
        config.thinkingBudget = effectiveThinkingBudget
        config.extendedCacheTTL = isAnthropicLineage && extendedCacheTTL
        config.streaming = streaming
        // NOTE: thinkingEffort and extraJSONOverrides are preserved as-is
        // from the existing config (or default nil for new configs). They
        // are not yet exposed in this editor UI — users wishing to set
        // thinkingEffort or extraJSONOverrides edit Application Support
        // JSON directly.

        onSave(config)
        onDismiss()
    }
}
