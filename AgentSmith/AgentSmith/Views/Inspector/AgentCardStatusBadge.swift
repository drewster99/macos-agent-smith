import SwiftUI

/// Compact status indicator that sits at the right edge of `AgentCard`'s header. Picks
/// between five mutually-exclusive states (Thinking / Working / Idle / Terminated / Not
/// active) based on the agent's current activity. Renders the elapsed timer when either
/// thinking or working — long tool executions (slow AppleScripts, network fetches) used
/// to leave the agent looking idle while it was actually blocked waiting for the tool to
/// return; the Working state covers that span.
struct AgentCardStatusBadge: View {
    let isProcessing: Bool
    let hasActivity: Bool
    let isJones: Bool
    /// True when the agent has activity history but no live tools — i.e. it has been
    /// terminated. Driven by `availableTools.isEmpty && !contextMessages.isEmpty`.
    let isTerminated: Bool
    /// Names of tools currently executing for this agent (one entry per concurrent call,
    /// summarised by display label). Empty when no tool is running.
    let executingTools: [String]
    let processingStartDate: Date?
    let toolExecutingStartDate: Date?

    var body: some View {
        Group {
            if isProcessing {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(isJones ? "Evaluating" : "Thinking")
                        .font(AppFonts.inspectorLabel)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let start = processingStartDate {
                        ThinkingElapsedTime(since: start, font: AppFonts.inspectorLabel)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            } else if !executingTools.isEmpty {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(workingLabel)
                        .font(AppFonts.inspectorLabel)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let start = toolExecutingStartDate {
                        ThinkingElapsedTime(since: start, font: AppFonts.inspectorLabel)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
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
