import SwiftUI
import SwiftLLMKit

/// Per-(provider, model) capability-flag and status override editor — the twin of
/// `BehaviorFlagsEditorSheet`, but for `ModelCapabilities` (vision, tool use, …) plus the
/// top-level status fields (`hidden`, `isAvailable`, `isAccessDenied`,
/// `supportsChatCompletions`) and the display-name override.
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
        Descriptor(id: "toolResultRoundTrip", title: "Tool result round-trip",
                   description: "Model consumes tool RESULTS, not just emits calls — the half an agent depends on. Probe-established; force only to correct a stale verdict.",
                   resolved: \.toolResultRoundTrip, override: \.toolResultRoundTrip),
        Descriptor(id: "toolChoice", title: "Tool choice",
                   description: "Model honors an explicit `tool_choice` selection.",
                   resolved: \.toolChoice, override: \.toolChoice)
    ]

    /// One editable model-status field. These live at the top level of `ModelMetadataOverride`
    /// (not inside the capabilities container) and their resolved values are tri-state on
    /// `ModelInfo` — nil means "no source has said", which the row surfaces as "unknown".
    private struct StatusDescriptor: Identifiable {
        let id: String
        let title: String
        let description: String
        let resolved: (ModelInfo?) -> Bool?
        let override: WritableKeyPath<ModelMetadataOverride, Bool?>
    }

    private static let statusDescriptors: [StatusDescriptor] = [
        StatusDescriptor(id: "hidden", title: "Hidden",
                         description: "Hide this model from configuration pickers. Presentation only — nothing is deleted, and un-hiding is just clearing this.",
                         resolved: { $0?.hidden }, override: \.hidden),
        StatusDescriptor(id: "isAvailable", title: "Available",
                         description: "Whether the model actually answers. Probes set this empirically; force it to correct a stale verdict (e.g. a model that came back to life).",
                         resolved: { $0?.isAvailable }, override: \.isAvailable),
        StatusDescriptor(id: "isAccessDenied", title: "Access denied",
                         description: "Whether YOUR account/key is denied for this model. Account-scoped — force off after a plan change un-denies you.",
                         resolved: { $0?.isAccessDenied }, override: \.isAccessDenied),
        StatusDescriptor(id: "supportsChatCompletions", title: "Chat completions",
                         description: "Model serves the chat-completions surface Agent Smith talks to. Off means it's responses-/embeddings-only.",
                         resolved: { $0?.supportsChatCompletions }, override: \.supportsChatCompletions)
    ]

    @State private var states: [String: FlagState] = [:]
    /// The override selections as they stood when the sheet opened, so Done can tell whether
    /// anything actually changed (and only then surface the restart notice).
    @State private var initialStates: [String: FlagState] = [:]
    /// Display-name override as typed; empty = no override.
    @State private var displayNameOverride: String = ""
    @State private var initialDisplayNameOverride: String = ""
    @State private var showRestartNotice = false

    private var key: String { "\(providerID)/\(modelID)" }

    private var resolvedModelInfo: ModelInfo? {
        shared.llmKit.modelInfo(providerID: providerID, modelID: modelID)
    }

    private var resolvedCapabilities: ModelCapabilities {
        resolvedModelInfo?.capabilities ?? ModelCapabilities()
    }

    private var hasAnyOverride: Bool {
        states.values.contains { $0 != .default } || !displayNameOverride.isEmpty
    }

    /// The typed display-name override, normalized: whitespace-trimmed, empty → nil.
    private var trimmedDisplayNameOverride: String? {
        let trimmed = displayNameOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Model Capabilities & Status")
                        .font(.title3.bold())
                    Text("\(providerID) — \(modelID)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") { commit() }
                    .keyboardShortcut(.defaultAction)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sectionHeader("Capabilities")
                    ForEach(Self.descriptors) { descriptor in
                        flagRow(descriptor)
                    }

                    Divider().padding(.vertical, 4)

                    sectionHeader("Status & Identity")
                    displayNameRow
                    ForEach(Self.statusDescriptors) { descriptor in
                        statusRow(descriptor)
                    }
                }
            }

            Divider()

            HStack {
                Button("Reset to defaults") {
                    for descriptor in Self.descriptors { states[descriptor.id] = .default }
                    for descriptor in Self.statusDescriptors { states[descriptor.id] = .default }
                    displayNameOverride = ""
                }
                .disabled(!hasAnyOverride)
                Spacer()
                Text("Default = inherit LiteLLM/provider resolution. Force on/off writes a per-model override. Takes effect after you restart Agent Smith.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 460, idealHeight: 620)
        .onAppear { loadFromShared() }
        .alert("Restart Required", isPresented: $showRestartNotice) {
            Button("OK") { dismiss() }
        } message: {
            Text("Your capability changes were saved. They take effect the next time you restart Agent Smith.")
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.bold())
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displayNameRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Display name").font(.headline)
                Spacer()
                Text("Resolved: \(resolvedModelInfo?.displayName ?? modelID)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text("Override how this model is named in pickers and lists. Empty = keep the catalog's name.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("e.g. GLM 5.2 (Ollama Cloud)", text: $displayNameOverride)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func statusRow(_ descriptor: StatusDescriptor) -> some View {
        let resolved = descriptor.resolved(resolvedModelInfo)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(descriptor.title).font(.headline)
                Spacer()
                switch resolved {
                case true?:
                    Text("Resolved: ON")
                        .font(.caption.monospaced())
                        .foregroundStyle(.green)
                case false?:
                    Text("Resolved: off")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                case nil:
                    Text("Resolved: unknown")
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
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
        let existing = shared.userModelOverrides[key]
        for descriptor in Self.descriptors {
            states[descriptor.id] = FlagState(existing?.capabilities?[keyPath: descriptor.override] ?? nil)
        }
        for descriptor in Self.statusDescriptors {
            states[descriptor.id] = FlagState(existing?[keyPath: descriptor.override] ?? nil)
        }
        displayNameOverride = existing?.displayName ?? ""
        initialStates = states
        initialDisplayNameOverride = displayNameOverride
    }

    /// Persists the edits. If they changed anything, surfaces the restart notice (whose OK
    /// dismisses); otherwise dismisses straight through so an unchanged visit doesn't nag.
    private func commit() {
        let changed = states != initialStates || displayNameOverride != initialDisplayNameOverride
        save()
        if changed {
            showRestartNotice = true
        } else {
            dismiss()
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
        // This sheet now owns capabilities, status flags, and display name; only the fields it
        // does NOT edit (limits, pricing, behavior flags) are carried from the existing override.
        let existing = shared.userModelOverrides[key]
        var merged = ModelMetadataOverride(
            displayName: trimmedDisplayNameOverride,
            maxInputTokens: existing?.maxInputTokens,
            maxOutputTokens: existing?.maxOutputTokens,
            capabilities: anyForced ? patch : nil,
            pricing: existing?.pricing,
            behaviorFlags: existing?.behaviorFlags
        )
        for descriptor in Self.statusDescriptors {
            merged[keyPath: descriptor.override] = (states[descriptor.id] ?? .default).asOptional
        }
        shared.setUserModelOverride(providerID: providerID, modelID: modelID, override: merged)
    }
}
