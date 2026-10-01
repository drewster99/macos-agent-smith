import Testing
import Foundation
@testable import AgentSmithKit

/// Regressions for defects found in the final review of task watches.
@Suite("Task watches — review fixes")
struct TaskWatchReviewFixTests {

    private func completion(_ taskID: UUID) -> TaskStatusTransition {
        TaskStatusTransition(taskID: taskID, statusRevision: 1, from: .running, to: .completed, at: Date(), cause: .smithSetStatus)
    }

    @Test("Cancelling a fired once-watch still cancels its undelivered firing and effect")
    func cancelConsumedWatch() async throws {
        let store = TaskStore()
        let upstream = await store.addTask(title: "A", description: "d")
        let downstream = await store.addTask(title: "B", description: "d")
        let watch = TaskWatch(triggers: [.completed], action: .startTask(taskID: downstream.id), createdBy: .user)
        #expect(await store.addWatch(watch, to: upstream.id) == nil)
        await store.updateStatus(id: upstream.id, status: .completed, cause: .smithSetStatus)
        guard case .consumed = await store.task(id: upstream.id)?.watch(id: watch.id)?.state else {
            Issue.record("expected consumed"); return
        }
        #expect(await store.cancelWatch(watch.id, on: upstream.id) == nil)
        let after = try #require(await store.task(id: upstream.id))
        #expect(after.watch(id: watch.id)?.firing(occurrence: 1)?.state == .cancelled)
        #expect(!after.pendingEffects.contains { if case .watchFiring = $0.effect { true } else { false } })
        #expect(await store.task(id: downstream.id)?.startHolds.isEmpty == true)
    }

    @Test("A chain target must be runnable, and the watched task must not already be finished")
    func addWatchChecksStatuses() async {
        let store = TaskStore()
        let upstream = await store.addTask(title: "A", description: "d")
        let finishedTarget = await store.addTask(title: "Done", description: "d")
        await store.updateStatus(id: finishedTarget.id, status: .completed, cause: .smithSetStatus)
        #expect(await store.addWatch(TaskWatch(triggers: [.completed], action: .startTask(taskID: finishedTarget.id), createdBy: .user), to: upstream.id) != nil)

        let finishedUpstream = await store.addTask(title: "Old", description: "d")
        let target = await store.addTask(title: "B", description: "d")
        await store.updateStatus(id: finishedUpstream.id, status: .failed, cause: .smithSetStatus)
        #expect(await store.addWatch(TaskWatch(triggers: [.completed], action: .startTask(taskID: target.id), createdBy: .user), to: finishedUpstream.id) != nil)
        #expect(await store.task(id: target.id)?.startHolds.isEmpty == true)
    }

    @Test("Turning a task into a template cancels its chain links and frees their targets")
    func promotionStripsRunState() async throws {
        let store = TaskStore()
        let upstream = await store.addTask(title: "A", description: "d")
        let downstream = await store.addTask(title: "B", description: "d")
        let chain = TaskWatch(triggers: [.completed], action: .startTask(taskID: downstream.id), createdBy: .user)
        let notify = TaskWatch(triggers: [.failed], action: .macOSNotification, createdBy: .user)
        #expect(await store.addWatch(chain, to: upstream.id) == nil)
        #expect(await store.addWatch(notify, to: upstream.id) == nil)
        #expect(await store.setTemplate(id: upstream.id, isTemplate: true) == nil)
        let template = try #require(await store.taskOrLibraryTemplate(id: upstream.id))
        guard case .cancelled = template.watch(id: chain.id)?.state else { Issue.record("chain link should be cancelled"); return }
        #expect(template.watch(id: notify.id)?.isActive == true, "notifying watches stay as blueprints")
        #expect(template.pendingEffects.isEmpty)
        #expect(await store.task(id: downstream.id)?.startHolds.isEmpty == true)
    }

    @Test("Capacity shedding and a missing-validator park fire no watch")
    func internalParksAreNotEvents() {
        let id = UUID()
        #expect(TaskWatchTrigger(transition: TaskStatusTransition(taskID: id, statusRevision: 1, from: .running, to: .interrupted, at: Date(), cause: .capacityShed)) == nil)
        #expect(TaskWatchTrigger(transition: TaskStatusTransition(taskID: id, statusRevision: 1, from: .validating, to: .awaitingReview, at: Date(), cause: .validationBlocked)) == nil)
        #expect(TaskWatchTrigger(transition: TaskStatusTransition(taskID: id, statusRevision: 1, from: .validating, to: .awaitingReview, at: Date(), cause: .validationEscalated)) == .needsReview)
    }

