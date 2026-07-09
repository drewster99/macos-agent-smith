import Foundation

/// Periodically posts task status summaries to the channel for Smith to review.
actor MonitoringTimer {
    private let interval: TimeInterval
    private let channel: MessageChannel
    private let taskStore: TaskStore
    private var timerTask: Task<Void, Never>?
    private var lastReportedTaskIDs: Set<UUID> = []
    /// Running-with-no-worker tasks seen on the previous tick — the two-strike rule for
    /// the orphaned-task watchdog.
    private var orphanCandidateIDs: Set<UUID> = []

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
            var runningTasks = tasks.filter { $0.status == .running && $0.disposition == .active }

            // Zombie-task watchdog. A task is legally `running` with no assigned worker
            // only for the instants between spawn-success and assignment (two sequential
            // awaits in every legitimate start path). One observed like that on TWO
            // consecutive ticks is definitively orphaned — a status forced around the
            // orchestrated path, or a worker death that unassigned it — and it will spin
            // in the UI forever while blocking the auto-run queue's busy checks. Flip it
            // to `interrupted` so run_task / auto-run-interrupted can recover it.
            let orphaned = runningTasks.filter { $0.assigneeIDs.isEmpty }
            let confirmedOrphans = orphaned.filter { orphanCandidateIDs.contains($0.id) }
            orphanCandidateIDs = Set(orphaned.map(\.id)).subtracting(confirmedOrphans.map(\.id))
            for task in confirmedOrphans {
                await taskStore.updateStatus(id: task.id, status: .interrupted)
                await channel.post(ChannelMessage(
                    sender: .system,
                    content: "Task \"\(task.title)\" (ID: \(task.id.uuidString)) was marked `running` but had NO assigned worker for two consecutive monitor ticks — an orphaned status that would spin forever and block the queue. It has been marked `interrupted`. Call `run_task` on it when nothing else is running (never set `running` via `update_task`).",
                    metadata: [
                        "messageKind": .string("task_update_guidance"),
                        "taskID": .string(task.id.uuidString),
                        "isWarning": .bool(true)
                    ]
                ))
            }
            runningTasks.removeAll { task in confirmedOrphans.contains { $0.id == task.id } }
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
