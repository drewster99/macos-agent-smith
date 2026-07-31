import SwiftUI
import SwiftLLMKit

/// Per-(provider, model) capability-flag and status override editor — the twin of
/// `BehaviorFlagsEditorSheet`, but for `ModelCapabilities` (chat, vision, tool use, …) plus the
/// top-level status fields (`hidden`, `isAvailable`, `isAccessDenied`), the display-name override,
/// the token limits, and — new — the catalog-fetch / probe freshness and an on-demand probe.
///
/// The catalog's capability flags come from LiteLLM + provider-reported abilities, which are
/// frequently WRONG for self-hosted / cloud models. This sheet lets the user force any flag on or
/// off per model, writing through `SharedAppState.setUserModelOverride(...)`. Sections are ordered
/// Metadata & Probes → Status & Identity → Limits → Capabilities, rows within each sorted by title,
/// and the chrome/rows are shared with the other override sheets.
struct CapabilitiesEditorSheet: View {
    @Bindable var shared: SharedAppState
    let providerID: String
    let modelID: String

    @Environment(\.dismiss) private var dismiss

    @State private var states: [String: TriStateOverride] = [:]
    @State private var displayNameOverride: String = ""
    @State private var maxContextOverride: Int?
    @State private var maxOutputOverride: Int?
    @State private var probeRunner = ModelProbeRunner()
    /// Bumped by Reset to defaults so each limit's Default/Override control fully resyncs.
    @State private var resetToken = 0

    private var key: String { "\(providerID)/\(modelID)" }
    private var targetKey: String { "\(providerID)/\(modelID)" }

    private var resolvedModelInfo: ModelInfo? {
        shared.llmKit.modelInfo(providerID: providerID, modelID: modelID)
    }

    private var provider: ModelProvider? {
        shared.llmKit.providers.first(where: { $0.id == providerID })
    }

    private var localProbeRecord: ProbeRecord? {
        guard let provider else { return nil }
        return shared.llmKit.probeRecords(provider: provider, modelID: modelID).local
    }

    /// The model's reported ceiling for a limit, resolved to be INDEPENDENT of this user override so
    /// it stays visible even after the used value is capped below it: a real probed measurement, then
    /// the composition's non-user layers, then the resolved catalog value (only when unoverridden).
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
        let info = resolvedModelInfo
        VStack(alignment: .leading, spacing: 16) {
            OverrideSheetHeader(title: "Model Capabilities & Status", subtitle: "\(providerID) — \(modelID)",
                                onCancel: { dismiss() }, onDone: { save(); dismiss() })
            if info?.capabilities.state(of: .chat) == false {
                NotAChatModelBanner()
            }
            CapabilitiesForm(
                modelInfo: info,
                reportedContext: reportedLimit(probed: \.maxContextTokens, facts: \.maxInputTokens,
                                               catalog: info?.maxInputTokens, userOverride: maxContextOverride),
                reportedOutput: reportedLimit(probed: \.maxOutputTokens, facts: \.maxOutputTokens,
                                              catalog: info?.maxOutputTokens, userOverride: maxOutputOverride),
                fallbackName: modelID,
                probeRunner: probeRunner,
                targetKey: targetKey,
                providerAvailable: provider != nil,
                onProbe: { runProbe() },
                resetToken: resetToken,
                states: $states,
                displayNameOverride: $displayNameOverride,
                maxContextOverride: $maxContextOverride,
                maxOutputOverride: $maxOutputOverride)
            OverrideSheetFooter(
                explanation: "Default = inherit LiteLLM/provider resolution. Force on/off writes a per-model override. Takes effect after you restart Agent Smith.",
                resetDisabled: !hasAnyOverride,
                onReset: { resetAll() })
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 660, minHeight: 480, idealHeight: 680)
        .onAppear { loadFromShared() }
    }

    /// Probes just this model, on demand. Reuses `ModelProbeRunner` (the same path the metadata
    /// inspector's Probe Now uses); on completion it refreshes the catalog, so the resolved rows and
    /// the "Capabilities probed" timestamp update live without a restart.
    private func runProbe() {
        guard let provider else { return }
        Task { await probeRunner.probe(targets: [(provider: provider, modelID: modelID)], kit: shared.llmKit) }
    }

    private func resetAll() {
        for capability in ModelCapability.allCases { states[capability.rawValue] = .default }
        for descriptor in CapabilityStatusDescriptor.all { states[descriptor.id] = .default }
        displayNameOverride = ""
        maxContextOverride = nil
        maxOutputOverride = nil
        resetToken += 1
    }

    private func loadFromShared() {
        let existing = shared.userModelOverrides[key]
        for capability in ModelCapability.allCases {
            states[capability.rawValue] = TriStateOverride(existing?.capabilities?[capability] ?? nil)
        }
        for descriptor in CapabilityStatusDescriptor.all {
            states[descriptor.id] = TriStateOverride(existing?[keyPath: descriptor.override] ?? nil)
        }
        displayNameOverride = existing?.displayName ?? ""
        maxContextOverride = existing?.maxInputTokens
        maxOutputOverride = existing?.maxOutputTokens
    }

    private func save() {
        var patch = ModelCapabilitiesOverride()
        var anyForced = false
        for capability in ModelCapability.allCases {
            let value = (states[capability.rawValue] ?? .default).asOptional
            patch[capability] = value
            if value != nil { anyForced = true }
        }
        // This sheet owns capabilities, status flags, display name, AND token limits; only the fields
        // it does NOT edit (pricing, behavior flags) are carried from the existing override.
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
        for descriptor in CapabilityStatusDescriptor.all {
            merged[keyPath: descriptor.override] = (states[descriptor.id] ?? .default).asOptional
        }
        shared.setUserModelOverride(providerID: providerID, modelID: modelID, override: merged)
    }
}

