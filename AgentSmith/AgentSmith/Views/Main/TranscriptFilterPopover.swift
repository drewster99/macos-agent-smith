import SwiftUI
import AgentSmithKit

/// A thin header strip above the bottom transcript pane carrying the filter-config button. The funnel
/// fills when the config differs from the show-everything default — in practice "messages are being
/// hidden", though a customization that happens to show everything (e.g. a sender override still equal
/// to the default it was copied from) fills it too: the icon tracks configuration, not message counts.
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

/// The message-kind checklist with a SCOPE picker above it: "All senders" edits the default
/// selection; picking a sender edits (or creates) that sender's override, so any sender can show
/// a different set of kinds than the rest of the transcript. The checklist itself is one shared
/// component bound to whichever scope's `TranscriptKindSelection` is being edited.
private struct TranscriptKindGroupSection: View {
    @Binding var config: TranscriptViewConfig
    /// nil = the default ("All senders") scope.
    @State private var scopeSender: ChannelMessage.Sender?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Message kinds")
                .font(.headline)
            Picker("For", selection: $scopeSender) {
                Text("All senders").tag(ChannelMessage.Sender?.none)
                ForEach(TranscriptViewConfig.selectableSenders, id: \.self) { sender in
                    // Mark customized senders right in the picker, so an override you set last
                    // week is findable without clicking through every sender.
                    Text(config.hasKindOverride(forSender: sender)
                         ? "\(sender.displayName) — custom"
                         : sender.displayName)
                        .tag(ChannelMessage.Sender?.some(sender))
                }
            }
            .pickerStyle(.menu)

            if let sender = scopeSender, !config.hasKindOverride(forSender: sender) {
                // No override yet: say what governs this sender, and offer to branch from it.
                // The override starts as a COPY of the current default, so customizing never
                // changes what's on screen until a toggle is actually flipped.
                Text("\(sender.displayName) follows the All-senders selection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Customize for \(sender.displayName)") {
                    config.setKindSelection(config.defaultKinds, forSender: sender)
                }
            } else {
                if let sender = scopeSender {
                    HStack {
                        Text("Custom selection for \(sender.displayName).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset to All senders") {
                            config.removeKindOverride(forSender: sender)
                        }
                        .font(.caption)
                    }
                }
                TranscriptKindChecklist(selection: selectionBinding)
            }
        }
    }

    /// The edited scope's selection, routed through the config's scope accessors so the override
    /// map stays the only storage.
    private var selectionBinding: Binding<TranscriptKindSelection> {
        Binding(
            get: { config.kindSelection(forSender: scopeSender) },
            set: { config.setKindSelection($0, forSender: scopeSender) }
        )
    }
}

/// The Chat (kindless) toggle plus one row per group with a tri-state checkbox that expands to a
/// per-kind toggle for every `ChannelMessageKind` — each kind individually filterable, the group
/// checkbox a convenience over the per-kind truth, not a separate switch.
private struct TranscriptKindChecklist: View {
    @Binding var selection: TranscriptKindSelection

    /// Every group except Chat, which renders as its own toggle above. Static so the ForEach
    /// iterates a stored constant instead of re-filtering `allCases` on every body evaluation.
    private static let kindGroups = TranscriptKindGroup.allCases.filter { !$0.governsKindless }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $selection.showsChat) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(TranscriptKindGroup.chat.displayName)
                    Text(TranscriptKindGroup.chat.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(Self.kindGroups) { group in
                TranscriptKindGroupRow(group: group, selection: $selection)
            }
        }
    }
}

/// One kind-group: tri-state checkbox in the disclosure label, per-kind toggles inside.
private struct TranscriptKindGroupRow: View {
    let group: TranscriptKindGroup
    @Binding var selection: TranscriptKindSelection
    @State private var isExpanded = false

    /// Wire order is stable and clusters families (`task_*`, `validation_*`) — good enough
    /// ordering, and it never shuffles when display labels get reworded. Stored at init rather
    /// than computed: a computed collection fed to ForEach re-sorts on every body evaluation.
    private let orderedKinds: [ChannelMessageKind]

    init(group: TranscriptKindGroup, selection: Binding<TranscriptKindSelection>) {
        self.group = group
        self._selection = selection
        self.orderedKinds = group.kinds.sorted { $0.rawValue < $1.rawValue }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(orderedKinds, id: \.self) { kind in
                    Toggle(isOn: kindBinding(kind)) {
                        Text(kind.transcriptFilterLabel)
                    }
                    // The wire string, for when "which kind is this exactly?" matters.
                    .help(kind.rawValue)
                }
            }
            .padding(.top, 4)
            .padding(.leading, 4)
        } label: {
            HStack(spacing: 6) {
                GroupTriStateCheckbox(state: selection.groupVisibility(of: group)) { makeAllVisible in
                    selection.setGroup(group, visible: makeAllVisible)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.displayName)
                    Text(detailLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// A mixed group says WHICH FRACTION shows — the group's stock description would misread as
    /// "all of this is on".
    private var detailLine: String {
        guard selection.groupVisibility(of: group) == .mixed else { return group.detail }
        let visible = group.kinds.count - group.kinds.intersection(selection.hiddenKinds).count
        return "\(visible) of \(group.kinds.count) kinds shown"
    }

    private func kindBinding(_ kind: ChannelMessageKind) -> Binding<Bool> {
        Binding(
            get: { selection.isKindVisible(kind) },
            set: { isOn in selection.setKind(kind, visible: isOn) }
        )
    }
}

/// The group checkbox: checked (all kinds shown), unchecked (none), or dash (mixed). Clicking a
/// fully-checked group hides all its kinds; clicking a mixed or empty one shows them all.
private struct GroupTriStateCheckbox: View {
    let state: TranscriptKindSelection.GroupVisibility
    let onSetAll: (Bool) -> Void

    var body: some View {
        Button {
            onSetAll(state != .all)
        } label: {
            Image(systemName: symbolName)
                .foregroundStyle(state == .none ? Color.secondary : Color.accentColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state == .all ? "Hide all" : "Show all")
    }

    private var symbolName: String {
        switch state {
        case .all: return "checkmark.square.fill"
        case .mixed: return "minus.square.fill"
        case .none: return "square"
        }
    }
}

extension ChannelMessageKind {
    /// Reader-facing label for the per-kind filter rows, derived from the wire string so a newly
    /// added kind gets a label with no table to update. Only the pairs that would read as
    /// duplicates — and the acronym — get explicit wording.
    var transcriptFilterLabel: String {
        switch self {
        case .taskComplete: return "Task complete (worker submission)"
        case .taskCompleted: return "Task completed (final state)"
        case .taskLifecycle: return "Task lifecycle (informational)"
        case .mcpStatus: return "MCP status"
        default:
            let words = rawValue.split(separator: "_").joined(separator: " ")
            return words.prefix(1).uppercased() + words.dropFirst()
        }
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
