import SwiftUI
import SwiftLLMKit
import AgentSmithKit

/// Per-(role, model) RUNTIME override editor. Each setting inherits the model's resolved default
/// unless the user flips "Override" and enters a value. Overrides are PERMISSIVE — a value may
/// exceed what the catalog believes about the model (it may be wrong) — but an out-of-range value
/// shows a non-blocking warning. Everything resolves fresh against the latest model facts; the
/// stored override holds only the deltas (see ``ModelConfigurationOverride``).
struct RoleModelConfigOverrideEditor: View {
    @Bindable var shared: SharedAppState
    let role: AgentRole
    let providerID: String
    let modelID: String

    @State private var override = ModelConfigurationOverride()

    /// Standard effort levels; the model's own ``EffortSupport`` decides which draw a warning,
    /// not which are offered (overrides are permissive).
    private static let effortLevels = ["low", "medium", "high", "xhigh", "max"]

    private var modelInfo: ModelInfo? {
        shared.llmKit.modelInfo(providerID: providerID, modelID: modelID)
    }

    private var warnings: [OverrideWarning.Field: String] {
        guard let modelInfo else { return [:] }
        return Dictionary(override.warnings(against: modelInfo).map { ($0.field, $0.message) },
                          uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header()

            temperatureRow()
            maxOutputRow()
            maxContextRow()
            // Per-row, per-MODEL gating from the probed/decoded facts — the old gate was a
            // provider allowlist ("Anthropic/Alibaba"), which hid the thinking switch from every
            // reasoning-capable model on other providers and showed effort to models that reject
            // it. Each row's rule mirrors the EMISSION rule for its field, so a visible control
            // is one that can actually reach the wire:
            //  - Thinking: always visible — its status line is the place that says on / off /
            //    unsupported / unknown, and "unsupported" is an answer, not an absence.
            //  - Budget: only for mechanisms that carry one (plus the legacy Anthropic/Alibaba
            //    fallback for models whose mechanism is unrecorded — emission honors it there).
            //  - Effort (general): hidden only when KNOWN-unsupported; emission fails open.
            //  - Effort (reasoning): shown only when KNOWN-supported; emission fails closed, so
            //    a control shown on an unknown ladder would silently do nothing.
            thinkingRow()
            if showsThinkingBudgetRow {
                thinkingBudgetRow()
            }
            if modelInfo?.generalEffort?.isSupported != false {
                effortRow()
            }
            if modelInfo?.reasoningEffort?.isSupported == true {
                reasoningEffortRow()
            }
            togglesRow()
        }
        .onAppear {
            override = shared.roleModelConfigOverride(role: role, providerID: providerID, modelID: modelID)
        }
        .onChange(of: override) { _, newValue in
            // Save only genuine user edits — the onAppear load sets `override` to the stored value,
            // which compares equal and no-ops.
            guard newValue != shared.roleModelConfigOverride(role: role, providerID: providerID, modelID: modelID) else { return }
            shared.setRoleModelConfigOverride(role: role, providerID: providerID, modelID: modelID, override: newValue)
        }
    }

