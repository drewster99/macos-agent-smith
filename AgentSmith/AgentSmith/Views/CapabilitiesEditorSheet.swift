import SwiftUI
import SwiftLLMKit

/// Per-(provider, model) capability-flag override editor — the twin of
/// `BehaviorFlagsEditorSheet`, but for `ModelCapabilities` (vision, tool use, …).
///
/// The catalog's capability flags come from LiteLLM + provider-reported abilities, which are
/// frequently WRONG for self-hosted / cloud models (e.g. ollama-cloud reports `toolUse: false`
/// for models that clearly use tools every turn). This sheet lets the user force any flag on or
/// off per model, writing through `SharedAppState.setUserModelOverride(...)` — the same override
/// path that already persists to the user-overrides JSON and pushes into `LLMKitManager`.
///
/// Each flag is tri-state: **Default** (inherit LiteLLM/provider resolution), **Force on**,
/// **Force off**. Force values force-replace the resolved capability.
struct CapabilitiesEditorSheet: View {
    @Bindable var shared: SharedAppState
    let providerID: String
    let modelID: String

    @Environment(\.dismiss) private var dismiss

    /// Tri-state for a single capability flag. Mirrors `BehaviorFlagsEditorSheet.FlagState`.
    private enum FlagState: String, CaseIterable, Identifiable {
        case `default`, forceOn, forceOff
        var id: String { rawValue }
        var label: String {
            switch self {
            case .default: return "Default"
            case .forceOn: return "Force on"
            case .forceOff: return "Force off"
            }
        }
        init(_ optional: Bool?) {
            switch optional {
            case nil: self = .default
            case true?: self = .forceOn
            case false?: self = .forceOff
            }
        }
        var asOptional: Bool? {
            switch self {
            case .default: return nil
            case .forceOn: return true
            case .forceOff: return false
            }
        }
    }

    /// One editable capability: how to read its resolved value and how to read/write its override.
    private struct Descriptor: Identifiable {
        let id: String
        let title: String
        let description: String
        let resolved: KeyPath<ModelCapabilities, Bool>
        let override: WritableKeyPath<ModelCapabilitiesOverride, Bool?>
    }

    private static let descriptors: [Descriptor] = [
        Descriptor(id: "vision", title: "Vision (image input)",
                   description: "Model can accept images in the prompt. Off means a pasted image is rejected (HTTP 400).",
                   resolved: \.vision, override: \.vision),
        Descriptor(id: "toolUse", title: "Tool use",
                   description: "Model can call tools. Frequently mis-reported as off for cloud/self-hosted models that do support it.",
                   resolved: \.toolUse, override: \.toolUse),
        Descriptor(id: "parallelToolCalls", title: "Parallel tool calls",
                   description: "Model can emit multiple tool calls in one turn.",
                   resolved: \.parallelToolCalls, override: \.parallelToolCalls),
        Descriptor(id: "reasoning", title: "Reasoning / thinking",
                   description: "Model supports extended reasoning (thinking budget / effort).",
                   resolved: \.reasoning, override: \.reasoning),
        Descriptor(id: "pdfInput", title: "PDF input",
                   description: "Model can accept PDF documents as input.",
                   resolved: \.pdfInput, override: \.pdfInput),
        Descriptor(id: "audioInput", title: "Audio input",
                   description: "Model can accept audio as input.",
                   resolved: \.audioInput, override: \.audioInput),
        Descriptor(id: "audioOutput", title: "Audio output",
                   description: "Model can produce audio output.",
                   resolved: \.audioOutput, override: \.audioOutput),
        Descriptor(id: "videoInput", title: "Video input",
                   description: "Model can accept video as input.",
                   resolved: \.videoInput, override: \.videoInput),
        Descriptor(id: "promptCaching", title: "Prompt caching",
                   description: "Provider supports prompt/context caching for this model.",
                   resolved: \.promptCaching, override: \.promptCaching),
        Descriptor(id: "webSearch", title: "Web search",
                   description: "Model has a built-in web-search tool.",
                   resolved: \.webSearch, override: \.webSearch),
        Descriptor(id: "codeExecution", title: "Code execution",
                   description: "Model has a built-in code-execution tool.",
                   resolved: \.codeExecution, override: \.codeExecution),
        Descriptor(id: "computerUse", title: "Computer use",
                   description: "Model supports computer-use / GUI-control tooling.",
                   resolved: \.computerUse, override: \.computerUse),
        Descriptor(id: "responseSchema", title: "Response schema",
                   description: "Model supports structured-output / JSON-schema responses.",
                   resolved: \.responseSchema, override: \.responseSchema),
        Descriptor(id: "systemMessages", title: "System messages",
                   description: "Model accepts a system message (some backends fold it into the first user turn).",
                   resolved: \.systemMessages, override: \.systemMessages),
        Descriptor(id: "assistantPrefill", title: "Assistant prefill",
                   description: "Model supports prefilling the start of the assistant's reply.",
                   resolved: \.assistantPrefill, override: \.assistantPrefill),
        Descriptor(id: "toolChoice", title: "Tool choice",
                   description: "Model honors an explicit `tool_choice` selection.",
                   resolved: \.toolChoice, override: \.toolChoice)
    ]