// MARK: - Status descriptor

/// One editable model-status field that lives at the top level of `ModelMetadataOverride` (not
/// inside the capabilities container). Its resolved value is tri-state on `ModelInfo` — `nil` means
/// "no source has said," which a row surfaces as "unknown." Shared by the sheet (save/load) and the
/// form (rows) so the two can't disagree about the set.
private struct CapabilityStatusDescriptor: Identifiable {
    let id: String
    let title: String
    let description: String
    let resolved: (ModelInfo?) -> Bool?
    let override: WritableKeyPath<ModelMetadataOverride, Bool?>

    static let all: [CapabilityStatusDescriptor] = [
        CapabilityStatusDescriptor(id: "hidden", title: "Hidden",
            description: "Hide this model from configuration pickers. Presentation only — nothing is deleted, and un-hiding is just clearing this.",
            resolved: { $0?.hidden }, override: \.hidden),
        CapabilityStatusDescriptor(id: "isAvailable", title: "Available",
            description: "Whether the model actually answers. Probes set this empirically; force it to correct a stale verdict (e.g. a model that came back to life).",
            resolved: { $0?.isAvailable }, override: \.isAvailable),
        CapabilityStatusDescriptor(id: "isAccessDenied", title: "Access denied",
            description: "Whether YOUR account/key is denied for this model. Account-scoped — force off after a plan change un-denies you.",
            resolved: { $0?.isAccessDenied }, override: \.isAccessDenied)
    ]

    static let sorted = all.sorted { $0.title < $1.title }
}

// MARK: - Form

/// The grouped `Form` body of the capabilities sheet. Split out so the sheet's own `body` stays a
/// thin composition of header / banner / form / footer.
private struct CapabilitiesForm: View {
    let modelInfo: ModelInfo?
    let reportedContext: Int?
    let reportedOutput: Int?
    let fallbackName: String
    let probeRunner: ModelProbeRunner
    let targetKey: String
    let providerAvailable: Bool
    let onProbe: () -> Void
    let resetToken: Int
    @Binding var states: [String: TriStateOverride]
    @Binding var displayNameOverride: String
    @Binding var maxContextOverride: Int?
    @Binding var maxOutputOverride: Int?

    private static let sortedCapabilities = ModelCapability.allCases.sorted { $0.editorTitle < $1.editorTitle }

    private var effortLevels: [String] { modelInfo?.validEffortLevels ?? [] }

    private var probeTitle: String {
        modelInfo?.lastProbedAt == nil ? "Probe this model now" : "Re-probe this model"
    }

    private var probeStatusText: String? {
        switch probeRunner.states[targetKey] {
        case .probing: return "Probing…"
        case .stored(let n): return "Probed — \(n) calls"
        case .skipped(let reason): return "Skipped: \(reason)"
        case .failed(let error): return "Failed: \(error)"
        case .pending, nil: return nil
        }
    }

