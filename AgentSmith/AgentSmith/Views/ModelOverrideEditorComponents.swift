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
