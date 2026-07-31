import SwiftUI
import SwiftLLMKit

/// Shared building blocks for the per-(provider, model) override sheets — Behavior Flags,
/// Capabilities & Status, and Pricing. Extracting them is what makes those sheets read as one
/// family instead of three hand-synced twins that drifted (different resolved-label fonts, colors,
/// footer alignment). Each piece is a real `View` struct, not a `some View` helper, per the
/// project's SwiftUI rules.

// MARK: - Tri-state override

/// Inherit the resolved value, or force it on/off. One definition, replacing the per-sheet
/// `FlagState` copies that had drifted.
enum TriStateOverride: String, CaseIterable, Identifiable {
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

// MARK: - Resolved reference label

/// The monospaced "Resolved: ON / off / unknown" reference shown at the trailing edge of every
/// capability, status, and behavior-flag row — identical across sheets by construction. `nil` is
/// the genuinely-unknown tri-state (only Capabilities & Status can be unknown; behavior flags pass
/// a concrete Bool). Colors: ON green, off secondary, unknown tertiary.
struct ResolvedValueLabel: View {
    let resolved: Bool?

    var body: some View {
        switch resolved {
        case true?:
            Text("Resolved: ON").font(.caption.monospaced()).foregroundStyle(.green)
        case false?:
            Text("Resolved: off").font(.caption.monospaced()).foregroundStyle(.secondary)
        case nil:
            Text("Resolved: unknown").font(.caption.monospaced()).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Tri-state override row

/// One override row: bold title + resolved reference on the first line, a wrapped description, and a
/// segmented Default / Force-on / Force-off picker. Used by capability rows, status rows, and
/// behavior-flag rows.
struct OverrideTriStateRow: View {
    let title: String
    let resolved: Bool?
    let description: String
    @Binding var selection: TriStateOverride

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                ResolvedValueLabel(resolved: resolved)
            }
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("", selection: $selection) {
                ForEach(TriStateOverride.allCases) { value in
                    Text(value.label).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}

// MARK: - Sheet chrome

/// Pinned title bar shared by the override sheets: title + selectable "provider — model" subtitle,
/// and the Cancel / Done buttons. Done's behavior is the caller's (plain save vs. save-then-restart
/// notice), so both actions are injected.
struct OverrideSheetHeader: View {
    let title: String
    let subtitle: String
    let onCancel: () -> Void
    let onDone: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.bold())
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
            Button("Done", action: onDone).keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - Default / Override value control

/// Parsing + formatting helpers shared by the numeric override rows (token limits, prices), so the
/// same comma/`$` leniency applies everywhere.
enum OverrideValueParsing {
    static func tokenCount(_ raw: String) -> Int? {
        let cleaned = raw.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : Int(cleaned)
    }

    static func tokenDraft(_ value: Int) -> String { String(value) }
    static func tokenLabel(_ value: Int) -> String { value.formatted() }

    static func usdPerMillion(_ raw: String) -> Double? {
        let cleaned = raw.replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "$", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, let value = Double(cleaned), value >= 0, value.isFinite else { return nil }
        return value
    }

    static func usdDraft(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...4)).grouping(.never))
    }

    static func usdLabel(_ value: Double) -> String {
        "$" + value.formatted(.number.precision(.fractionLength(2...4)))
    }
}

/// A reusable "Default vs. Override" control for one optional value — a token limit or a price.
///
/// A two-segment Default / Override picker replaces the old "value + empty field + Prefill button"
/// row. Choosing **Override** reveals a focused field seeded with the default, plus an **OK** commit
/// (Enter commits too); OK validates via `parse`, stores the value, and flips to a clickable
/// formatted label + a green check. Clicking the label re-opens editing. Switching back to
/// **Default** reveals a **Confirm** button that clears the override (`override = nil`). The default
/// itself is shown by the CALLER (e.g. "Model reports:" in the row header), not here.
struct OverrideValueControl<Value: Equatable>: View {
    @Binding var override: Value?
    let defaultValue: Value?
    /// Plain, editable text seeded into the field (no grouping / symbols).
    let draftText: (Value) -> String
    /// Pretty text for the committed, clickable label.
    let format: (Value) -> String
    let parse: (String) -> Value?
    /// Bumped by the parent's Reset/Clear so the control fully resyncs — needed because a reset that
    /// leaves an already-`nil` override unchanged emits no `override` change to observe.
    var resetToken: Int = 0

    private enum Stage: Equatable { case inactive, editing, committed, pendingClear }
    private enum Segment: Hashable { case useDefault, useOverride }

    @State private var stage: Stage = .inactive
    @State private var draft: String = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: segmentSelection) {
                Text("Default").tag(Segment.useDefault)
                Text("Override").tag(Segment.useOverride)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            switch stage {
            case .inactive:
                EmptyView()
            case .editing:
                TextField("value", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
                    .focused($fieldFocused)
                    .onSubmit { commit() }
                Button("OK", action: commit)
                    .controlSize(.small)
                    .disabled(parse(draft) == nil)
            case .committed:
                Button(action: reopen) {
                    Text(override.map(format) ?? "—").font(.body.monospacedDigit())
                }
                .buttonStyle(.plain)
                .help("Click to edit this override")
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .pendingClear:
                Button("Confirm", action: clearOverride).controlSize(.small)
            }
        }
        .onAppear { stage = override == nil ? .inactive : .committed }
        .onChange(of: override) { _, newValue in
            // Resync when the value is cleared from OUTSIDE (e.g. the sheet's Reset button) from any
            // non-inactive stage, including pendingClear.
            if newValue == nil, stage != .inactive {
                DispatchQueue.main.async { stage = .inactive }
            }
        }
        .onChange(of: resetToken) { _, _ in
            // Catches the case `onChange(of: override)` cannot: a reset that leaves an uncommitted
            // (already-nil) override in place, which would otherwise strand an open editing field.
            DispatchQueue.main.async { stage = override == nil ? .inactive : .committed }
        }
    }

    private var segmentSelection: Binding<Segment> {
        Binding(
            get: { (stage == .editing || stage == .committed) ? .useOverride : .useDefault },
            set: { newValue in
                switch newValue {
                case .useOverride:
                    // From pendingClear, restore the committed value if there is one; otherwise
                    // (or from inactive) open a fresh editing field seeded with the default.
                    if stage == .pendingClear, override != nil {
                        stage = .committed
                    } else if stage != .editing && stage != .committed {
                        draft = (override ?? defaultValue).map(draftText) ?? ""
                        stage = .editing
                        focusSoon()
                    }
                case .useDefault:
                    if stage == .editing || stage == .committed { stage = .pendingClear }
                }
            })
    }

    private func commit() {
        guard let parsed = parse(draft) else { return }
        override = parsed
        stage = .committed
        fieldFocused = false
    }

    private func reopen() {
        draft = override.map(draftText) ?? ""
        stage = .editing
        focusSoon()
    }

    private func clearOverride() {
        override = nil
        stage = .inactive
    }

    private func focusSoon() {
        DispatchQueue.main.async { fieldFocused = true }
    }
}

/// Pinned footer shared by the override sheets: a Reset-to-defaults button on the left and a
/// right-hugged explanation whose LINES are left-aligned (so wrapped text lines up under its own
/// first line rather than ragged-right).
struct OverrideSheetFooter: View {
    var resetTitle: String = "Reset to defaults"
    let explanation: String
    let resetDisabled: Bool
    let onReset: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Button(resetTitle, action: onReset)
                .disabled(resetDisabled)
            Spacer()
            Text(explanation)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: 300, alignment: .leading)
        }
    }
}
