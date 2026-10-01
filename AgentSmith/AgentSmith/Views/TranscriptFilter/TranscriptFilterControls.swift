import SwiftUI
import AgentSmithKit

/// A filter section's label: small, uppercase, secondary — headings that organize without competing
/// with the controls under them.
struct FilterSectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(AppFonts.filterSectionLabel)
            .tracking(0.5)
            .foregroundStyle(.secondary)
    }
}

/// One line of secondary explanation under a control.
struct FilterCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The checkbox glyph for an aggregate: checked (all shown), dash (some), empty (none).
struct TriStateGlyph: View {
    let state: TranscriptKindSelection.GroupVisibility

    var body: some View {
        Image(systemName: symbolName)
            .foregroundStyle(state == .none ? Color.secondary : Color.accentColor)
            .accessibilityHidden(true)
    }

    private var symbolName: String {
        switch state {
        case .all: return "checkmark.square.fill"
        case .mixed: return "minus.square.fill"
        case .none: return "square"
        }
    }
}

/// A standalone tri-state checkbox. Clicking a fully-checked box hides everything it covers;
/// clicking a mixed or empty one shows everything.
struct TriStateCheckbox: View {
    let state: TranscriptKindSelection.GroupVisibility
    let accessibilityName: String
    let onSet: (Bool) -> Void

    var body: some View {
        Button(action: {
            onSet(state != .all)
        }, label: {
            TriStateGlyph(state: state)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        })
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(state.accessibilityDescription)
    }
}

/// The expand/collapse chevron. Occupies its width even when there is nothing to expand, so titles
/// at the same depth line up.
struct DisclosureChevron: View {
    let isExpandable: Bool
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action, label: {
            Image(systemName: "chevron.right")
                .font(AppFonts.metaIconSmall)
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 12, height: 16)
                .contentShape(Rectangle())
        })
        .buttonStyle(.plain)
        .opacity(isExpandable ? 1 : 0)
        .disabled(!isExpandable)
        .accessibilityLabel(isExpanded ? "Collapse" : "Expand")
    }
}

/// A participant toggle: the participant's own transcript color when shown, an empty outline when
/// hidden. The count says how many messages in scope involve them, so hiding one is a known cost.
struct ParticipantChip: View {
    @Binding var config: TranscriptViewConfig
    let participant: ChannelMessage.Sender
    let count: Int?

    private var isShown: Bool { config.isParticipantShown(participant) }

    var body: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) { config.setParticipant(participant, shown: !isShown) }
        }, label: {
            ParticipantChipLabel(participant: participant, isShown: isShown, count: count)
        })
        .buttonStyle(.plain)
        .help(isShown
              ? "Hide messages from and to \(participant.filterName)"
              : "Show messages from and to \(participant.filterName)")
        .accessibilityLabel(participant.filterName)
        .accessibilityValue(isShown ? "Shown" : "Hidden")
    }
}

private struct ParticipantChipLabel: View {
    let participant: ChannelMessage.Sender
    let isShown: Bool
    let count: Int?

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .strokeBorder(AppColors.color(for: participant), lineWidth: isShown ? 0 : 1.5)
                .background(Circle().fill(isShown ? AppColors.color(for: participant) : .clear))
                .frame(width: 8, height: 8)
            Text(participant.filterName)
                .foregroundStyle(isShown ? .primary : .secondary)
            Text(count.map { $0.formatted() } ?? "")
                .font(AppFonts.filterCount)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(isShown ? AppColors.participantChipFill(for: participant) : .clear))
        .overlay(Capsule().strokeBorder(isShown
                                        ? AppColors.participantChipStroke(for: participant)
                                        : AppColors.participantChipOffStroke))
        .contentShape(Capsule())
    }
}

extension TranscriptKindSelection.GroupVisibility {
    var accessibilityDescription: String {
        switch self {
        case .all: return "Shown"
        case .mixed: return "Partly shown"
        case .none: return "Hidden"
        }
    }
}
