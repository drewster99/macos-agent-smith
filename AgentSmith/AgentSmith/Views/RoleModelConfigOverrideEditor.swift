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

    /// Standard adaptive-thinking effort levels; the model's own `validEffortLevels` decides which
    /// draw a warning, not which are offered (overrides are permissive).
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
            if selectedProviderSupportsThinking {
                effortRow()
                thinkingBudgetRow()
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

    private func effortRow() -> some View {
        overrideRow(
            title: "Thinking effort",
            help: "Adaptive-thinking depth. Off = the model / provider default.",
            isOn: Binding(get: { override.thinkingEffort != nil },
                          set: { override.thinkingEffort = $0 ? (modelInfo?.validEffortLevels.first ?? "high") : nil }),
            defaultText: "provider default",
            warning: warnings[.thinkingEffort]
        ) {
            Picker("", selection: Binding(get: { override.thinkingEffort ?? "high" }, set: { override.thinkingEffort = $0 })) {
                ForEach(Self.effortLevels, id: \.self) { level in
                    Text(effortLabel(level)).tag(level)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private func thinkingBudgetRow() -> some View {
        overrideRow(
            title: "Thinking budget",
            help: "Extended-thinking token budget (0 = off). On adaptive models it's a boolean on/off signal.",
            isOn: Binding(get: { override.thinkingBudget != nil },
                          set: { override.thinkingBudget = $0 ? 2048 : nil }),
            defaultText: "off",
            warning: nil
        ) {
            numberField(value: Binding(get: { override.thinkingBudget ?? 0 }, set: { override.thinkingBudget = max(0, $0) }))
        }
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

    private func effortLabel(_ level: String) -> String {
        guard let modelInfo, !modelInfo.validEffortLevels.isEmpty else { return level }
        return modelInfo.validEffortLevels.contains(level) ? level : "\(level)*"
    }

    /// Only Anthropic/Alibaba honor thinking today; hide the thinking rows elsewhere to keep the
    /// editor honest about what actually reaches the request.
    private var selectedProviderSupportsThinking: Bool {
        switch shared.llmKit.providers.first(where: { $0.id == providerID })?.apiType {
        case .anthropic, .alibabaCloud: return true
        default: return false
        }
    }
}
