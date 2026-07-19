import SwiftUI
import SwiftLLMKit

/// Per-(provider, model) `BehaviorFlags` editor.
///
/// The user picks one of three states for each typed flag:
///   - **Default** — no override; the resolved value comes from bundled defaults
///                   (provider-wide / per-model / apiType-keyed) plus any
///                   gap-fill from LiteLLM. This is the safe choice for almost
///                   everything; the bundled JSON has good defaults for known
///                   GLM hosts, OpenAI, and Mistral.
///   - **Force on** — a force-replace override that turns the flag on regardless
///                    of what the bundled layer says. Useful when a new GLM
///                    variant ships and the bundled JSON hasn't caught up.
///   - **Force off** — a force-replace override that turns the flag off. Useful
///                     if a bundled flag misfires on a particular model.
///
/// Edits write through `SharedAppState.setUserModelOverride(...)`, which updates
/// `LLMKitManager`'s in-memory user overrides and persists to the user model
/// overrides JSON file on disk. Entries with every flag back at "Default" are
/// removed from the override file entirely so the disk state stays tidy.
struct BehaviorFlagsEditorSheet: View {
    @Bindable var shared: SharedAppState
    let providerID: String
    let modelID: String

    @Environment(\.dismiss) private var dismiss

    /// Tri-state for a single flag.
    private enum FlagState: String, CaseIterable, Identifiable {
        case `default`
        case forceOn
        case forceOff

        var id: String { rawValue }
        var label: String {
            switch self {
            case .default: return "Default"
            case .forceOn: return "Force on"
            case .forceOff: return "Force off"
            }
        }

        /// Initializes from an optional override field — `nil` means default.
        init(_ optional: Bool?) {
            switch optional {
            case nil:    self = .default
            case true?:  self = .forceOn
            case false?: self = .forceOff
            }
        }

        /// Renders back to an optional override field. `.default` becomes nil so
        /// the override patch carries no value for this flag.
        var asOptional: Bool? {
            switch self {
            case .default:  return nil
            case .forceOn:  return true
            case .forceOff: return false
            }
        }
    }

    @State private var glmTemplateSalvage: FlagState = .default
    @State private var useMaxCompletionTokens: FlagState = .default
    @State private var disableParallelToolCalls: FlagState = .default

    private var key: String { "\(providerID)/\(modelID)" }

    private var resolvedFlags: BehaviorFlags {
        shared.llmKit.behaviorFlags(forProviderID: providerID, modelID: modelID)
    }

    private var hasUnsavedDefault: Bool {
        glmTemplateSalvage == .default
            && useMaxCompletionTokens == .default
            && disableParallelToolCalls == .default
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
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Done") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                flagRow(
                    title: "GLM template salvage",
                    description: "Recover tool-call args from `<arg_key>/<arg_value>` blocks in `content` and strip GLM chat-template control tokens. Required for GLM-4 / GLM-5 models on most adapters; harmless on non-GLM responses.",
                    state: $glmTemplateSalvage,
                    resolved: resolvedFlags.glmTemplateSalvage
                )

                flagRow(
                    title: "Use `max_completion_tokens`",
                    description: "Send `max_completion_tokens` instead of `max_tokens` on chat completions. Required for OpenAI GPT-5 / o-series; rejected by DeepSeek and most other OpenAI-compatible backends.",
                    state: $useMaxCompletionTokens,
                    resolved: resolvedFlags.useMaxCompletionTokens
                )

                flagRow(
                    title: "Disable parallel tool calls",
                    description: "Omit `parallel_tool_calls` from the request. `parallel_tool_calls: true` is sent by default; turn this ON only for a strict endpoint that rejects the field with HTTP 400.",
                    state: $disableParallelToolCalls,
                    resolved: resolvedFlags.disableParallelToolCalls
                )
            }

            Divider()

            HStack {
                Button("Reset to defaults") {
                    glmTemplateSalvage = .default
                    useMaxCompletionTokens = .default
                    disableParallelToolCalls = .default
                }
                .disabled(hasUnsavedDefault)
                Spacer()
                Text("Default = use bundled / LiteLLM resolution. Force on/off writes a per-model override.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(20)
        .frame(minWidth: 540, idealWidth: 640, minHeight: 420)
        .onAppear { loadFromShared() }
    }

    private func flagRow(
        title: String,
        description: String,
        state: Binding<FlagState>,
        resolved: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.headline)
                Spacer()
                Text("Resolved: \(resolved ? "ON" : "off")")
                    .font(.caption.monospaced())
                    .foregroundStyle(resolved ? .green : .secondary)
            }
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker(selection: state, label: EmptyView()) {
                ForEach(FlagState.allCases) { value in
                    Text(value.label).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    /// Reads the existing user override (if any) for this (provider, model) pair and
    /// initializes each tri-state to match. Missing override → all `.default`.
    private func loadFromShared() {
        let existing = shared.userModelOverrides[key]?.behaviorFlags
        glmTemplateSalvage = FlagState(existing?.glmTemplateSalvage)
        useMaxCompletionTokens = FlagState(existing?.useMaxCompletionTokens)
        disableParallelToolCalls = FlagState(existing?.disableParallelToolCalls)
    }

    /// Builds an override patch from the tri-state pickers and writes it. If every
    /// picker is at `.default` the call removes the entry (or no-ops if there wasn't
    /// one), keeping the on-disk overrides JSON tidy.
    private func save() {
        // Preserve any non-flag override fields the user already had on this entry —
        // we only edit `behaviorFlags`, not `displayName` / `maxInputTokens` / etc.
        let existing = shared.userModelOverrides[key]
        let flagsPatch = BehaviorFlagsOverride(
            glmTemplateSalvage: glmTemplateSalvage.asOptional,
            useMaxCompletionTokens: useMaxCompletionTokens.asOptional,
            disableParallelToolCalls: disableParallelToolCalls.asOptional
        )
        let merged = ModelMetadataOverride(
            displayName: existing?.displayName,
            maxInputTokens: existing?.maxInputTokens,
            maxOutputTokens: existing?.maxOutputTokens,
            sizeLabel: existing?.sizeLabel,
            capabilities: existing?.capabilities,
            pricing: existing?.pricing,
            supportsChatCompletions: existing?.supportsChatCompletions,
            behaviorFlags: flagsPatch.isEmpty ? nil : flagsPatch,
            // Every newer override field must ride along or a save here silently drops it.
            hidden: existing?.hidden,
            isAvailable: existing?.isAvailable,
            isAccessDenied: existing?.isAccessDenied
        )
        shared.setUserModelOverride(
            providerID: providerID,
            modelID: modelID,
            override: merged
        )
    }
}
