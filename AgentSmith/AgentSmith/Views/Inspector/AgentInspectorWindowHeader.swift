import SwiftUI
import AgentSmithKit

/// Top header bar for `AgentInspectorWindow`: activity dot, agent name, status, Done button.
struct AgentInspectorWindowHeader: View {
    let role: AgentRole
    let displayName: String
    let roleColor: Color
    let hasActivity: Bool
    let isProcessing: Bool
    let isTerminated: Bool
    let executingTools: [String]
    let processingStartDate: Date?
    let toolExecutingStartDate: Date?
    let onDone: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            Circle()
                .fill(hasActivity ? roleColor : AppColors.inactiveDot)
                .frame(width: 10, height: 10)
            Text(displayName)
                .font(.title2.bold())
                .foregroundStyle(roleColor)

            Spacer()

            if isProcessing {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(role == .securityAgent ? "Evaluating" : "Thinking")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    if let start = processingStartDate {
                        ThinkingElapsedTime(since: start, font: .headline)
                    }
                }
            } else if !executingTools.isEmpty {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(workingLabel)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    if let start = toolExecutingStartDate {
                        ThinkingElapsedTime(since: start, font: .headline)
                    }
                }
            } else if hasActivity && isTerminated {
                Text("Terminated")
                    .font(.headline)
                    .foregroundStyle(.orange)
            } else if hasActivity {
                Text("Idle")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            Button("Done", action: onDone)
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private var workingLabel: String {
        if executingTools.count == 1 {
            return "Working — \(executingTools[0])"
        }
        return "Working — \(executingTools.count) tools"
    }
}
