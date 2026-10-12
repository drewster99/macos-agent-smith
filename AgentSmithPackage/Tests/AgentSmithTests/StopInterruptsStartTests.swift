import Foundation
import Testing
import SemanticSearch
@testable import AgentSmithKit

/// A stop never waits behind another task's tool-scoping call (decided 2026-10-11, user). The start
/// is set aside — back to where it was — and started again behind the stop. Only stops interrupt,
/// and never the start of the task being stopped. See `OrchestrationRuntime.interruptStartForStop`.
@Suite("Stops interrupt a start that is choosing its tools")
struct StopInterruptsStartTests {

    private static let slowMarker = "SLOW-SCOPE"

    /// The Security Agent's model: scoping for a task titled with `slowMarker` never answers until
    /// cancelled; everything else is approved at once.
    private final class SlowScopingProvider: LLMProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var _slowCalls = 0
        var slowCalls: Int { lock.withLock { _slowCalls } }

        func send(messages: [LLMMessage], tools: [LLMToolDefinition], overrides: LLMCallOverrides) async throws -> LLMResponse {
            let isSlow = messages.contains { message in
                guard case .text(let text) = message.content else { return false }
                return text.contains(StopInterruptsStartTests.slowMarker)
            }
            if isSlow {
                lock.withLock { _slowCalls += 1 }
                try await Task.sleep(for: .seconds(3600))
                throw CancellationError()
            }
            return LLMResponse(text: "{\"toolResponses\":[{\"toolID\":\"file_read\",\"isAllowed\":true}]}")
        }
    }

    /// Set once the awaited stop returned.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var _isSet = false
        var isSet: Bool { lock.withLock { _isSet } }
        func set() { lock.withLock { _isSet = true } }
    }

    private func makeRuntime(securityProvider: SlowScopingProvider) async throws -> OrchestrationRuntime {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-smith-stop-interrupts-start-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let configuration = ModelConfiguration(name: "test", providerID: "test", modelID: "test-model")
        let runtime = OrchestrationRuntime(
            providers: [
                .smith: MockLLMProvider(responses: [LLMResponse(text: "Standing by.")]),
                .securityAgent: securityProvider,
                .brown: StillThinkingLLMProvider()
            ],
            configurations: [.smith: configuration, .securityAgent: configuration, .brown: configuration],
            providerAPITypes: [:],
            agentTuning: [:],
            semanticSearchEngine: SemanticSearchEngine(),
            usageStore: UsageStore(persistence: PersistenceManager(testingRoot: tmpRoot)),
            autoAdvanceEnabled: false,
            autoRunInterruptedTasks: false,
            memoryStore: nil
        )
        await runtime.setOrchestrationSettings(OrchestrationSettings.builtIn.applying(OrchestrationSettingsOverride(
            autoRunNextTask: false,
            autoRunInterruptedTasks: false,
            enableTaskCompletionValidators: false,
            scopeToolSetOnTaskStart: true
        )))
        await runtime.setWorkerCapacity(4)
        await runtime.start()
        return runtime
    }

    private func waitUntil(timeout: Duration = .seconds(30), _ predicate: @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return await predicate()
    }

    @Test("stopping a worker does not wait for another task's tool scoping; that start is retried after it")
    func stopRunsAheadOfScopingStart() async throws {
        let security = SlowScopingProvider()
        let runtime = try await makeRuntime(securityProvider: security)
        let store = await runtime.taskStore

        let running = await store.addTask(title: "Already running", description: "d")
        await runtime.restartForNewTask(taskID: running.id, origin: .explicitUser)
        await runtime.waitForPendingRestarts()
        let runningWorker = try #require(await runtime.liveWorkerID(taskID: running.id))

        let starting = await store.addTask(title: "\(Self.slowMarker) task", description: "d")
        await runtime.restartForNewTask(taskID: starting.id, origin: .explicitUser)
        #expect(await waitUntil { security.slowCalls == 1 }, "the slow start never began choosing its tools")

        let stopped = Flag()
        Task {
            _ = await runtime.stopWorker(id: runningWorker, callerID: UUID())
            stopped.set()
        }
        #expect(await waitUntil { stopped.isSet }, "the stop waited behind the other task's tool scoping")
        #expect(await runtime.liveWorkerID(taskID: running.id) == nil)

        // The set-aside start runs again, from the top, after the stop.
        #expect(await waitUntil { security.slowCalls == 2 }, "the interrupted start was never retried")
        #expect(await store.task(id: starting.id)?.status == .starting)
        let notices = await runtime.channel.allMessages().filter { $0.content.contains("set aside so a stop could run first") }
        #expect(notices.count == 1)

        await runtime.stopAll()
    }

    /// The 2026-10-11 incident's backlog: starts already queued AHEAD of the stop, each a full
    /// scoping call. They step behind a waiting stop instead of running first.
    @Test("a stop does not wait behind starts queued ahead of it — another task's, or a duplicate of the interrupted one")
    func stopRunsAheadOfQueuedStarts() async throws {
        let security = SlowScopingProvider()
        let runtime = try await makeRuntime(securityProvider: security)
        let store = await runtime.taskStore

        let running = await store.addTask(title: "Already running", description: "d")
        await runtime.restartForNewTask(taskID: running.id, origin: .explicitUser)
        await runtime.waitForPendingRestarts()
        let runningWorker = try #require(await runtime.liveWorkerID(taskID: running.id))

        let starting = await store.addTask(title: "\(Self.slowMarker) first", description: "d")
        await runtime.restartForNewTask(taskID: starting.id, origin: .explicitUser)
        #expect(await waitUntil { security.slowCalls == 1 })
        // Queued behind the scoping start, ahead of the stop: a duplicate start of the same task (the
        // replay found these re-claiming the task the interrupt had just set aside) and another task.
        await runtime.restartForNewTask(taskID: starting.id, origin: .autoAdvance)
        let queued = await store.addTask(title: "\(Self.slowMarker) queued", description: "d")
        await runtime.restartForNewTask(taskID: queued.id, origin: .autoAdvance)

        let stopped = Flag()
        Task {
            _ = await runtime.stopWorker(id: runningWorker, callerID: UUID())
            stopped.set()
        }
        #expect(await waitUntil { stopped.isSet }, "the stop waited behind a start queued ahead of it")
        #expect(await runtime.liveWorkerID(taskID: running.id) == nil)
        // Every start still happens, after the stop: the set-aside one once, and the queued one.
        #expect(await waitUntil { await store.task(id: starting.id)?.status == .starting })
        #expect(await store.task(id: queued.id)?.status == .pending, "the queued start ran ahead of the set-aside one's retry")

        await runtime.stopAll()
    }

    @Test("stopping the task that is being started does not interrupt its start")
    func stopOfStartingTaskWaits() async throws {
        let security = SlowScopingProvider()
        let runtime = try await makeRuntime(securityProvider: security)
        let store = await runtime.taskStore

        let starting = await store.addTask(title: "\(Self.slowMarker) task", description: "d")
        await runtime.restartForNewTask(taskID: starting.id, origin: .explicitUser)
        #expect(await waitUntil { security.slowCalls == 1 })

        let stopped = Flag()
        Task {
            await runtime.terminateTaskAgents(taskID: starting.id)
            stopped.set()
        }
        try await Task.sleep(for: .seconds(1))
        #expect(stopped.isSet == false, "a stop of the starting task itself must not cut its start short")
        #expect(security.slowCalls == 1)
        #expect(await store.task(id: starting.id)?.status == .starting)

        await runtime.stopAll()
        #expect(await waitUntil { stopped.isSet })
    }

    /// Archiving a finished task runs `terminateTaskAgents` with nothing to end. Interrupting for
    /// it would throw away the scoping call — once per archived task in a bulk archive.
    @Test("a stop with no live worker to end skips the queue and does not interrupt a start")
    func stopWithoutWorkerDoesNotInterrupt() async throws {
        let security = SlowScopingProvider()
        let runtime = try await makeRuntime(securityProvider: security)
        let store = await runtime.taskStore

        let idle = await store.addTask(title: "Never started", description: "d")
        let starting = await store.addTask(title: "\(Self.slowMarker) task", description: "d")
        await runtime.restartForNewTask(taskID: starting.id, origin: .explicitUser)
        #expect(await waitUntil { security.slowCalls == 1 })

        let stopped = Flag()
        Task {
            await runtime.terminateTaskAgents(taskID: idle.id)
            stopped.set()
        }
        #expect(await waitUntil { stopped.isSet }, "a stop with nothing to end waited behind the start")
        #expect(security.slowCalls == 1, "a stop with nothing to end cut the start short")
        let notices = await runtime.channel.allMessages().filter { $0.content.contains("set aside so a stop could run first") }
        #expect(notices.isEmpty)

        await runtime.stopAll()
        #expect(await waitUntil { stopped.isSet })
    }

    /// Validation tears down a finished task's worker through `terminateAgent` after every
    /// completion; in a busy pool each would discard another task's scoping call.
    @Test("routine worker teardown does not interrupt a start")
    func routineTeardownDoesNotInterrupt() async throws {
        let security = SlowScopingProvider()
        let runtime = try await makeRuntime(securityProvider: security)
        let store = await runtime.taskStore

        let finished = await store.addTask(title: "Finishing", description: "d")
        await runtime.restartForNewTask(taskID: finished.id, origin: .explicitUser)
        await runtime.waitForPendingRestarts()
        let finishedWorker = try #require(await runtime.liveWorkerID(taskID: finished.id))

        let starting = await store.addTask(title: "\(Self.slowMarker) task", description: "d")
        await runtime.restartForNewTask(taskID: starting.id, origin: .explicitUser)
        #expect(await waitUntil { security.slowCalls == 1 })

        let tornDown = Flag()
        Task {
            _ = await runtime.terminateAgent(id: finishedWorker)
            tornDown.set()
        }
        try await Task.sleep(for: .seconds(1))
        #expect(security.slowCalls == 1, "a routine teardown cut the start short")
        #expect(tornDown.isSet == false)

        await runtime.stopAll()
        #expect(await waitUntil { tornDown.isSet })
    }

    /// The user archives a finished task while a start is choosing its tools: the archive's stop
    /// has nothing to end, so it must not wait 30–60 s behind that start (2026-10-11: the user's
    /// archive clicks waited out an 86 s stall).
    @Test("archiving a finished task does not wait for a start choosing its tools")
    func archiveOfFinishedTaskSkipsQueue() async throws {
        let security = SlowScopingProvider()
        let runtime = try await makeRuntime(securityProvider: security)
        let store = await runtime.taskStore

        let finished = await store.addTask(title: "Finished", description: "d")
        #expect(await store.updateStatus(id: finished.id, status: .failed, cause: .smithSetStatus))
        let starting = await store.addTask(title: "\(Self.slowMarker) task", description: "d")
        await runtime.restartForNewTask(taskID: starting.id, origin: .explicitUser)
        #expect(await waitUntil { security.slowCalls == 1 })

        let stopped = Flag()
        Task {
            await runtime.terminateTaskAgents(taskID: finished.id)
            stopped.set()
        }
        #expect(await waitUntil { stopped.isSet }, "the archive's stop waited behind the start")
        #expect(security.slowCalls == 1)
        #expect(await store.task(id: starting.id)?.status == .starting, "the start was disturbed")

        await runtime.stopAll()
    }

    @Test("starts never interrupt each other")
    func startDoesNotInterruptStart() async throws {
        let security = SlowScopingProvider()
        let runtime = try await makeRuntime(securityProvider: security)
        let store = await runtime.taskStore

        let first = await store.addTask(title: "\(Self.slowMarker) first", description: "d")
        await runtime.restartForNewTask(taskID: first.id, origin: .explicitUser)
        #expect(await waitUntil { security.slowCalls == 1 })

        let second = await store.addTask(title: "Second", description: "d")
        await runtime.restartForNewTask(taskID: second.id, origin: .explicitUser)
        try await Task.sleep(for: .seconds(1))
        #expect(security.slowCalls == 1, "the first start was cut short by another start")
        #expect(await store.task(id: first.id)?.status == .starting)
        #expect(await store.task(id: second.id)?.status == .pending, "the second start ran ahead of the first")

        await runtime.stopAll()
    }
}
