import SwiftUI
import AgentSmithKit

/// A thin header strip above the bottom transcript pane carrying the filter-config button. The funnel
/// fills when the pane is showing anything less than the full firehose, so it's obvious at a glance that
/// messages are being hidden.
struct TranscriptFilterBar: View {
    @Binding var config: TranscriptViewConfig
    @State private var showPopover = false

    private var isFiltering: Bool { config != .everything }

    var body: some View {
        HStack(spacing: 6) {
            Text("Session transcript")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                showPopover = true
            } label: {
                Image(systemName: isFiltering
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle")
            }
            .buttonStyle(.borderless)
            .help("Choose which messages this pane shows")
            .popover(isPresented: $showPopover, arrowEdge: .top) {
                TranscriptFilterPopover(config: $config)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

/// The bottom pane's filter configuration UI: toggle message-kind groups, senders, recipients, scope,
/// errors, and public/private, with two one-click presets. Edits apply live — each toggle mutates the
/// bound `TranscriptViewConfig`, whose didSet repoints the pane's provider off-main.
struct TranscriptFilterPopover: View {
    @Binding var config: TranscriptViewConfig

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                TranscriptFilterPresetRow(config: $config)
                Divider()
                TranscriptScopeSection(config: $config)
                Divider()
                TranscriptSenderSection(config: $config)
                Divider()
                TranscriptRecipientSection(config: $config)
                Divider()
                TranscriptKindGroupSection(config: $config)
                Divider()
                TranscriptVisibilitySection(config: $config)
            }
            .padding()
        }
        .frame(width: 400, height: 620)
    }
}

/// The scope switches that carry most of the default's weight: hide everything tied to a specific task
/// (the top pane owns per-task history), and show/hide error messages.
private struct TranscriptScopeSection: View {
    @Binding var config: TranscriptViewConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scope")
                .font(.headline)
            Toggle(isOn: $config.hideTaskScoped) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Hide task-specific messages")
                    Text("Only the Smith ↔ you orchestration layer — per-task work shows in the top pane")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $config.showErrors) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Show errors")
                    Text("Provider failures, out-of-credits notices, and other flagged errors")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The message-kind group checklist.
private struct TranscriptKindGroupSection: View {
    @Binding var config: TranscriptViewConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Message kinds")
                .font(.headline)
            ForEach(TranscriptKindGroup.allCases) { group in
                Toggle(isOn: binding(for: group)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.displayName)
                        Text(group.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func binding(for group: TranscriptKindGroup) -> Binding<Bool> {
        Binding(
            get: { config.visibleGroups.contains(group) },
            set: { isOn in
                if isOn { config.visibleGroups.insert(group) } else { config.visibleGroups.remove(group) }
            }
        )
    }
}

/// The sender allow-list. `nil` (every sender) is shown as all-on; turning any off materializes the
/// explicit set, and turning them all back on collapses to `nil`.
private struct TranscriptSenderSection: View {
    @Binding var config: TranscriptViewConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Senders")
                .font(.headline)
            ForEach(TranscriptViewConfig.selectableSenders, id: \.self) { sender in
                Toggle(sender.displayName, isOn: binding(for: sender))
            }
        }
    }

    private func binding(for sender: ChannelMessage.Sender) -> Binding<Bool> {
        Binding(
            get: {
                guard let allowed = config.allowedSenders else { return true }
                return allowed.contains(sender)
            },
            set: { isOn in
                var allowed = config.allowedSenders ?? Set(TranscriptViewConfig.selectableSenders)
                if isOn { allowed.insert(sender) } else { allowed.remove(sender) }
                config.allowedSenders =
                    allowed == Set(TranscriptViewConfig.selectableSenders) ? nil : allowed
            }
        )
    }
}

/// The recipient allow-list. Filters PRIVATE (addressed) messages only — a public message always shows.
/// `nil` (every recipient) is all-on; turning any off materializes the set; all-on collapses to `nil`.
/// This is the axis that hides everything addressed TO a worker, which the sender axis can't.
private struct TranscriptRecipientSection: View {
    @Binding var config: TranscriptViewConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recipients")
                .font(.headline)
            Text("Filters messages addressed to a specific agent. Public messages always show.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(TranscriptViewConfig.selectableRecipients, id: \.self) { recipient in
                Toggle(recipient.displayName, isOn: binding(for: recipient))
            }
        }
    }

    private func binding(for recipient: MessageRecipient) -> Binding<Bool> {
        Binding(
            get: {
                guard let allowed = config.allowedRecipients else { return true }
                return allowed.contains(recipient)
            },
            set: { isOn in
                var allowed = config.allowedRecipients ?? Set(TranscriptViewConfig.selectableRecipients)
                if isOn { allowed.insert(recipient) } else { allowed.remove(recipient) }
                config.allowedRecipients =
                    allowed == Set(TranscriptViewConfig.selectableRecipients) ? nil : allowed
            }
        )
    }
}

/// The public / private / all selector.
private struct TranscriptVisibilitySection: View {
    @Binding var config: TranscriptViewConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Visibility")
                .font(.headline)
            Picker("Visibility", selection: $config.visibility) {
                Text("All").tag(TranscriptFilter.Visibility.all)
                Text("Public only").tag(TranscriptFilter.Visibility.publicOnly)
                Text("Private only").tag(TranscriptFilter.Visibility.privateOnly)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}

/// One-click presets: the readable conversation default, or the full firehose.
private struct TranscriptFilterPresetRow: View {
    @Binding var config: TranscriptViewConfig

    var body: some View {
        HStack {
            Button("Conversation") { config = .conversation }
            Button("Show everything") { config = .everything }
            Spacer()
        }
        .controlSize(.small)
    }
}
