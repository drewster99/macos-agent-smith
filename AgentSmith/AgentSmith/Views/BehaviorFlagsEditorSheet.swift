import SwiftUI
import SwiftLLMKit

/// Per-(provider, model) `BehaviorFlags` editor — the twin of `CapabilitiesEditorSheet`, but for
/// runtime behavior knobs (GLM salvage, `max_completion_tokens`, reasoning replay, …).
///
/// Rows are driven directly from `BehaviorFlag.allCases` (title/description from the enum, the
/// override value from `BehaviorFlagsOverride`'s subscript), sorted by title, so every flag — and
/// any future one — appears here automatically with no hand-maintained list to drift.
///
/// Each flag is tri-state: **Default** (inherit bundled / LiteLLM resolution), **Force on**,
/// **Force off**. Force values force-replace the resolved flag. Edits write through
/// `SharedAppState.setUserModelOverride(...)`, which updates `LLMKitManager`'s in-memory overrides
/// and persists to the user model overrides JSON. An all-default entry is removed so the file
/// stays tidy. The chrome (header/footer/rows) is shared with the other override sheets.
struct BehaviorFlagsEditorSheet: View {
    @Bindable var shared: SharedAppState
    let providerID: String
    let modelID: String

    @Environment(\.dismiss) private var dismiss

    @State private var states: [String: TriStateOverride] = [:]
    /// `nil` = inherit (no source has said). A picker rather than flags because the mechanisms are
    /// mutually exclusive — as booleans, two could be on at once and describe a model that can't exist.
    @State private var reasoningControlSelection: ReasoningControl?

    /// Flags shown in title order — sorted once, not per body pass.
    private static let sortedFlags = BehaviorFlag.allCases.sorted { $0.editorTitle < $1.editorTitle }

    private var key: String { "\(providerID)/\(modelID)" }

    private var resolvedFlags: BehaviorFlags {
        shared.llmKit.behaviorFlags(forProviderID: providerID, modelID: modelID)
    }

    private var hasAnyOverride: Bool {
        states.values.contains { $0 != .default } || reasoningControlSelection != nil
    }

    var body: some View {
        let resolved = resolvedFlags
        VStack(alignment: .leading, spacing: 16) {
            OverrideSheetHeader(title: "Behavior Flags", subtitle: "\(providerID) — \(modelID)",
                                onCancel: { dismiss() }, onDone: { save(); dismiss() })
            Form {
                Section {
                    ForEach(Self.sortedFlags, id: \.self) { flag in
                        OverrideTriStateRow(title: flag.editorTitle, resolved: resolved[flag],
                                            description: flag.editorDescription, selection: binding(for: flag.rawValue))
                    }
                }
                Section("Reasoning control") {
                    Picker("Mechanism", selection: $reasoningControlSelection) {
                        Text("Inherit").tag(ReasoningControl?.none)
                        ForEach(ReasoningControl.allCases, id: \.self) { control in
                            Text(control.editorTitle).tag(ReasoningControl?.some(control))
                        }
                    }
                    Text(reasoningControlSelection?.editorDescription
                         ?? "How reasoning is switched on and off. Inherit leaves it to the catalog.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                BehaviorFlagsExtrasSection(extras: resolved.extras)
            }
            .formStyle(.grouped)
            OverrideSheetFooter(
                explanation: "Default = use bundled / LiteLLM resolution. Force on/off writes a per-model override.",
                resetDisabled: !hasAnyOverride,
                onReset: {
                    for flag in BehaviorFlag.allCases { states[flag.rawValue] = .default }
                    reasoningControlSelection = nil
                })
        }
        .padding(20)
        .frame(minWidth: 540, idealWidth: 640, minHeight: 420, idealHeight: 620)
        .onAppear { loadFromShared(); reasoningControlSelection = shared.userModelOverrides[key]?.reasoningControl }
    }

    private func binding(for rawValue: String) -> Binding<TriStateOverride> {
        Binding(get: { states[rawValue] ?? .default }, set: { states[rawValue] = $0 })
    }

    /// Reads the existing user override (if any) for this (provider, model) pair and initializes
    /// each tri-state to match. Missing override → all `.default`.
    private func loadFromShared() {
        let existing = shared.userModelOverrides[key]?.behaviorFlags
        for flag in BehaviorFlag.allCases {
            states[flag.rawValue] = TriStateOverride(existing?[flag] ?? nil)
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
        // Start from the EXISTING override and mutate only what this sheet owns. Rebuilding it
        // field-by-field made every field this sheet doesn't know about vanish on save — so any
        // field added to ModelMetadataOverride was silently wiped by whichever editor the user
        // happened to open next. Preserving by default fails safe; enumerating fails lossy.
        var merged = shared.userModelOverrides[key] ?? ModelMetadataOverride()
        merged.behaviorFlags = flagsPatch.isEmpty ? nil : flagsPatch
        merged.reasoningControl = reasoningControlSelection
        shared.setUserModelOverride(providerID: providerID, modelID: modelID, override: merged)
    }
}

/// Read-only display of a model's resolved `BehaviorFlags.extras` — the free-form key/value bag for
/// one-off provider tweaks that haven't earned a typed flag. Shown so the values are visible even
/// though the tri-state rows above (which iterate `BehaviorFlag.allCases`) can't reach them; making
/// them editable is deferred.
private struct BehaviorFlagsExtrasSection: View {
    let extras: [String: String]

    var body: some View {
        Section("Extras (read-only)") {
            if extras.isEmpty {
                Text("No extra flags set for this model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(extras.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    LabeledContent(key) {
                        Text(value)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}
