import Foundation

/// Periodically posts task status summaries to the channel for Smith to review.
actor MonitoringTimer {
    private let interval: TimeInterval
    private let channel: MessageChannel
    private let taskStore: TaskStore
    private var timerTask: Task<Void, Never>?
    private var lastReportedTaskIDs: Set<UUID> = []

    public init(interval: TimeInterval = 60, channel: MessageChannel, taskStore: TaskStore) {
        self.interval = interval
        self.channel = channel
        self.taskStore = taskStore
    }

    /// Starts the monitoring timer.
    public func start() {
        guard timerTask == nil else { return }
        timerTask = Task { [weak self] in
            guard let self else { return }
            await self.timerLoop()
        }
    }

    /// Stops the monitoring timer.
    public func stop() {
        timerTask?.cancel()
        timerTask = nil
    }

    private func timerLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                break
            }

            let tasks = await taskStore.allTasks()
            let runningTasks = tasks.filter { $0.status == .running }
            let runningIDs = Set(runningTasks.map(\.id))

            // Only post if there are running tasks and the set changed since last report
            guard !runningTasks.isEmpty, runningIDs != lastReportedTaskIDs else { continue }
            lastReportedTaskIDs = runningIDs

            let summary = runningTasks.map { task in
                "- \(task.title) [\(task.status.rawValue)] (assigned to \(task.assigneeIDs.count) agent(s))"
            }.joined(separator: "\n")

            await channel.post(ChannelMessage(
                sender: .system,
                content: "Status update — \(runningTasks.count) running task(s):\n\(summary)"
            ))
        }
    }
}