    private func header() -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Runtime settings — \(role.displayName)")
                .font(.subheadline.bold())
            Text("Each setting uses \(modelInfo?.displayName ?? modelID)'s default unless you override it. Applies wherever \(role.displayName) runs this model.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Rows

    private func temperatureRow() -> some View {
        overrideRow(
            title: "Temperature",
            help: "Sampling randomness. Model default is used when off.",
            isOn: Binding(get: { override.temperature != nil },
                          set: { override.temperature = $0 ? (modelInfo?.samplingDefaults?.temperature ?? 0.7) : nil }),
            defaultText: modelInfo?.samplingDefaults?.temperature.map { String(format: "%.2f", $0) } ?? "provider default",
            warning: warnings[.temperature]
        ) {
            HStack(spacing: 10) {
                Slider(value: Binding(get: { override.temperature ?? 0.7 }, set: { override.temperature = $0 }),
                       in: 0...2, step: 0.05)
                Text(String(format: "%.2f", override.temperature ?? 0.7))
                    .font(.callout.monospaced()).frame(width: 44, alignment: .trailing)
            }
        }
    }

    private func maxOutputRow() -> some View {
        overrideRow(
            title: "Max output tokens",
            help: "Ceiling for a single response. Off = the model's reported maximum.",
            isOn: Binding(get: { override.maxOutputTokens != nil },
                          set: { override.maxOutputTokens = $0 ? (modelInfo?.maxOutputTokens ?? 4096) : nil }),
            defaultText: modelInfo?.maxOutputTokens.map { "\($0.formatted()) tokens" } ?? "unknown",
            warning: warnings[.maxOutputTokens]
        ) {
            numberField(value: Binding(get: { override.maxOutputTokens ?? 4096 }, set: { override.maxOutputTokens = max(1, $0) }))
        }
    }

    private func maxContextRow() -> some View {
        overrideRow(
            title: "Max context tokens",
            help: "Conversation-pruning budget. Off = the model's reported context window.",
            isOn: Binding(get: { override.maxContextTokens != nil },
                          set: { override.maxContextTokens = $0 ? (modelInfo?.maxInputTokens ?? 128_000) : nil }),
            defaultText: modelInfo?.maxInputTokens.map { "\($0.formatted()) tokens" } ?? "unknown",
            warning: warnings[.maxContextTokens]
        ) {
            numberField(value: Binding(get: { override.maxContextTokens ?? 128_000 }, set: { override.maxContextTokens = max(1, $0) }))
        }
    }

    /// GENERAL effort — Anthropic's `output_config.effort`, which applies even with reasoning off.
    /// Separate from the reasoning row below because they are different wire parameters with
    /// different ladders; one control for both was how they got conflated in the first place.
    private func effortRow() -> some View {
        overrideRow(
            title: "Effort (general)",
            help: "Overall effort. Applies even when reasoning is off. Off = the model / provider default.",
            isOn: Binding(get: { override.effort != nil },
                          set: { override.effort = $0 ? (modelInfo?.generalEffort?.knownLevels?.first ?? "high") : nil }),
            defaultText: "provider default",
            warning: warnings[.effort]
        ) {
            Picker("", selection: Binding(get: { override.effort ?? "high" }, set: { override.effort = $0 })) {
                ForEach(Self.effortLevels, id: \.self) { level in
                    Text(effortLabel(level, modelInfo?.generalEffort)).tag(level)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    // MARK: Thinking

    /// The model's reasoning mechanism, honoring the legacy adaptive behavior flag exactly the way
    /// emission does — a hand-set flag predates the probe's discovery and must keep working.
    private var reasoningControl: ReasoningControl? {
        modelInfo?.reasoningControl
            ?? (modelInfo?.behaviorFlags.requiresAdaptiveThinking == true ? .anthropicAdaptiveThinking : nil)
    }

    /// What the CURRENT settings will actually do about thinking — resolved by the library's
    /// `plannedThinkingState`, the same rules emission applies, so this display cannot drift
    /// from the wire.
    private var plannedThinking: PlannedThinkingState {
        ReasoningControl.plannedThinkingState(
            control: reasoningControl,
            capabilities: modelInfo?.capabilities ?? ModelCapabilities(),
            reasoningEnabled: override.reasoningEnabled,
            thinkingBudget: override.thinkingBudget,
            reasoningEffort: override.reasoningEffort,
            reasoningEffortSupport: modelInfo?.reasoningEffort)
    }

    /// Budget shown for mechanisms that carry one, plus the legacy Anthropic/Alibaba fallback for
    /// unrecorded mechanisms (emission honors a budget there via the apiType fallback).
    private var showsThinkingBudgetRow: Bool {
        if let control = reasoningControl { return control.carriesTokenBudget }
        switch shared.llmKit.providers.first(where: { $0.id == providerID })?.apiType {
        case .anthropic, .alibabaCloud: return true
        default: return false
        }
    }

    /// The thinking SWITCH (Default / On / Off) with the ACTUAL resolved state underneath.
    /// Permissive like every other row: choosing a direction the model was measured unable to
    /// switch shows the warning and the honest "nothing sent" status instead of being disabled.
    private func thinkingRow() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Thinking").font(.headline)
                Spacer()
                if reasoningControl != nil && reasoningControl != .unsupported {
                    Picker("", selection: Binding(
                        get: { override.reasoningEnabled },
                        set: { newValue in
                            override.reasoningEnabled = newValue
                            // Forcing ON on a mechanism that emits nothing without a budget
                            // (Anthropic's budgeted thinking) seeds one, so On means on.
                            if newValue == true, reasoningControl == .anthropicThinking,
                               override.thinkingBudget == nil {
                                override.thinkingBudget = max(modelInfo?.minThinkingBudgetTokens ?? 0, 2048)
                            }
                        })) {
                        Text("Default").tag(Bool?.none)
                        Text("On").tag(Bool?.some(true))
                        Text("Off").tag(Bool?.some(false))
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
            }
            // The ACTUAL state — on / off / unsupported / unknown — never the wish. This line is
            // the whole point of the row: what the next request will do, with the wire form named.
            HStack(spacing: 5) {
                Image(systemName: plannedThinkingSymbol).font(.caption)
                Text(plannedThinking.detail.isEmpty
                     ? "Thinking \(plannedThinking.label)"
                     : "Thinking \(plannedThinking.label) — \(plannedThinking.detail)")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.secondary)
            if let warning = warnings[.reasoningEnabled] {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color.secondary.opacity(override.reasoningEnabled != nil ? 0.10 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(warnings[.reasoningEnabled] == nil ? Color.clear : Color.orange.opacity(0.4), lineWidth: 1))
    }

    private var plannedThinkingSymbol: String {
        switch plannedThinking {
        case .on: return "brain.head.profile"
        case .off: return "brain.head.profile.fill"
        case .unsupported: return "nosign"
        case .unknown: return "questionmark.circle"
        }
    }

    private func thinkingBudgetRow() -> some View {
        overrideRow(
            title: "Thinking budget",
            help: budgetHelp,
            isOn: Binding(get: { override.thinkingBudget != nil },
                          set: { override.thinkingBudget = $0
                              ? max(modelInfo?.minThinkingBudgetTokens ?? 0, 2048) : nil }),
            defaultText: "model default",
            warning: warnings[.thinkingBudget]
        ) {
            numberField(value: Binding(get: { override.thinkingBudget ?? 0 }, set: { override.thinkingBudget = max(0, $0) }))
        }
    }

    /// Depth only — on/off belongs to the Thinking switch above ("0 = off" was never true for
    /// most mechanisms; a zero budget emits nothing, which is model-default, not off). The
    /// measured range is stated so an out-of-range entry is a choice, not a surprise.
    private var budgetHelp: String {
        var help = reasoningControl == .anthropicAdaptiveThinking
            ? "Adaptive model — the budget acts as an on-signal; depth is the model's own choice."
            : "Extended-thinking token depth. On/off is the Thinking switch above."
        if let floor = modelInfo?.minThinkingBudgetTokens, let ceiling = modelInfo?.maxThinkingBudgetTokens {
            help += " Measured range \(floor.formatted()) – \(ceiling.formatted())."
        } else if let ceiling = modelInfo?.maxThinkingBudgetTokens {
            help += " Measured maximum \(ceiling.formatted())."
        }
        return help
    }

    private func togglesRow() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            optionalToggleRow(title: "Extended cache TTL (1 hour)",
                              help: "Anthropic only; cached tokens cost 2× base input.",
                              value: $override.extendedCacheTTL, defaultOn: false)
            optionalToggleRow(title: "Streaming",
                              help: "Request streaming responses.",
                              value: $override.streaming, defaultOn: true)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    // MARK: Reusable pieces

    @ViewBuilder
    private func overrideRow<Control: View>(
        title: String,
        help: String,
        isOn: Binding<Bool>,
        defaultText: String,
        warning: String?,
        @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                Toggle("Override", isOn: isOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help("Override the model default")
            }
            Text(help).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if isOn.wrappedValue {
                control()
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle").font(.caption)
                    Text("Default · \(defaultText)").font(.callout.monospaced())
                }
                .foregroundStyle(.secondary)
            }
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(isOn.wrappedValue ? 0.10 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(warning == nil ? Color.clear : Color.orange.opacity(0.4), lineWidth: 1))
    }

    private func optionalToggleRow(title: String, help: String, value: Binding<Bool?>, defaultOn: Bool) -> some View {
        let isOverridden = value.wrappedValue != nil
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(isOverridden ? help : "Default · \(defaultOn ? "on" : "off")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isOverridden {
                Toggle("", isOn: Binding(get: { value.wrappedValue ?? defaultOn }, set: { value.wrappedValue = $0 }))
                    .labelsHidden()
            }
            Toggle("Override", isOn: Binding(get: { isOverridden }, set: { value.wrappedValue = $0 ? defaultOn : nil }))
                .toggleStyle(.switch).labelsHidden().help("Override the model default")
        }
    }

    private func numberField(value: Binding<Int>) -> some View {
        TextField("", value: value, format: .number)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 160, alignment: .leading)
    }

    /// REASONING effort — `reasoning_effort` on OpenAI-compatible endpoints. Only meaningful for
    /// reasoning models, which is why it is gated separately from the general row above: a model
    /// may accept one and reject the other with HTTP 400.
    private func reasoningEffortRow() -> some View {
        overrideRow(
            title: "Effort (reasoning)",
            help: "Reasoning depth (`reasoning_effort`). Off = the model / provider default.",
            isOn: Binding(get: { override.reasoningEffort != nil },
                          set: { override.reasoningEffort = $0 ? (modelInfo?.reasoningEffort?.knownLevels?.first ?? "high") : nil }),
            defaultText: "provider default",
            warning: warnings[.reasoningEffort]
        ) {
            Picker("", selection: Binding(get: { override.reasoningEffort ?? "high" },
                                          set: { override.reasoningEffort = $0 })) {
                ForEach(Self.effortLevels, id: \.self) { level in
                    Text(effortLabel(level, modelInfo?.reasoningEffort)).tag(level)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 160, alignment: .leading)
        }
    }

    /// Marks a level the model's own record does not list. `rejects` fails safe, so a model with
    /// an unknown ladder marks nothing — an asterisk there would invent a warning.
    private func effortLabel(_ level: String, _ support: EffortSupport?) -> String {
        guard let support else { return level }
        return support.rejects(level) ? "\(level)*" : level
    }

}
