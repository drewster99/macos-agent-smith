import Foundation

/// Bridges scheduled-wake tools to an AgentActor. Created before the agent exists so it can
/// be captured by the ToolContext, then wired to the real agent after creation.
///
/// Exposes the multi-wake API (schedule/list/cancel) that replaced the single-slot
/// `scheduleFollowUp` design — see `ScheduledWake` for the per-wake record.
actor FollowUpScheduler {
    private weak var agent: AgentActor?

    func set(agent: AgentActor) {
        self.agent = agent
    }

    func scheduleWake(
        wakeAt: Date,
        instructions: String,
        taskID: UUID? = nil,
        replacesID: UUID? = nil,
        recurrence: Recurrence? = nil,
        survivesTaskTermination: Bool = false,
        action: TaskActionKind? = nil
    ) async -> ScheduleWakeOutcome {
        guard let agent else {
            return .error("Agent is not running.")
        }
        return await agent.scheduleWake(
            wakeAt: wakeAt,
            instructions: instructions,
            taskID: taskID,
            replacesID: replacesID,
            recurrence: recurrence,
            survivesTaskTermination: survivesTaskTermination,
            action: action
        )
    }

    func listScheduledWakes() async -> [ScheduledWake] {
        guard let agent else { return [] }
        return await agent.listScheduledWakes()
    }

    @discardableResult
    func cancelWake(id: UUID) async -> Bool {
        guard let agent else { return false }
        return await agent.cancelWake(id: id)
    }

    @discardableResult
    func cancelWakesForTask(_ taskID: UUID) async -> [UUID] {
        guard let agent else { return [] }
        return await agent.cancelWakesForTask(taskID)
    }
}
