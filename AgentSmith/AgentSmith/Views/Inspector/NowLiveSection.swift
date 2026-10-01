import SwiftUI
import AgentSmithKit

/// The live "Now" view at the top of the inspector: the tasks happening right now, each
/// with its stage, its Brown's live micro-state, and its most recent tool calls — each showing
/// who is looking at it and how long it actually ran.
///
/// Sources: the Brown state (`thinking` / `running <tool>` / `waiting on security`) comes from
/// per-instance telemetry (the M2 re-key), matched to a task via the Brown instance id in its
/// `assigneeIDs`. Each tool row is assembled from the CHANNEL, joining a call's request, its
/// Security Agent verdict, and its output on the `requestID` all three carry — the same join the
/// transcript uses. Nothing is faked; a state that isn't on the wire is simply omitted.
///
/// The per-call security state replaced a single `Security · evaluating` line under Brown. That
/// line could not say WHICH call of a batch was under review, and it contradicted the Agents
/// tally beside it: the tally counts only real LLM-backed evaluations, while the line lit up for
/// auto-approved calls too, so "Brown waiting on security" could sit directly above "0 Security".
///
/// Activity rows are age-bounded (`activityWindowSeconds`) on their REQUEST time and swept on a
/// timer, because this section means "now" literally. What a row DISPLAYS is the tool's own run
/// duration, never that age — showing the age made a call that had long since returned read as
/// one that never did. A task keeps its title and stage chip for as long as its status is live;
/// only the activity beneath it expires.
///
/// The rows are derived in the model (`InspectorLiveState.liveRows`); this view only draws them.
struct NowLiveSection: View {
    let live: InspectorLiveState

    var body: some View {
        // Rendered only when something is actually live, so an idle session shows no
        // empty section.
        if !live.liveRows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Live")
                    .font(AppFonts.liveSectionHeader)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 4)

                ForEach(live.liveRows) { row in
                    LiveTaskRowView(row: row)
                }

                Divider()
                    .padding(.top, 6)
            }
        }
    }
}

/// One live task: its title + stage chip, with its recent tool activity indented beneath.
private struct LiveTaskRowView: View {
    let row: LiveTaskRow

    private var stageColor: Color { TaskStatusBadge.color(for: row.status) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(row.title)
                    .font(AppFonts.liveTaskTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(row.status.displayName)
                    .font(AppFonts.liveTaskStageChip)
                    .foregroundStyle(stageColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(stageColor.opacity(0.16), in: Capsule())
            }
            .padding(.horizontal, 12)

            if let brownState = row.brownState {
                HStack(spacing: 6) {
                    Text("Brown")
                        .font(AppFonts.liveAgentLabel)
                        .foregroundStyle(AppColors.color(for: .agent(.brown)))
                    Text(brownState)
                        .font(AppFonts.liveAgentState)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.leading, 12)
            }

            ForEach(row.tools) { tool in
                LiveToolRowView(tool: tool)
            }
        }
        .padding(.vertical, 5)
    }
}

/// One tool call: its name, then whatever is true of it right now — under review, running, or
/// finished with the time it actually took and how Security ruled on it.
private struct LiveToolRowView: View {
    let tool: LiveToolActivity

    var body: some View {
        HStack(spacing: 6) {
            Text(tool.name)
                .font(AppFonts.liveToolName)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 8)

            LiveToolStatusView(tool: tool)
        }
        .padding(.leading, 28)
        .padding(.trailing, 12)
    }
}

/// The trailing half of a live tool row: either the Security Agent holding the call, or the run
/// duration plus the verdict it was let through on.
private struct LiveToolStatusView: View {
    let tool: LiveToolActivity

    var body: some View {
        switch tool.security {
        case .notYetReviewed:
            EmptyView()
        case .evaluating:
            // The one state that names an agent: this call is parked in front of the Security
            // Agent and nothing else is happening to it.
            Text("Security")
                .font(AppFonts.liveAgentLabel)
                .foregroundStyle(AppColors.color(for: .agent(.securityAgent)))
        case .denied:
            // No duration: a denied call never ran, so any number here would be a lie.
            Image(systemName: "xmark.circle.fill")
                .font(AppFonts.liveToolVerdictIcon)
                .foregroundStyle(AppColors.securityDenied)
        case .approved, .autoApproved, .warned:
            HStack(spacing: 5) {
                LiveToolDurationView(run: tool.run)
                Image(systemName: verdictSymbol)
                    .font(AppFonts.liveToolVerdictIcon)
                    .foregroundStyle(verdictColor)
            }
        }
    }

    private var verdictSymbol: String {
        switch tool.security {
        case .autoApproved: return "bolt.circle.fill"
        case .warned: return "exclamationmark.triangle.fill"
        default: return "checkmark.circle.fill"
        }
    }

    private var verdictColor: Color {
        switch tool.security {
        case .warned: return AppColors.securityWarning
        case .autoApproved: return AppColors.securityAutoApproved
        default: return AppColors.securityApproved
        }
    }
}

/// Time the TOOL spent running — never the age of the row, never the review wait. A call still
/// executing counts up from its verdict; a finished one shows what was measured.
private struct LiveToolDurationView: View {
    let run: LiveToolActivity.RunPhase

    var body: some View {
        switch run {
        case .notStarted:
            EmptyView()
        case .running(let since):
            Text(since, style: .timer)
                .font(AppFonts.liveToolAge)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        case .finished(let runMs):
            if let runMs {
                Text(Self.formatted(runMs))
                    .font(AppFonts.liveToolAge)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
    }

    /// Sub-second calls read in milliseconds, longer ones in seconds: "1483 ms" is harder to
    /// compare at a glance than "1.5s" when scanning a column of them.
    static func formatted(_ runMs: Int) -> String {
        runMs < 1000 ? "\(runMs) ms" : String(format: "%.1fs", Double(runMs) / 1000)
    }
}
