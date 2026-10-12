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

    @Test("terminating a worker does not wait for another task's tool scoping; that start is retried after it")
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
            _ = await runtime.terminateAgent(id: runningWorker)
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
