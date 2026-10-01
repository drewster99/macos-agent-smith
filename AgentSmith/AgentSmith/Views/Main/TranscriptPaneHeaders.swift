import SwiftUI
import AgentSmithKit

/// The session (bottom) pane's header strip: its title and its filter control.
struct TranscriptFilterBar: View {
    @Binding var config: TranscriptViewConfig
    let statsSource: TranscriptFilterStatsSource?

    var body: some View {
        TranscriptPaneHeader(title: TranscriptPane.session.title) {
            TranscriptFilterButton(config: $config, pane: .session, statsSource: statsSource)
        }
    }
}

/// The filter control for one pane: names the view the pane is showing — a preset's name, or
/// "Custom" — and opens the filter popover.
///
/// The funnel fills only when the pane differs from ITS OWN default. It used to fill whenever the
/// config differed from show-everything, which made it permanently filled in the session pane (whose
/// default is the filtered Conversation view) — an indicator that never changed carries nothing.
struct TranscriptFilterButton: View {
    @Binding var config: TranscriptViewConfig
    let pane: TranscriptPane
    let statsSource: TranscriptFilterStatsSource?
    @State private var showPopover = false

    var body: some View {
        Button(action: {
            showPopover = true
        }, label: {
            TranscriptFilterButtonLabel(
                title: pane.preset(matching: config)?.title ?? "Custom",
                isCustomized: pane.isCustomized(config))
        })
        .buttonStyle(.borderless)
        .help("Choose which messages this pane shows")
        .popover(isPresented: $showPopover, arrowEdge: .top) {
            TranscriptFilterPopover(config: $config, pane: pane, statsSource: statsSource)
        }
    }
}

private struct TranscriptFilterButtonLabel: View {
    let title: String
    let isCustomized: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isCustomized
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
            Text(title)
                .font(.caption)
        }
        .foregroundStyle(isCustomized ? Color.accentColor : Color.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Filter: \(title)")
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
                // wraps to several lines in a narrow pane and eats the transcript's height.
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
/// that resemble each other: the seam between the panes only reads if both sides match.
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
/// row, the bold monospaced orange the transcript uses for the task name in its sender slot. This is
/// the same task, said the same way.
struct TaskTranscriptHeader: View {
    /// nil when the pane has no resolved task — the run-history and empty states.
    let task: AgentTask?
    /// THIS pane's filter config — `taskTranscriptViewConfig`, never the session pane's.
    @Binding var config: TranscriptViewConfig
    let statsSource: TranscriptFilterStatsSource?

    var body: some View {
        TranscriptPaneChrome(topRule: true) {
            TaskTranscriptHeaderLabel(task: task)
            Spacer()
            TranscriptFilterButton(config: $config, pane: .task, statsSource: statsSource)
        }
    }
}

/// Names the pane: the task's status chip and title, or a plain caption when nothing is resolved.
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
            Text(TranscriptPane.task.title)
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
