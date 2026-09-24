import SwiftUI
import AgentSmithKit

/// The app-wide Memory activity feed: every memory-store query with exactly what each corpus
/// returned, and every committed change to memories and task summaries. Reads `shared.memoryActivityFeed` (global, since the `MemoryStore` is shared across
/// sessions). Starts collapsed; the header carries the retention wording so the count is honest
/// without expanding.
struct MemoryActivityCard: View {
    @Bindable var shared: SharedAppState
    @State private var expanded = false

    /// The sidebar renders only the newest few rows so a long session doesn't build a huge tree.
    private static let visibleRowLimit = 40

    var body: some View {
        let feed = shared.memoryActivityFeed
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle, label: {
                MemoryActivityCardHeader(feed: feed, expanded: expanded)
            })
            .buttonStyle(.plain)
            .help(expanded ? "Collapse Memory activity" : "Expand Memory activity")
            .accessibilityLabel("Memory activity, \(MemoryActivityPresentation.feedHeading(feed))")
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if expanded {
                MemoryActivityList(feed: feed, visibleRowLimit: Self.visibleRowLimit)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            Divider()
        }
    }

    private func toggle() {
        withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
    }
}

private struct MemoryActivityCardHeader: View {
    let feed: MemoryActivityFeed
    let expanded: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(feed.lifetimeCount == 0 ? AppColors.inactiveDot : AppColors.memoryActivity)
                .frame(width: 8, height: 8)
            Text("Memory")
                .font(.headline)
                .foregroundStyle(feed.lifetimeCount == 0 ? Color.secondary : AppColors.memoryActivity)
            Spacer()
            Text(MemoryActivityPresentation.feedHeading(feed))
                .font(AppFonts.inspectorLabel)
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .contentShape(Rectangle())
    }
}

private struct MemoryActivityList: View {
    let feed: MemoryActivityFeed
    let visibleRowLimit: Int

    var body: some View {
        let visible = Array(feed.activities.suffix(visibleRowLimit).reversed())
        VStack(alignment: .leading, spacing: 3) {
            if visible.isEmpty {
                Text("No memory activity yet.")
                    .font(AppFonts.inspectorBody)
                    .foregroundStyle(.secondary)
            } else if feed.activities.count > visible.count {
                Text("Showing latest \(visible.count) of \(feed.activities.count) retained")
                    .font(AppFonts.inspectorBody)
                    .foregroundStyle(.tertiary)
            }
            ForEach(visible) { activity in
                MemoryActivityRow(activity: activity)
            }
        }
    }
}

/// One feed entry, routed by kind.
struct MemoryActivityRow: View {
    let activity: MemoryActivity

    var body: some View {
        switch activity.kind {
        case .query(let query):
            MemoryQueryActivityRow(query: query, timestamp: activity.timestamp)
        case .mutation(let mutation):
            MemoryMutationActivityRow(mutation: mutation, timestamp: activity.timestamp)
        }
    }
}
