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
        TranscriptPaneHeader(title: "Session transcript") {
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
    }
}

/// The title strip above a transcript pane, with an optional trailing control.
///
/// Shared by both panes so the seam between them is legible. Previously only the lower pane carried
/// a title, and it sat on the same background as the messages — so the two transcripts ran together
/// and the boundary was a guess. The tint plus a rule makes each pane's start explicit, and giving
/// both panes the same chrome is what identifies them as two of a kind rather than one list with a
/// caption in the middle of it.
struct TranscriptPaneHeader<Trailing: View>: View {
    let title: String
    /// Draw a rule ABOVE the header too.
    ///
    /// Off by default because the lower pane sits directly under the split divider, where a second
    /// hairline only doubles the line. The UPPER pane needs it: with no task in flight the overlay
    /// bar is not rendered at all — it is gated on HAVING ENTRIES, not on the visibility preference
    /// — so in the app's resting state this header is the topmost thing in the column, with nothing
    /// above it to delimit it.
    var topRule: Bool = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        TranscriptPaneChrome(topRule: topRule) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                // Titles carry a task name, which can be a sentence. Without this the header
                // wraps to several lines in a narrow pane and eats the transcript's height —
                // and a header that grows is exactly the kind of content-driven sizing the
                // rest of this change is removing.
                .lineLimit(1)
                .truncationMode(.tail)
                .help(title)
            Spacer()
            trailing
        }
    }
}

/// The bar itself — tint, padding, and the rules — with no opinion about what sits in it.
///
/// Extracted so the plain session header and the task header below are the SAME bar rather than two
/// that resemble each other: the seam between the panes only reads if both sides match, and a
/// second hand-built copy is where that quietly stops being true.
struct TranscriptPaneChrome<Content: View>: View {
    var topRule: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            if topRule { Divider() }
            HStack(spacing: 6) { content }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppColors.secondaryBackground)
            // Always: this is what separates the header from the messages under it.
            Divider()
        }
    }
}

/// The upper pane's header: the task's own status chip and its title, styled as the transcript
/// styles that same title.
///
/// The sidebar and the transcript already agree on how a task is presented — the chip from the task
/// row, the bold monospaced orange the transcript uses for the task name in its sender slot. The
/// header said the same thing in plain secondary grey, so the eye had to re-learn it in a third
/// dialect. This is the same task, said the same way.
struct TaskTranscriptHeader: View {
    /// nil when the pane has no resolved task — the run-history and empty states.
    let task: AgentTask?

    var body: some View {
        TranscriptPaneChrome(topRule: true) {
            if let task {
                // The chip the sidebar row shows: the outcome once there is one, the lifecycle
                // status until then.
                if let outcome = task.outcome {
                    TaskOutcomeChip(outcome: outcome)
                } else {
                    TaskStatusChip(status: task.status)
                }
                Text(task.title)
                    // AppFonts.channelSender + the Brown/task orange: verbatim what the transcript
                    // below uses for this exact string in its sender slot.
                    .font(AppFonts.channelSender)
                    .foregroundStyle(AppColors.brownAgent)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(task.title)
            } else {
                Text("Task transcript")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

extension TranscriptPaneHeader where Trailing == EmptyView {
    init(title: String, topRule: Bool = false) {
        self.init(title: title, topRule: topRule) { EmptyView() }
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
