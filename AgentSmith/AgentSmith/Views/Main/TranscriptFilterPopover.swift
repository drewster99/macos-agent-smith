import SwiftUI
import AgentSmithKit

/// A thin header strip above the bottom transcript pane carrying the filter-config button. The funnel
/// fills when the config differs from the show-everything default — in practice "messages are being
/// hidden", though a customization that happens to show everything (e.g. a sender override still equal
/// to the default it was copied from) fills it too: the icon tracks configuration, not message counts.
struct TranscriptFilterBar: View {
    @Binding var config: TranscriptViewConfig

    var body: some View {
        TranscriptPaneHeader(title: "Session transcript") {
            TranscriptFilterButton(config: $config)
        }
    }
}

/// The funnel button and its popover, with no opinion about which pane it sits in.
///
/// Extracted so the task pane and the session pane carry the SAME control over their OWN configs.
/// The task pane briefly got this by reusing `TranscriptFilterBar` wholesale, which also dragged
/// along that bar's hardcoded "Session transcript" title and stacked a second header under the
/// task's own — two bars, one of them lying about which pane it belonged to.
struct TranscriptFilterButton: View {
    @Binding var config: TranscriptViewConfig
    @State private var showPopover = false

    private var isFiltering: Bool { config != .everything }

    var body: some View {
        Button(action: {
            showPopover = true
        }, label: {
            Image(systemName: isFiltering
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle")
        })
        .buttonStyle(.borderless)
        .help("Choose which messages this pane shows")
        .popover(isPresented: $showPopover, arrowEdge: .top) {
            TranscriptFilterPopover(config: $config)
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
    /// THIS pane's filter config — `taskTranscriptViewConfig`, never the session pane's.
    @Binding var config: TranscriptViewConfig

    var body: some View {
        TranscriptPaneChrome(topRule: true) {
            TaskTranscriptHeaderLabel(task: task)
            Spacer()
            TranscriptFilterButton(config: $config)
        }
    }
}

/// Names the pane: the task's status chip and title, or a plain caption when nothing is resolved.
///
/// Its own `View` struct rather than a branch inside the header's body — adding the filter button
/// pushed that body past the 20-line limit, and the label is the part with an identity of its own.
private struct TaskTranscriptHeaderLabel: View {
    let task: AgentTask?

    var body: some View {
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
            CaptionedToggle(
                isOn: $config.hideTaskScoped,
                title: "Hide task-specific messages",
                detail: "Only the Smith ↔ you orchestration layer — per-task work shows in the top pane"
            )
            CaptionedToggle(
                isOn: $config.showErrors,
                title: "Show errors",
                detail: "Provider failures, out-of-credits notices, and other flagged errors"
            )
            SeverityFloorPicker(floor: $config.alwaysShowAtOrAbove)
        }
    }
}

/// A toggle with a caption under its label — the shape every row in this section already had,
/// extracted so the section's own body stays inside the 20-line limit as rows are added.
private struct CaptionedToggle: View {
    @Binding var isOn: Bool
    let title: String
    let detail: String

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The severity FLOOR control: which messages override every other filter on this pane.
///
/// Its own View rather than more rows in `TranscriptScopeSection` because that body is already at
/// the length where this codebase splits. The picker binds straight to the optional — "Nothing"
/// IS `nil`, not a sentinel case, so there is no second representation to keep in sync.
private struct SeverityFloorPicker: View {
    @Binding var floor: MessageSeverity?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Picker("Always show", selection: $floor) {
                Text("Errors and warnings").tag(MessageSeverity?.some(.warning))
                Text("Errors only").tag(MessageSeverity?.some(.error))
                Text("Nothing").tag(MessageSeverity?.none)
            }
            Text("Shown even when a hidden kind, sender, or tool would filter them out")
                .font(.caption)
                .foregroundStyle(.secondary)
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
        DisclosureGroup(isExpanded: $isExpanded, content: {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(orderedKinds, id: \.self) { kind in
                    Toggle(isOn: kindBinding(kind)) {
                        Text(kind.transcriptFilterLabel)
                    }
                    // The wire string, for when "which kind is this exactly?" matters.
                    .help(kind.rawValue)
                }
                // Tool calls get a second axis the other groups have no use for: WHICH tool. The
                // kinds above can only say "requests and/or output", and both carry the same two
                // kinds whichever tool produced them.
                if group == .toolCalls {
                    TranscriptToolFilterSection(selection: $selection)
                }
            }
            .padding(.top, 4)
            .padding(.leading, 4)
        }, label: {
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
        })
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

/// The per-tool checklist under the Tool calls group.
///
/// Built from `BuiltInToolGroup`'s membership table rather than a second list, so a tool that gains
/// a group automatically becomes filterable and `BuiltInToolGroupCoverageTests` is the one place
/// that can fail when a new tool is forgotten.
///
/// MCP tools are deliberately absent: their names come from whichever servers are configured, so
/// there is no static list to render. They follow the Tool calls group switch, which is the honest
/// behaviour — nothing here silently hides them.
private struct TranscriptToolFilterSection: View {
    @Binding var selection: TranscriptKindSelection

    @State private var isExpanded = false

    private var hiddenCount: Int { selection.hiddenToolNames.count }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded, content: {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(BuiltInToolGroup.allCases, id: \.self) { group in
                    TranscriptToolGroupRow(group: group, selection: $selection)
                }
            }
            .padding(.top, 4)
            .padding(.leading, 4)
        }, label: {
            VStack(alignment: .leading, spacing: 1) {
                Text("Specific tools")
                Text(hiddenCount == 0
                     ? "Every tool shown"
                     : "\(hiddenCount) tool\(hiddenCount == 1 ? "" : "s") hidden")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        })
        .padding(.top, 2)
    }
}

/// One built-in tool family, with a tri-state checkbox over its tools.
private struct TranscriptToolGroupRow: View {
    let group: BuiltInToolGroup
    @Binding var selection: TranscriptKindSelection

    @State private var isExpanded = false

    /// Stored at init: a computed collection handed to ForEach re-sorts on every body evaluation.
    private let orderedTools: [String]

    init(group: BuiltInToolGroup, selection: Binding<TranscriptKindSelection>) {
        self.group = group
        self._selection = selection
        self.orderedTools = BuiltInToolGroup.orderedToolNames(in: group)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded, content: {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(orderedTools, id: \.self) { toolName in
                    Toggle(isOn: toolBinding(toolName)) {
                        Text(toolName)
                            .font(.callout.monospaced())
                    }
                }
            }
            .padding(.top, 4)
            .padding(.leading, 4)
        }, label: {
            HStack(spacing: 6) {
                GroupTriStateCheckbox(state: selection.toolGroupVisibility(of: group)) { makeAllVisible in
                    selection.setToolGroup(group, visible: makeAllVisible)
                }
                Text(group.displayName)
            }
        })
    }

    private func toolBinding(_ toolName: String) -> Binding<Bool> {
        Binding(
            get: { selection.isToolVisible(toolName) },
            set: { isOn in selection.setTool(toolName, visible: isOn) }
        )
    }
}

/// The group checkbox: checked (all kinds shown), unchecked (none), or dash (mixed). Clicking a
/// fully-checked group hides all its kinds; clicking a mixed or empty one shows them all.
private struct GroupTriStateCheckbox: View {
    let state: TranscriptKindSelection.GroupVisibility
    let onSetAll: (Bool) -> Void

    var body: some View {
        Button(action: {
            onSetAll(state != .all)
        }, label: {
            Image(systemName: symbolName)
                .foregroundStyle(state == .none ? Color.secondary : Color.accentColor)
        })
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