    @Test("A worker's acknowledgement never revives a task paused since it was briefed")
    func acknowledgementIsNotATransition() async {
        let store = TaskStore()
        let task = await store.addTask(title: "t", description: "d")
        let worker = UUID()
        await store.driveStatus(id: task.id, to: .running)
        await store.assignAgent(taskID: task.id, agentID: worker)
        #expect(await store.acknowledgeTask(id: task.id, byAgent: worker) == 1)
        await store.updateStatus(id: task.id, status: .paused, cause: .smithSetStatus)
        #expect(await store.acknowledgeTask(id: task.id, byAgent: worker) == nil)
        #expect(await store.task(id: task.id)?.status == .paused)
        #expect(await store.acknowledgeTask(id: task.id, byAgent: UUID()) == nil, "only the assigned worker")
    }

    @Test("After a failed write, asking again schedules a new write that can succeed")
    func failedWriteIsRetried() async {
        actor Disk {
            var failing = true
            var writes = 0
            func setFailing(_ value: Bool) { failing = value }
            func save(_ snapshot: [AgentTask]) throws {
                if failing { throw CocoaError(.fileWriteNoPermission) }
                writes += 1
            }
        }
        let disk = Disk()
        let store = TaskStore()
        await store.attachPersistence(save: { try await disk.save($0) }, writeNow: false)
        _ = await store.addTask(title: "t", description: "d")
        let seq = await store.currentMutationSeq
        #expect(await store.awaitDurable(through: seq) == false)
        await disk.setFailing(false)
        // No further mutation: the retry alone must get it written.
        #expect(await store.awaitDurable(through: seq) == false, "this ask schedules the rewrite")
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var durable = false
        while !durable, ContinuousClock.now < deadline {
            durable = await store.awaitDurable(through: seq)
            if !durable { try? await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(durable)
    }

    @Test("Watch state lookup finds a watch on any active task")
    func watchStateLookup() async {
        let store = TaskStore()
        let task = await store.addTask(title: "t", description: "d")
        let watch = TaskWatch(triggers: [.completed], action: .summarizeToUser, createdBy: .user)
        _ = await store.addWatch(watch, to: task.id)
        #expect(await store.watchState(watch.id)?.isActive == true)
        #expect(await store.watchState(UUID()) == nil)
    }
}

@Suite("Notification broker — durable ownership")
struct NotificationBrokerOwnershipTests {
    private struct NoopRuntime: NotificationRuntime {
        func autoRunTask(_ taskID: UUID, amendment: String?) async -> AutoRunDispatchOutcome { .placed }
        func setTaskStatus(_ taskID: UUID, to status: AgentTask.Status) async -> Bool { true }
        func taskTitle(_ taskID: UUID) async -> String? { nil }
        func postSystemNotice(_ text: String, taskID: UUID?) async {}
        func startTaskForWatch(_ targetID: UUID, watchedTaskID: UUID, watchID: UUID, occurrence: Int) async -> AutoRunDispatchOutcome { .placed }
    }
    private actor FlakyDisk {
        var failing = true
        func setFailing(_ value: Bool) { failing = value }
        func write(_ items: [QueuedDelivery]) throws { if failing { throw CocoaError(.fileWriteNoPermission) } }
    }

    @Test("A Smith delivery whose queue couldn't be saved is not owned; resubmitting after the disk recovers is")
    func pullOwnershipFollowsDurability() async {
        let disk = FlakyDisk()
        let broker = NotificationBroker(runtime: NoopRuntime(), persistPendingDelivery: { try await disk.write($0) })
        await broker.registerHandler(type: KnownNotificationType.taskBriefing.rawValue, TaskBriefingNotificationHandler())
        await broker.registerPullRecipient(.smith)
        let notification = AgentNotification(
            id: NotificationID(namespace: "tasktransition", key: "x"),
            triggerSource: .taskTransition(taskID: UUID(), statusRevision: 1),
            recipient: .smith, title: "t", createdAt: Date(),
            payload: Payload(type: KnownNotificationType.taskBriefing.rawValue, data: ["note": .string("hi")])
        )
        #expect(await broker.submit(notification) == false)
        await disk.setFailing(false)
        #expect(await broker.submit(notification))
        #expect(await broker.drainPendingDeliveries(for: .smith).count == 1, "queued once, not twice")
    }
}