    var body: some View {
        let caps = modelInfo?.capabilities ?? ModelCapabilities()
        Form {
            Section("Metadata & Probes") {
                TimestampRow(title: "Model list fetched", date: modelInfo?.fetchedAt, empty: "unknown")
                TimestampRow(title: "Capabilities probed", date: modelInfo?.lastProbedAt,
                             empty: "Never probed on this Mac")
                ProbeControlRow(title: probeTitle, disabled: !providerAvailable || probeRunner.isRunning,
                                statusText: probeStatusText, isRunning: probeRunner.isRunning, onProbe: onProbe)
            }
            Section("Status & Identity") {
                DisplayNameRow(resolvedName: modelInfo?.displayName ?? fallbackName, text: $displayNameOverride)
                ForEach(CapabilityStatusDescriptor.sorted) { descriptor in
                    OverrideTriStateRow(title: descriptor.title, resolved: descriptor.resolved(modelInfo),
                                        description: descriptor.description, selection: binding(for: descriptor.id))
                }
            }
            Section("Limits") {
                LimitRow(title: "Max context (input) tokens",
                         help: "Correct the model's context window when the catalog is wrong or missing (e.g. Ollama Cloud reports no context window). Becomes the value the app uses everywhere. Empty = use the reported value.",
                         reported: reportedContext, value: $maxContextOverride, resetToken: resetToken)
                LimitRow(title: "Max output tokens",
                         help: "Correct the model's output-token ceiling when the catalog is wrong or missing. Becomes the value the app uses. Empty = use the reported value.",
                         reported: reportedOutput, value: $maxOutputOverride, resetToken: resetToken)
            }
            Section("Capabilities") {
                LabeledContent("Effort levels") {
                    Text(effortLevels.isEmpty ? "none reported" : effortLevels.joined(separator: ", "))
                        .font(.caption.monospaced())
                        .foregroundStyle(effortLevels.isEmpty ? AnyShapeStyle(HierarchicalShapeStyle.tertiary)
                                                              : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                }
                ForEach(Self.sortedCapabilities, id: \.self) { capability in
                    OverrideTriStateRow(title: capability.editorTitle, resolved: caps[capability],
                                        description: capability.editorDescription, selection: binding(for: capability.rawValue))
                }
            }
        }
        .formStyle(.grouped)
    }

    private func binding(for rawValue: String) -> Binding<TriStateOverride> {
        Binding(get: { states[rawValue] ?? .default }, set: { states[rawValue] = $0 })
    }
}

/// A native `LabeledContent` freshness row: title on the left, a monospaced absolute timestamp (or
/// the `empty` placeholder, dimmed) on the right.
private struct TimestampRow: View {
    let title: String
    let date: Date?
    let empty: String

    var body: some View {
        LabeledContent(title) {
            Text(date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? empty)
                .font(.caption.monospaced())
                .foregroundStyle(date == nil ? AnyShapeStyle(HierarchicalShapeStyle.tertiary)
                                             : AnyShapeStyle(HierarchicalShapeStyle.secondary))
        }
    }
}

// MARK: - Rows

private struct DisplayNameRow: View {
    let resolvedName: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Display name").font(.headline)
                Spacer()
                Text("Resolved: \(resolvedName)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text("Override how this model is named in pickers and lists. Empty = keep the catalog's name.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("e.g. GLM 5.2 (Ollama Cloud)", text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

/// `reported` is the model's own ceiling (probe/catalog), shown as a persistent reference in the
/// header. `value` is a CORRECTION of the believed limit, edited through the shared Default/Override
/// control — set it when the catalog is wrong or missing. It is NOT a cost-cap preference; per-run
/// caps belong on the configuration, not on the model's metadata.
private struct LimitRow: View {
    let title: String
    let help: String
    let reported: Int?
    @Binding var value: Int?
    let resetToken: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                Text("Model reports: \(reported.map { "\($0.formatted())" } ?? "unknown")")
                    .font(.caption.monospaced())
                    .foregroundStyle(reported == nil ? AnyShapeStyle(HierarchicalShapeStyle.tertiary)
                                                     : AnyShapeStyle(HierarchicalShapeStyle.secondary))
            }
            Text(help)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            OverrideValueControl(override: $value, defaultValue: reported,
                                 draftText: OverrideValueParsing.tokenDraft,
                                 format: OverrideValueParsing.tokenLabel,
                                 parse: OverrideValueParsing.tokenCount,
                                 resetToken: resetToken)
        }
    }
}

/// The on-demand probe control: a Probe / Re-probe button, a spinner while a run is live, and the
/// per-model outcome text.
private struct ProbeControlRow: View {
    let title: String
    let disabled: Bool
    let statusText: String?
    let isRunning: Bool
    let onProbe: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onProbe) {
                Label(title, systemImage: "bolt.badge.checkmark")
            }
            .disabled(disabled)
            if isRunning { ProgressView().controlSize(.small) }
            Spacer()
            if let statusText {
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Pinned warning for a model that does NOT serve the chat-completions endpoint Agent Smith talks
/// to. Shown only when chat resolves OFF — the case where the capability rows below resolve to
/// unreachable defaults and assigning the model 404s at call time.
private struct NotAChatModelBanner: View {
    var body: some View {
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
}
