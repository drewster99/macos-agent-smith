import SwiftUI

/// Header row for `SummarizerCard` — activity dot, title, status, mute placeholder, gear.
struct SummarizerCardHeader: View {
    let hasActivity: Bool
    let isProcessing: Bool
    let executingTools: [String]
    let roleColor: Color
    @Binding var expanded: Bool
    let onShowConfig: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            }, label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(hasActivity ? roleColor : AppColors.inactiveDot)
                        .frame(width: 8, height: 8)

                    Text("Summarizer")
                        .font(.headline)
                        .foregroundStyle(hasActivity ? roleColor : .secondary)

                    Spacer()

                    if isProcessing {
                        HStack(spacing: 4) {
                            AgentActivitySpinner()
                            Text("Summarizing")
                                .font(AppFonts.inspectorLabel)
                                .foregroundStyle(.secondary)
                        }
                    } else if !executingTools.isEmpty {
                        HStack(spacing: 4) {
                            AgentActivitySpinner()
                            Text(executingTools.count == 1 ? "Working — \(executingTools[0])" : "Working — \(executingTools.count) tools")
                                .font(AppFonts.inspectorLabel)
                                .foregroundStyle(.secondary)
                        }
                    } else if hasActivity {
                        Text("Idle")
                            .font(AppFonts.inspectorLabel)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Not active")
                            .font(AppFonts.inspectorLabel)
                            .foregroundStyle(.tertiary)
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            })
            .buttonStyle(.plain)

            Image(systemName: "speaker.slash")
                .font(.caption)
                .foregroundStyle(AppColors.dimSecondary30)
                .help("Speech configuration coming soon")

            Button(action: onShowConfig, label: {
                Image(systemName: "gearshape")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            })
            .buttonStyle(.plain)
            .padding(.leading, 4)
            .help("Configure summarizer")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
