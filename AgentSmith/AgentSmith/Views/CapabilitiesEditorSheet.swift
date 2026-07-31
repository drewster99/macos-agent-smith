import SwiftUI
import SwiftLLMKit

/// Per-(provider, model) capability-flag and status override editor — the twin of
/// `BehaviorFlagsEditorSheet`, but for `ModelCapabilities` (chat, vision, tool use, …) plus the
/// top-level status fields (`hidden`, `isAvailable`, `isAccessDenied`) and the display-name override.
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

    // Capability rows are driven directly from `ModelCapability.allCases` (title/description come
    // from the enum, the override value from `ModelCapabilitiesOverride`'s subscript), so a new
    // capability appears here automatically — no hand-maintained list to drift. Chat is one of them.

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
                         resolved: { $0?.isAccessDenied }, override: \.isAccessDenied)
        // Chat lives in the Capabilities section now — it's a ModelCapability like the rest.
    ]

    @State private var states: [String: FlagState] = [:]
    /// The override selections as they stood when the sheet opened, so Done can tell whether
    /// anything actually changed (and only then surface the restart notice).
    @State private var initialStates: [String: FlagState] = [:]
    /// Display-name override as typed; empty = no override.
    @State private var displayNameOverride: String = ""
    @State private var initialDisplayNameOverride: String = ""
    /// Token-limit overrides as typed; nil/empty = no override (inherit the catalog value).
    @State private var maxContextOverride: Int?
    @State private var maxOutputOverride: Int?
    @State private var initialMaxContextOverride: Int?
    @State private var initialMaxOutputOverride: Int?
    @State private var showRestartNotice = false

    private var key: String { "\(providerID)/\(modelID)" }

    private var resolvedModelInfo: ModelInfo? {
        shared.llmKit.modelInfo(providerID: providerID, modelID: modelID)
    }

    private var resolvedCapabilities: ModelCapabilities {
        resolvedModelInfo?.capabilities ?? ModelCapabilities()
    }

    /// The model's own reported limit, independent of THIS user override — so it stays visible as
    /// a reference even after you cap the used value below it. Prefers the probe record's
    /// established value (a real measurement); falls back to the resolved catalog value.
    private var localProbeRecord: ProbeRecord? {
        guard let provider = shared.llmKit.providers.first(where: { $0.id == providerID }) else { return nil }
        return shared.llmKit.probeRecords(provider: provider, modelID: modelID).local
    }
    /// The model's reported ceiling for a limit, resolved to be INDEPENDENT of this user override
    /// so it stays visible even after the used value is capped below it. In priority:
    /// 1. a real probed measurement; 2. the composition's non-user layers (catalog/empirical),
    /// pre-override, when computed; 3. the resolved catalog value, but ONLY when the user hasn't
    /// overridden this field (otherwise that value is the override itself and would mislead).
    private func reportedLimit(probed: KeyPath<ModelProfile, ProbeFinding<Int>>,
                               facts: KeyPath<ModelFacts, Int?>,
                               catalog: Int?, userOverride: Int?) -> Int? {
        if let finding = localProbeRecord?.profile[keyPath: probed], finding.status == .established {
            return finding.value
        }
        if let composition = shared.llmKit.metadataCompositions[key] {
            for layer in [MetadataLayer.authoritative, .empirical, .downloadedOverrides, .enrichment] {
                if let layerFacts = composition.layers[layer], let value = layerFacts[keyPath: facts] {
                    return value
                }
            }
        }
        return userOverride == nil ? catalog : nil
    }

    private var hasAnyOverride: Bool {
        states.values.contains { $0 != .default } || !displayNameOverride.isEmpty
            || maxContextOverride != nil || maxOutputOverride != nil
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

            // Chat support is the GATING capability: when it's off the model can't be called at all,
            // so surface it as a pinned banner rather than leaving it as one buried row far below the
            // (now-misleading) Vision/Tool/Reasoning rows.
            if resolvedModelInfo?.capabilities.state(of: .chat) == false {
                chatNotAChatModelBanner()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sectionHeader("Capabilities")
                    ForEach(ModelCapability.allCases, id: \.self) { capability in
                        flagRow(capability)
                    }

                    Divider().padding(.vertical, 4)

                    sectionHeader("Status & Identity")
                    displayNameRow()
                    ForEach(Self.statusDescriptors) { descriptor in
                        statusRow(descriptor)
                    }

                    Divider().padding(.vertical, 4)

                    sectionHeader("Limits")
                    limitRow(title: "Max context (input) tokens",
                             help: "Correct the model's context window when the catalog is wrong or missing (e.g. Ollama Cloud reports no context window). Becomes the value the app uses everywhere. Empty = use the reported value.",
                             reported: reportedLimit(probed: \.maxContextTokens, facts: \.maxInputTokens,
                                                     catalog: resolvedModelInfo?.maxInputTokens, userOverride: maxContextOverride),
                             value: $maxContextOverride)
                    limitRow(title: "Max output tokens",
                             help: "Correct the model's output-token ceiling when the catalog is wrong or missing. Becomes the value the app uses. Empty = use the reported value.",
                             reported: reportedLimit(probed: \.maxOutputTokens, facts: \.maxOutputTokens,
                                                     catalog: resolvedModelInfo?.maxOutputTokens, userOverride: maxOutputOverride),
                             value: $maxOutputOverride)
                }
            }

            Divider()

            HStack {
                Button("Reset to defaults") {
                    for capability in ModelCapability.allCases { states[capability.rawValue] = .default }
                    for descriptor in Self.statusDescriptors { states[descriptor.id] = .default }
                    displayNameOverride = ""
                    maxContextOverride = nil
                    maxOutputOverride = nil
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

    /// Pinned warning for a model that does NOT serve the chat-completions endpoint Agent Smith talks
    /// to. Shown only when chat resolves OFF — the case where the capability rows below resolve to
    /// unreachable defaults and assigning the model 404s at call time.
    private func chatNotAChatModelBanner() -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Not a chat model")
                    .font(.subheadline.bold())
                Text("This model doesn't serve the chat-completions endpoint Agent Smith uses (it's responses-/embeddings-only), so assigning it to an agent fails with HTTP 404. Force “Chat completions” on in the Capabilities section below if this is wrong.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.5))
    }

    /// `reported` is the model's own ceiling (probe/catalog), shown as a persistent reference.
    /// `value` is a CORRECTION of the believed limit — set it when the catalog is wrong or missing
    /// (e.g. Ollama Cloud reports no context window). It is NOT a cost-cap preference; per-run caps
    /// belong on the configuration, not on the model's metadata.
    private func limitRow(title: String, help: String, reported: Int?, value: Binding<Int?>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                Text("Model reports: \(reported.map { "\($0.formatted())" } ?? "unknown")")
                    .font(.caption.monospaced())
                    .foregroundStyle(reported == nil ? .tertiary : .secondary)
            }
            Text(help)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField(reported.map { "\($0)" } ?? "model's limit", value: value, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                // Warn when the used value EXCEEDS what the model reports — that 400s in production.
                if let reported, value.wrappedValue != reported {
                    Button("Prefill (\(reported.formatted()))") { value.wrappedValue = reported }
                        .controlSize(.small)
                        .help("Fill the field with the model's reported value, then edit it down.")
                }
                if value.wrappedValue != nil {
                    Button("Inherit catalog") { value.wrappedValue = nil }
                        .controlSize(.small)
                        .help("Remove the override and use the model's own reported limit.")
                }
            }
        }
    }

    private func displayNameRow() -> some View {
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
                resolvedStatusText(resolved)
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

    /// Tri-state "Resolved: ON / off / unknown" label, shared by capability and status rows.
    @ViewBuilder
    private func resolvedStatusText(_ resolved: Bool?) -> some View {
        switch resolved {
        case true?:
            Text("Resolved: ON").font(.caption.monospaced()).foregroundStyle(.green)
        case false?:
            Text("Resolved: off").font(.caption.monospaced()).foregroundStyle(.secondary)
        case nil:
            Text("Resolved: unknown").font(.caption.monospaced()).foregroundStyle(.tertiary)
        }
    }

    private func flagRow(_ capability: ModelCapability) -> some View {
        let resolved = resolvedCapabilities[capability]   // tri-state, straight from the enum
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(capability.editorTitle).font(.headline)
                Spacer()
                resolvedStatusText(resolved)
            }
            Text(capability.editorDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker(selection: Binding(
                get: { states[capability.rawValue] ?? .default },
                set: { states[capability.rawValue] = $0 }
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
        for capability in ModelCapability.allCases {
            states[capability.rawValue] = FlagState(existing?.capabilities?[capability] ?? nil)
        }
        for descriptor in Self.statusDescriptors {
            states[descriptor.id] = FlagState(existing?[keyPath: descriptor.override] ?? nil)
        }
        displayNameOverride = existing?.displayName ?? ""
        maxContextOverride = existing?.maxInputTokens
        maxOutputOverride = existing?.maxOutputTokens
        initialStates = states
        initialDisplayNameOverride = displayNameOverride
        initialMaxContextOverride = maxContextOverride
        initialMaxOutputOverride = maxOutputOverride
    }

    /// Persists the edits. If they changed anything, surfaces the restart notice (whose OK
    /// dismisses); otherwise dismisses straight through so an unchanged visit doesn't nag.
    private func commit() {
        let changed = states != initialStates || displayNameOverride != initialDisplayNameOverride
            || maxContextOverride != initialMaxContextOverride
            || maxOutputOverride != initialMaxOutputOverride
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
        for capability in ModelCapability.allCases {
            let value = (states[capability.rawValue] ?? .default).asOptional
            patch[capability] = value
            if value != nil { anyForced = true }
        }
        // This sheet now owns capabilities, status flags, display name, AND token limits; only the
        // fields it does NOT edit (pricing, behavior flags) are carried from the existing override.
        let existing = shared.userModelOverrides[key]
        var merged = ModelMetadataOverride(
            displayName: trimmedDisplayNameOverride,
            maxInputTokens: maxContextOverride,
            maxOutputTokens: maxOutputOverride,
            sizeLabel: existing?.sizeLabel,
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
