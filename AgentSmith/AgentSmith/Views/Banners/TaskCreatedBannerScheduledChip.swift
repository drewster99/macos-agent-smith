import SwiftUI
import AgentSmithKit

/// Clock-icon chip showing when a `TaskCreatedBanner`'s scheduled task will fire.
/// Renders only when the task was created with a future `scheduled_run_at`.
struct TaskCreatedBannerScheduledChip: View {
    let runAt: Date

    var body: some View {
        let _scheduledAccent = TaskStatusBadge.color(for: .scheduled)
        return HStack(spacing: 4) {
            Image(systemName: "clock")
                .font(AppFonts.bannerIconSmall)
                .foregroundStyle(_scheduledAccent)
            Text("Scheduled \(formatScheduledTime(runAt))")
                .font(AppFonts.channelBody)
                .foregroundStyle(_scheduledAccent)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}
