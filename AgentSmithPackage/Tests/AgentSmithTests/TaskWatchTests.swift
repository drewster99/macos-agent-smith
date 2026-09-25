import Testing
import Foundation
import SemanticSearch
import SwiftLLMKit
@testable import AgentSmithKit

@Suite("Task watches — model and firing")
struct TaskWatchModelTests {

    private func transition(_ cause: TaskTransitionCause, from: AgentTask.Status = .running, to: AgentTask.Status) -> TaskStatusTransition {
        TaskStatusTransition(taskID: UUID(), statusRevision: 1, from: from, to: to, at: Date(), cause: cause)
    }

    @Test("Triggers map from the typed transition, not the bare status")
    func triggerMapping() {
        #expect(TaskWatchTrigger(transition: transition(.workerStarted, from: .starting, to: .running)) == .started)
        #expect(TaskWatchTrigger(transition: transition(.workerStartedAtRuntimeStart, from: .interrupted, to: .running)) == .started)
        #expect(TaskWatchTrigger(transition: transition(.rejectionsReturned, from: .validating, to: .running)) == nil,
                "rejections handed back are not a start")
        #expect(TaskWatchTrigger(transition: transition(.validationPassed(validationWasRun: true), from: .validating, to: .completed)) == .completed)
        #expect(TaskWatchTrigger(transition: transition(.spawnFailed, from: .starting, to: .failed)) == .failed)
        #expect(TaskWatchTrigger(transition: transition(.helpRequested, to: .awaitingHelp)) == .needsHelp)
        #expect(TaskWatchTrigger(transition: transition(.validationEscalated, from: .validating, to: .awaitingReview)) == .needsReview)
        #expect(TaskWatchTrigger(transition: transition(.userStopped, to: .interrupted)) == .interrupted)
        #expect(TaskWatchTrigger(transition: transition(.coldBootRecovery(.interrupt), to: .interrupted)) == .interrupted,
                "a crash found at launch is a real event")
        #expect(TaskWatchTrigger(transition: transition(.sessionShutdown, to: .interrupted)) == nil, "quitting is not an event")
        #expect(TaskWatchTrigger(transition: transition(.sessionDeletion, to: .interrupted)) == nil)
    }

    @Test("A matching transition records a firing and its effect in the same write")
    func firingRecordedWithStatus() async throws {
        let store = TaskStore()
        let task = await store.addTask(title: "t", description: "d")
        let watch = TaskWatch(triggers: [.completed], action: .instructSmith("tell me"), createdBy: .user)
        #expect(await store.addWatch(watch, to: task.id) == nil)
        await store.driveStatus(id: task.id, to: .completed)
        let stored = try #require(await store.task(id: task.id)?.watch(id: watch.id))
        #expect(stored.recentFirings.map(\.occurrence) == [1])
        #expect(stored.recentFirings.first?.state == .pending)
        #expect(stored.nextOccurrence == 2)
        #expect(stored.isActive, "an every-time watch stays active")
        let effects = try #require(await store.task(id: task.id)?.pendingEffects)
        #expect(effects.contains { $0.effect == .watchFiring(watchID: watch.id, occurrence: 1) })
    }

    @Test("A once-watch is consumed when it fires, so it can never fire twice")
    func onceConsumedAtFiring() async throws {
        let store = TaskStore()
        let task = await store.addTask(title: "t", description: "d")
        let watch = TaskWatch(triggers: [.failed], action: .macOSNotification, lifetime: .once, createdBy: .user)
        #expect(await store.addWatch(watch, to: task.id) == nil)
        await store.driveStatus(id: task.id, to: .failed)
        await store.updateStatus(id: task.id, status: .pending, cause: .resetForRun)
        await store.driveStatus(id: task.id, to: .failed)
        let stored = try #require(await store.task(id: task.id)?.watch(id: watch.id))
        #expect(stored.recentFirings.count == 1)
        guard case .consumed = stored.state else { Issue.record("expected consumed"); return }
    }

    @Test("Cancelling a watch cancels its unsettled firings and removes their undelivered effects")
    func cancelStopsFirings() async throws {
        let store = TaskStore()
        let task = await store.addTask(title: "t", description: "d")
        let watch = TaskWatch(triggers: [.completed], action: .summarizeToUser, createdBy: .smith)
        #expect(await store.addWatch(watch, to: task.id) == nil)
        await store.driveStatus(id: task.id, to: .completed)
        #expect(await store.cancelWatch(watch.id, on: task.id) == nil)
        let stored = try #require(await store.task(id: task.id))
        #expect(stored.watch(id: watch.id)?.recentFirings.first?.state == .cancelled)
        #expect(!stored.pendingEffects.contains { if case .watchFiring = $0.effect { true } else { false } })
        #expect(await store.setWatchFiringState(taskID: task.id, watchID: watch.id, occurrence: 1, to: .delivered(at: Date())) == false,
                "a cancelled firing stays cancelled")
    }

    @Test("Watches that could not work are refused when created")
    func invalidWatchesRefused() async {
        let store = TaskStore()
        let a = await store.addTask(title: "A", description: "d")
        let b = await store.addTask(title: "B", description: "d")
        #expect(await store.addWatch(TaskWatch(triggers: [], action: .macOSNotification, createdBy: .user), to: a.id) != nil)
        #expect(await store.addWatch(TaskWatch(triggers: [.completed], action: .instructSmith("  "), createdBy: .user), to: a.id) != nil)
        #expect(await store.addWatch(TaskWatch(triggers: [.completed], action: .startTask(taskID: a.id), createdBy: .user), to: a.id) != nil,
                "a task can't start itself")
        #expect(await store.addWatch(TaskWatch(triggers: [.completed], action: .startTask(taskID: UUID()), createdBy: .user), to: a.id) != nil,
                "the target must exist in this session")
        #expect(await store.addWatch(TaskWatch(triggers: [.completed], action: .startTask(taskID: b.id), createdBy: .user), to: a.id) == nil)
        #expect(await store.addWatch(TaskWatch(triggers: [.completed], action: .startTask(taskID: a.id), createdBy: .user), to: b.id) != nil,
                "B → A would close the loop A → B")
    }

    @Test("Settled firings are compacted past the bound; the occurrence counter keeps counting")
    func retentionIsBounded() {
        var watch = TaskWatch(triggers: [.completed], action: .macOSNotification, createdBy: .user)
        for _ in 0..<30 {
            let occurrence = watch.recordFiring(trigger: .completed, transition: transition(.smithSetStatus, from: .pending, to: .completed))
            watch.setFiringState(occurrence: occurrence, .delivered(at: Date()))
        }
        #expect(watch.recentFirings.count == TaskWatch.settledFiringsRetained)
        #expect(watch.nextOccurrence == 31)
        #expect(watch.recentFirings.first?.occurrence == 11)
    }

    @Test("Unsettled firings are never compacted")
    func unsettledKept() {
        var watch = TaskWatch(triggers: [.completed], action: .macOSNotification, createdBy: .user)
        for _ in 0..<30 {
            _ = watch.recordFiring(trigger: .completed, transition: transition(.smithSetStatus, from: .pending, to: .completed))
        }
        #expect(watch.recentFirings.count == 30)
    }

    @Test("A template's notifying watches are blueprints copied into each run; startTask is refused on a template")
    func templateBlueprints() async throws {
        let store = TaskStore()
        let template = await store.addTask(title: "Nightly", description: "d", isTemplate: true)
        let other = await store.addTask(title: "Other", description: "d")
        let notify = TaskWatch(triggers: [.failed], action: .macOSNotification, createdBy: .user)
        #expect(await store.addWatch(notify, to: template.id) == nil)
        #expect(await store.addWatch(TaskWatch(triggers: [.completed], action: .startTask(taskID: other.id), createdBy: .user), to: template.id) != nil)
        guard case .success(let instance) = await store.instantiateTemplate(templateID: template.id, inputValues: [:]) else {
            Issue.record("instantiation failed"); return
        }
        let copied = try #require(instance.watches.first)
        #expect(instance.watches.count == 1)
        #expect(copied.id != notify.id, "each run gets its own identity")
        #expect(copied.action == .macOSNotification)
        #expect(copied.recentFirings.isEmpty)
    }

    @Test("Watches and firings round-trip through AgentTask's Codable")
    func watchesPersist() async throws {
        let store = TaskStore()
        let task = await store.addTask(title: "t", description: "d")
        #expect(await store.addWatch(TaskWatch(triggers: [.completed, .failed], action: .instructSmith("x"), createdBy: .user), to: task.id) == nil)
        await store.driveStatus(id: task.id, to: .completed)
        let stored = try #require(await store.task(id: task.id))
        let decoded = try JSONDecoder().decode(AgentTask.self, from: JSONEncoder().encode(stored))
        #expect(decoded.watches == stored.watches)
        #expect(decoded.pendingEffects == stored.pendingEffects)
    }
}

