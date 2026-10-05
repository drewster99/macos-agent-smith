import SwiftUI
import AppKit
import AgentSmithKit

/// Compact status indicator that sits at the right edge of `AgentCard`'s header. Picks
/// between five mutually-exclusive states (Thinking / Working / Idle / Terminated / Not
/// active) based on the agent's current activity. Renders the elapsed timer when either
/// thinking or working — long tool executions (slow AppleScripts, network fetches) used
/// to leave the agent looking idle while it was actually blocked waiting for the tool to
/// return; the Working state covers that span.
/// Activity spinner for agent status rows. Replaces `ProgressView(.mini)`, whose
/// NSProgressIndicator ignores tint and rendered near-invisible dark-on-dark. Drawn in the
/// secondary label color (adaptive in both modes) and spun on a Core Animation layer: the
/// `.symbolEffect(.variableColor, options: .repeating)` it replaced was a per-frame SwiftUI update
/// that re-laid out the whole window (see `LayerSpinningSymbol`).
struct AgentActivitySpinner: View {
    var body: some View {
        LayerSpinningSymbol(
            systemName: "progress.indicator",
            pointSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize,
            color: .secondaryLabelColor,
            isSpinning: true,
            accessibilityLabel: "Working"
        )
    }
}

struct AgentCardStatusBadge: View {
    let isProcessing: Bool
    let hasActivity: Bool
    let isSecurityAgent: Bool
    /// True when the agent has activity history but no live tools — i.e. it has been
    /// terminated. Driven by `availableTools.isEmpty && !contextMessages.isEmpty`.
    let isTerminated: Bool
    /// Names of tools currently executing for this agent (one entry per concurrent call,
    /// summarised by display label). Empty when no tool is running.
    let executingTools: [String]
    let processingStartDate: Date?
    let toolExecutingStartDate: Date?
    /// This role's callers sleeping on their provider, soonest resumption first. Takes precedence:
    /// during the wait the agent is neither thinking nor idle.
    let providerWaits: [ProviderWait]

    var body: some View {
        Group {
            if let wait = providerWaits.first {
                ProviderWaitStatusLabel(wait: wait, waitingCount: providerWaits.count, font: AppFonts.inspectorLabel)
            } else if isProcessing {
                HStack(spacing: 4) {
                    AgentActivitySpinner()
                    Text(isSecurityAgent ? "Evaluating" : "Thinking")
                        .font(AppFonts.inspectorLabel)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let start = processingStartDate {
                        ThinkingElapsedTime(since: start, font: AppFonts.inspectorLabel)
                    }
                }
            } else if !executingTools.isEmpty {
                HStack(spacing: 4) {
                    AgentActivitySpinner()
                    Text(workingLabel)
                        .font(AppFonts.inspectorLabel)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let start = toolExecutingStartDate {
                        ThinkingElapsedTime(since: start, font: AppFonts.inspectorLabel)
                    }
                }
            } else if hasActivity && isTerminated {
                Text("Terminated")
                    .font(AppFonts.inspectorLabel)
                    .foregroundStyle(.orange)
            } else if hasActivity {
                Text("Idle")
                    .font(AppFonts.inspectorLabel)
                    .foregroundStyle(.secondary)
            } else {
                Text("Not active")
                    .font(AppFonts.inspectorLabel)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var workingLabel: String {
        if executingTools.count == 1 {
            return "Working — \(executingTools[0])"
        }
        return "Working — \(executingTools.count) tools"
    }
}
