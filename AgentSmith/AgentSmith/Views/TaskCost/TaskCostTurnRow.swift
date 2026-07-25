import SwiftUI
import AgentSmithKit

/// One row of the Turn-by-Turn timeline table in the Task Cost Detail sheet.
/// All formatting is done by the parent so this view stays purely presentational.
struct TaskCostTurnRow: View {
    let displayNumber: Int
    let agentRole: AgentRole
    let inputTokensFormatted: String
    let outputTokensFormatted: String
    let costFormatted: String
    let latencyFormatted: String
    let toolNames: String

    var body: some View {
        // Top-aligned so the fixed columns line up with the first line of a wrapped Tools cell.
        HStack(alignment: .top, spacing: 0) {
            Text("\(displayNumber)")
                .frame(width: 30, alignment: .leading)
            Text(agentRole.displayName)
                .foregroundStyle(AppColors.color(for: .agent(agentRole)))
                .frame(width: 60, alignment: .leading)
                .padding(.leading, 8)
            Text(inputTokensFormatted)
                .frame(width: 60, alignment: .trailing)
            Text(outputTokensFormatted)
                .frame(width: 60, alignment: .trailing)
            Text(costFormatted)
                .frame(width: 60, alignment: .trailing)
            Text(latencyFormatted)
                .frame(width: 60, alignment: .trailing)
            Text(toolNames)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 8)
        }
        .font(.caption2.monospacedDigit())
        .padding(.vertical, 1)
    }
}