    @State private var states: [String: FlagState] = [:]

    private var key: String { "\(providerID)/\(modelID)" }

    private var resolvedCapabilities: ModelCapabilities {
        shared.llmKit.modelInfo(providerID: providerID, modelID: modelID)?.capabilities ?? ModelCapabilities()
    }

    private var hasAnyOverride: Bool {
        states.values.contains { $0 != .default }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Model Capabilities")
                        .font(.title3.bold())
                    Text("\(providerID) — \(modelID)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") { save(); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Self.descriptors) { descriptor in
                        flagRow(descriptor)
                    }
                }
            }

            Divider()

            HStack {
                Button("Reset to defaults") {
                    for descriptor in Self.descriptors { states[descriptor.id] = .default }
                }
                .disabled(!hasAnyOverride)
                Spacer()
                Text("Default = inherit LiteLLM/provider resolution. Force on/off writes a per-model override.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 460, idealHeight: 620)
        .onAppear { loadFromShared() }
    }

    private func flagRow(_ descriptor: Descriptor) -> some View {
        let resolved = resolvedCapabilities[keyPath: descriptor.resolved]
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(descriptor.title).font(.headline)
                Spacer()
                Text("Resolved: \(resolved ? "ON" : "off")")
                    .font(.caption.monospaced())
                    .foregroundStyle(resolved ? .green : .secondary)
            }
            Text(descriptor.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker(selection: Binding(
                get: { states[descriptor.id] ?? .default },
                set: { states[descriptor.id] = $0 }
            ), label: EmptyView()) {
                ForEach(FlagState.allCases) { value in
                    Text(value.label).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private func loadFromShared() {
        let existing = shared.userModelOverrides[key]?.capabilities
        for descriptor in Self.descriptors {
            states[descriptor.id] = FlagState(existing?[keyPath: descriptor.override] ?? nil)
        }
    }

    private func save() {
        var patch = ModelCapabilitiesOverride()
        var anyForced = false
        for descriptor in Self.descriptors {
            let value = (states[descriptor.id] ?? .default).asOptional
            patch[keyPath: descriptor.override] = value
            if value != nil { anyForced = true }
        }
        // Preserve every non-capability field on the existing override; edit only `capabilities`.
        let existing = shared.userModelOverrides[key]
        let merged = ModelMetadataOverride(
            displayName: existing?.displayName,
            maxInputTokens: existing?.maxInputTokens,
            maxOutputTokens: existing?.maxOutputTokens,
            capabilities: anyForced ? patch : nil,
            pricing: existing?.pricing,
            supportsChatCompletions: existing?.supportsChatCompletions,
            behaviorFlags: existing?.behaviorFlags
        )
        shared.setUserModelOverride(providerID: providerID, modelID: modelID, override: merged)
    }
}