/// End to end through the runtime: a firing reaches its recipient and its outcome is recorded.
@Suite("Task watches — runtime delivery", .serialized)
struct TaskWatchRuntimeTests {

    private func waitUntil(timeout: Duration = .seconds(15), _ predicate: @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return await predicate()
    }

    private func makeRuntime() -> OrchestrationRuntime {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-smith-task-watch", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let configuration = ModelConfiguration(name: "test", providerID: "test", modelID: "test-model")
        return OrchestrationRuntime(
            providers: [
                .smith: MockLLMProvider(responses: [LLMResponse(text: "Standing by.")]),
                .securityAgent: MockLLMProvider(responses: [LLMResponse(text: "SAFE")]),
                .brown: MockLLMProvider(responses: [LLMResponse(text: "Working.")])
            ],
            configurations: [.smith: configuration, .securityAgent: configuration, .brown: configuration],
            providerAPITypes: [:],
            agentTuning: [
                .brown: AgentTuningConfig(pollInterval: 3600),
                .smith: AgentTuningConfig(pollInterval: 3600),
                .securityAgent: AgentTuningConfig(pollInterval: 3600)
            ],
            semanticSearchEngine: SemanticSearchEngine(),
            usageStore: UsageStore(persistence: PersistenceManager(testingRoot: tmpRoot)),
            autoAdvanceEnabled: false,
            autoRunInterruptedTasks: false,
            memoryStore: nil
        )
    }

