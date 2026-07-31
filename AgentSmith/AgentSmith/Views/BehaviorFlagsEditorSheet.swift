import SwiftUI
import SwiftLLMKit

/// Per-(provider, model) `BehaviorFlags` editor — the twin of `CapabilitiesEditorSheet`, but for
/// runtime behavior knobs (GLM salvage, `max_completion_tokens`, reasoning replay, …).
///
/// Rows are driven directly from `BehaviorFlag.allCases` (title/description from the enum, the
/// override value from `BehaviorFlagsOverride`'s subscript), so every flag — and any future one —
/// appears here automatically with no hand-maintained list to drift. (The old hardcoded version
/// only exposed three of the eight flags.)
///
/// Each flag is tri-state: **Default** (inherit bundled / LiteLLM resolution), **Force on**,
/// **Force off**. Force values force-replace the resolved flag. Edits write through
/// `SharedAppState.setUserModelOverride(...)`, which updates `LLMKitManager`'s in-memory overrides
/// and persists to the user model overrides JSON. An all-default entry is removed so the file
/// stays tidy.
struct BehaviorFlagsEditorSheet: View {
    @Bindable var shared: SharedAppState
    let providerID: String
    let modelID: String

    @Environment(\.dismiss) private var dismiss

    /// Tri-state for a single flag. Mirrors `CapabilitiesEditorSheet.FlagState`.
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

    @State private var states: [String: FlagState] = [:]

    private var key: String { "\(providerID)/\(modelID)" }

    private var resolvedFlags: BehaviorFlags {
        shared.llmKit.behaviorFlags(forProviderID: providerID, modelID: modelID)
    }

    private var hasAnyOverride: Bool {
        states.values.contains { $0 != .default }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Behavior Flags")
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
                    ForEach(BehaviorFlag.allCases, id: \.self) { flag in
                        flagRow(flag)
                    }
                }
            }

            Divider()

            HStack {
                Button("Reset to defaults") {
                    for flag in BehaviorFlag.allCases { states[flag.rawValue] = .default }
                }
                .disabled(!hasAnyOverride)
                Spacer()
                Text("Default = use bundled / LiteLLM resolution. Force on/off writes a per-model override.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(20)
        .frame(minWidth: 540, idealWidth: 640, minHeight: 420, idealHeight: 620)
        .onAppear { loadFromShared() }
    }

    private func flagRow(_ flag: BehaviorFlag) -> some View {
        let resolved = resolvedFlags[flag]
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(flag.editorTitle).font(.headline)
                Spacer()
                Text("Resolved: \(resolved ? "ON" : "off")")
                    .font(.caption.monospaced())
                    .foregroundStyle(resolved ? .green : .secondary)
            }
            Text(flag.editorDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker(selection: Binding(
                get: { states[flag.rawValue] ?? .default },
                set: { states[flag.rawValue] = $0 }
            ), label: EmptyView()) {
                ForEach(FlagState.allCases) { value in
                    Text(value.label).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    /// Reads the existing user override (if any) for this (provider, model) pair and initializes
    /// each tri-state to match. Missing override → all `.default`.
    private func loadFromShared() {
        let existing = shared.userModelOverrides[key]?.behaviorFlags
        for flag in BehaviorFlag.allCases {
            states[flag.rawValue] = FlagState(existing?[flag] ?? nil)
        }
    }

    /// Builds an override patch from the tri-state pickers and writes it. Every non-flag field the
    /// user already had on this entry is carried through — this sheet only edits `behaviorFlags`.
    /// An all-default patch stores nil so `setUserModelOverride` can drop an emptied entry.
    private func save() {
        var flagsPatch = BehaviorFlagsOverride()
        for flag in BehaviorFlag.allCases {
            flagsPatch[flag] = (states[flag.rawValue] ?? .default).asOptional
        }
        let existing = shared.userModelOverrides[key]
        var merged = ModelMetadataOverride(
            displayName: existing?.displayName,
            maxInputTokens: existing?.maxInputTokens,
            maxOutputTokens: existing?.maxOutputTokens,
            sizeLabel: existing?.sizeLabel,
            capabilities: existing?.capabilities,
            pricing: existing?.pricing,
            behaviorFlags: flagsPatch.isEmpty ? nil : flagsPatch
        )
        merged.hidden = existing?.hidden
        merged.isAvailable = existing?.isAvailable
        merged.isAccessDenied = existing?.isAccessDenied
        shared.setUserModelOverride(providerID: providerID, modelID: modelID, override: merged)
    }
}
