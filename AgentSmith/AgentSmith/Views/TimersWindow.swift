import SwiftUI
import AgentSmithKit

/// Displays the current session's active timers and full timer history. Opened via
/// View → Timers in the main menu. The window targets a specific session (the one whose
/// window was key at the moment of opening) so multi-tab users see the right timers.
struct TimersWindow: View {
    @Bindable var viewModel: AppViewModel
    @State private var selectedTab: Tab = .active

    enum Tab: Hashable {
        case active, history
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text("Active (\(viewModel.activeTimers.count))").tag(Tab.active)
                Text("History (\(viewModel.timerHistory.count))").tag(Tab.history)
            }
            .pickerStyle(.segmented)
            .padding(12)

            Divider()

            switch selectedTab {
            case .active:
                ActiveTimersList(viewModel: viewModel)
            case .history:
                TimerHistoryList(history: viewModel.timerHistory)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .navigationTitle("Timers — \(viewModel.session.name)")
        .task {
            await viewModel.refreshActiveTimers()
        }
    }
}

private struct ActiveTimersList: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        if viewModel.activeTimers.isEmpty {
            ContentUnavailableView(
                "No active timers",
                systemImage: "clock",
                description: Text("Reminders and task-action timers will appear here while they're scheduled.")
            )
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.activeTimers.enumerated()), id: \.element.id) { index, wake in
                        ActiveTimerRow(wake: wake, taskTitle: taskTitle(for: wake.taskID), onCancel: {
                            Task { await viewModel.cancelTimer(id: wake.id) }
                        })
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(index.isMultiple(of: 2) ? Color.clear : AppColors.subtleRowBackgroundDim)
                    }
                }
            }
        }
    }

    private func taskTitle(for taskID: UUID?) -> String? {
        guard let taskID else { return nil }
        return viewModel.anyTask(id: taskID)?.title
    }
}

private struct ActiveTimerRow: View {
    let wake: ScheduledWake
    let taskTitle: String?
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: wake.recurrence == nil ? "clock" : "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
                Text(wake.instructions)
                    .font(.body)
                    .lineLimit(3)
                Spacer()
                Button(role: .destructive, action: onCancel, label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                })
                .buttonStyle(.plain)
                .help("Cancel this timer")
            }
            HStack(spacing: 12) {
                Label(absoluteString(wake.wakeAt), systemImage: "calendar")
                Label(relativeString(wake.wakeAt), systemImage: "hourglass")
                if let taskTitle {
                    Label(taskTitle, systemImage: "rectangle.stack")
                        .lineLimit(1)
                }
                if let recurrence = wake.recurrence {
                    Label(recurrence.displayDescription, systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func absoluteString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f.string(from: date)
    }

    private func relativeString(_ date: Date) -> String {
        let interval = date.timeIntervalSinceNow
        if interval < 0 { return "due now" }
        if interval < 60 { return "in <1 min" }
        if interval < 3600 { return "in \(Int(interval / 60)) min" }
        if interval < 86400 { return String(format: "in %.1f h", interval / 3600) }
        return String(format: "in %.1f d", interval / 86400)
    }
}

private struct TimerHistoryList: View {
    let history: [TimerEvent]

    var body: some View {
        if history.isEmpty {
            ContentUnavailableView(
                "No timer history yet",
                systemImage: "clock.arrow.circlepath",
                description: Text("Once timers are scheduled, fired, or cancelled their lifecycle events appear here.")
            )
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(history.enumerated()), id: \.element.id) { index, event in
                        TimerHistoryRow(event: event)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(index.isMultiple(of: 2) ? Color.clear : AppColors.subtleRowBackgroundDim)
                    }
                }
            }
        }
    }
}

private struct TimerHistoryRow: View {
    let event: TimerEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .foregroundStyle(iconTint)
                Text(headlineText)
                    .font(.body.weight(.semibold))
                Spacer()
                Text(timestamp)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(event.instructions)
                .font(.callout)
                .lineLimit(4)
                .foregroundStyle(.primary)
            HStack(spacing: 12) {
                if let taskID = event.taskID {
                    Label(taskID.uuidString.prefix(8) + "…", systemImage: "rectangle.stack")
                }
                if let recurrence = event.recurrenceDescription {
                    Label(recurrence, systemImage: "arrow.triangle.2.circlepath")
                }
                if let coalesced = event.coalescedCount, coalesced > 1 {
                    Label("\(coalesced) timers fired together", systemImage: "rectangle.3.group")
                }
                if let cause = event.cancellationCause {
                    Label(cause.rawValue, systemImage: "xmark.octagon")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var headlineText: String {
        switch event.kind {
        case .scheduled: return "Scheduled"
        case .fired:     return "Fired"
        case .cancelled: return "Cancelled"
        }
    }

    private var iconName: String {
        switch event.kind {
        case .scheduled: return "clock.badge.checkmark"
        case .fired:     return "bolt.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    private var iconTint: Color {
        switch event.kind {
        case .scheduled: return .blue
        case .fired:     return .orange
        case .cancelled: return .secondary
        }
    }

    private var timestamp: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: event.timestamp)
    }
}