    private func configure(_ runtime: OrchestrationRuntime) async {
        await runtime.setOrchestrationSettings(OrchestrationSettings.builtIn.applying(OrchestrationSettingsOverride(
            autoRunNextTask: false, autoRunInterruptedTasks: false, scopeToolSetOnTaskStart: false
        )))
    }

    @Test("An instructSmith watch reaches Smith, and the firing is recorded delivered once Smith has acted")
    func instructSmithDelivered() async throws {
        let runtime = makeRuntime()
        await configure(runtime)
        await runtime.start()
        let store = await runtime.taskStore
        let task = await store.addTask(title: "Report", description: "d")
        let watch = TaskWatch(triggers: [.interrupted], action: .instructSmith("Ping the user about Report."), createdBy: .user)
        #expect(await store.addWatch(watch, to: task.id) == nil)
        await store.updateStatus(id: task.id, status: .interrupted, cause: .smithSetStatus)

        let reachedSmith = await waitUntil {
            let context = await runtime.contextSnapshot(for: .smith)
            return context?.contains { $0.content.textValue?.contains("Ping the user about Report.") == true } == true
        }
        #expect(reachedSmith)
        let delivered = await waitUntil {
            if case .delivered = await store.task(id: task.id)?.watch(id: watch.id)?.firing(occurrence: 1)?.state { return true }
            return false
        }
        #expect(delivered)
        let fired = await waitUntil { await runtime.channel.allMessages().contains { $0.kind == .taskWatchFired && $0.taskID == task.id } }
        #expect(fired)
        await runtime.stopAll()
    }

    private actor BannerRecorder {
        private(set) var banners: [(title: String?, body: String)] = []
        func record(_ notification: AgentNotification, _ text: String) {
            let title: String?
            if case .string(let value)? = notification.payload.data[TaskWatchDelivery.Key.bannerTitle] { title = value } else { title = nil }
            banners.append((title, text))
        }
    }

    @Test("A macOS-notification watch reaches the app's bridge with its banner")
    func macOSNotificationDelivered() async throws {
        let runtime = makeRuntime()
        await configure(runtime)
        let recorder = BannerRecorder()
        await runtime.setExternalRecipientTarget(TaskWatchDelivery.macOSNotificationTarget, ClosureRecipientTarget { text, notification in
            await recorder.record(notification, text)
            return .delivered
        })
        await runtime.start()
        let store = await runtime.taskStore
        let task = await store.addTask(title: "Deploy", description: "d")
        let watch = TaskWatch(triggers: [.failed], action: .macOSNotification, createdBy: .user)
        #expect(await store.addWatch(watch, to: task.id) == nil)
        await store.addUpdate(id: task.id, message: "The build broke.")
        await store.updateStatus(id: task.id, status: .failed, cause: .smithSetStatus)
        let delivered = await waitUntil {
            if case .delivered = await store.task(id: task.id)?.watch(id: watch.id)?.firing(occurrence: 1)?.state { return true }
            return false
        }
        #expect(delivered)
        let banner = try #require(await recorder.banners.first)
        #expect(banner.title == "\"Deploy\" fails")
        #expect(banner.body == "The build broke.")
        await runtime.stopAll()
    }

    @Test("Notifications turned off in macOS become a visible refusal, not a silent drop")
    func macOSNotificationDenied() async throws {
        let runtime = makeRuntime()
        await configure(runtime)
        await runtime.setExternalRecipientTarget(TaskWatchDelivery.macOSNotificationTarget, ClosureRecipientTarget { _, _ in
            .refused("macOS notifications are turned off for Agent Smith")
        })
        await runtime.start()
        let store = await runtime.taskStore
        let task = await store.addTask(title: "Deploy", description: "d")
        let watch = TaskWatch(triggers: [.completed], action: .macOSNotification, createdBy: .user)
        #expect(await store.addWatch(watch, to: task.id) == nil)
        await store.updateStatus(id: task.id, status: .completed, cause: .smithSetStatus)
        let refused = await waitUntil {
            if case .refused(let reason) = await store.task(id: task.id)?.watch(id: watch.id)?.firing(occurrence: 1)?.state {
                return reason.contains("turned off")
            }
            return false
        }
        #expect(refused)
        let row = await waitUntil {
            await runtime.channel.allMessages().contains { $0.kind == .taskWatchRefused && $0.content.contains("turned off") }
        }
        #expect(row)
        await runtime.stopAll()
    }

    @Test("A summarize-to-user watch asks Smith to message the user, with the outcome")
    func summarizeToUserReachesSmith() async throws {
        let runtime = makeRuntime()
        await configure(runtime)
        await runtime.start()
        let store = await runtime.taskStore
        let task = await store.addTask(title: "Report", description: "d")
        #expect(await store.addWatch(TaskWatch(triggers: [.completed], action: .summarizeToUser, createdBy: .user), to: task.id) == nil)
        await store.setResult(id: task.id, result: "42 widgets shipped.", commentary: nil)
        await store.updateStatus(id: task.id, status: .completed, cause: .smithSetStatus)
        let asked = await waitUntil {
            let context = await runtime.contextSnapshot(for: .smith)
            return context?.contains {
                guard let text = $0.content.textValue else { return false }
                return text.contains("`message_user`") && text.contains("42 widgets shipped.")
            } == true
        }
        #expect(asked)
        await runtime.stopAll()
    }

    @Test("A startTask watch starts its target when the watched task completes")
    func startTaskChains() async throws {
        let runtime = makeRuntime()
        await configure(runtime)
        await runtime.start()
        let store = await runtime.taskStore
        let upstream = await store.addTask(title: "A", description: "d")
        let downstream = await store.addTask(title: "B", description: "d")
        #expect(await store.addWatch(TaskWatch(triggers: [.completed], action: .startTask(taskID: downstream.id), createdBy: .user), to: upstream.id) == nil)
        await store.updateStatus(id: upstream.id, status: .completed, cause: .smithSetStatus)
        let started = await waitUntil { await store.task(id: downstream.id)?.startedAt != nil }
        #expect(started)
        await runtime.stopAll()
    }

    @Test("A startTask watch whose target is not runnable is refused visibly, and the target is never reopened")
    func startTaskRefusalIsVisible() async throws {
        let runtime = makeRuntime()
        await configure(runtime)
        await runtime.start()
        let store = await runtime.taskStore
        let upstream = await store.addTask(title: "A", description: "d")
        let downstream = await store.addTask(title: "B", description: "d")
        let watch = TaskWatch(triggers: [.completed], action: .startTask(taskID: downstream.id), createdBy: .user)
        #expect(await store.addWatch(watch, to: upstream.id) == nil)
        await store.updateStatus(id: downstream.id, status: .completed, cause: .smithSetStatus)
        await store.updateStatus(id: upstream.id, status: .completed, cause: .smithSetStatus)
        let refused = await waitUntil {
            if case .refused = await store.task(id: upstream.id)?.watch(id: watch.id)?.firing(occurrence: 1)?.state { return true }
            return false
        }
        #expect(refused)
        #expect(await store.task(id: downstream.id)?.status == .completed, "a completed target is never reopened")
        #expect(await store.task(id: downstream.id)?.startHolds.isEmpty == true,
                "a refused chain link whose watch can't fire again doesn't leave its target waiting forever")
        let row = await waitUntil {
            await runtime.channel.allMessages().contains { $0.kind == .taskWatchRefused && $0.severity == .error && $0.taskID == upstream.id }
        }
        #expect(row)
        await runtime.stopAll()
    }
}
