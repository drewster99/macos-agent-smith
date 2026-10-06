import Foundation
import Testing
import SemanticSearch
import SwiftLLMKit
@testable import AgentSmithKit

/// A worker model that can't be used (out of credits, a rejected key, a model outside the plan) is
/// an account problem, not the task's. Decided 2026-10-06 (user): the task is PAUSED, not failed;
/// no task starts on that model until it is fixed; paused tasks resume when the worker's model
/// changes or the user presses Play. Before this, auto-advance failed five tasks in a row on a model
/// outside the account's plan.
@Suite("Provider outages")
struct ProviderOutageTests {

    private static let sharedEngine = SemanticSearchEngine()

    // MARK: - Classification

    @Test("account and model failures are recognized by status; a request's own failures are not")
    func classification() {
        func kind(_ status: Int) -> ProviderUnavailableKind? {
            ProviderUnavailableKind.of(LLMProviderError.httpError(statusCode: status, body: "{}"))
        }
        #expect(kind(401) == .unauthorized)
        #expect(kind(402) == .paymentRequired)
        #expect(kind(403) == .forbidden)
        #expect(kind(404) == .modelNotFound)
        for status in [400, 408, 413, 422, 429, 500, 503] {
            #expect(kind(status) == nil, "HTTP \(status) is not an account or model problem")
        }
        #expect(ProviderUnavailableKind.of(URLError(.timedOut)) == nil)
    }

    /// OpenRouter answers 403 when moderation flags the input: a refusal of that conversation, not
    /// of the account. Read from its typed error fields, never its message.
    @Test("an OpenRouter moderation 403 is not an account problem; a plain 403 is")
    func moderationForbidden() {
        let moderation = #"{"error":{"code":403,"message":"Your chosen model requires moderation and your input was flagged","metadata":{"reasons":["violence"],"flagged_input":"…"}}}"#
        #expect(ProviderUnavailableKind.of(LLMProviderError.httpError(statusCode: 403, body: moderation)) == nil)
        #expect(ProviderUnavailableKind.of(LLMProviderError.httpError(statusCode: 403, body: #"{"error":{"message":"forbidden"}}"#)) == .forbidden)
        #expect(ProviderUnavailableKind.of(LLMProviderError.httpError(statusCode: 403, body: "not json")) == .forbidden)
    }

    // MARK: - Runtime

    @Test("an unusable worker model pauses its task, holds back other starts, and a model change resumes them")
    func pauseHoldAndRelease() async throws {
        let runtime = try makeRuntime(brownProvider: PaymentRequiredProvider())
        await runtime.setOrchestrationSettings(OrchestrationSettings.builtIn.applying(OrchestrationSettingsOverride(
            autoRunNextTask: false,
            autoRunInterruptedTasks: false,
            enableTaskCompletionValidators: false,
            scopeToolSetOnTaskStart: false
        )))
        await runtime.setWorkerCapacity(2)
        await runtime.start()
        let store = await runtime.taskStore

        let first = await store.addTask(title: "First", description: "d")
        let second = await store.addTask(title: "Second", description: "d")
        await runtime.restartForNewTask(taskID: first.id, origin: .explicitUser)
        await runtime.waitForPendingRestarts()

        #expect(try await waitUntil { await store.task(id: first.id)?.status == .interrupted },
                "the task was not paused")
        #expect(await store.task(id: first.id)?.status != .failed, "an account problem failed the task")
        let outage = try #require(await runtime.workerProviderOutage())
        #expect(outage.kind == .paymentRequired)
        let advisories = await runtime.channel.allMessages().filter { $0.kind == .advisory && $0.severity == .error }
        #expect(advisories.count == 1, "the user must be told once")

        // Breaker: another start on the same model waits instead of failing too.
        await runtime.restartForNewTask(taskID: second.id, origin: .smithTool)
        await runtime.waitForPendingRestarts()
        #expect(await store.task(id: second.id)?.status == .pending, "a task started on an unusable model")

        // Switching the worker's model releases the outage and resumes both.
        await runtime.setProviders(
            providers: [.brown: StillThinkingLLMProvider()],
            configurations: [.brown: ModelConfiguration(name: "test", providerID: "test", modelID: "working-model")],
            apiTypes: [.brown: .openAICompatible]
        )
        #expect(await runtime.workerProviderOutage() == nil)
        let resumed = try await waitUntil {
            let firstStarted = await store.task(id: first.id)?.status == .running
            let secondStarted = await store.task(id: second.id)?.status == .running
            return firstStarted && secondStarted
        }
        let firstStatus = await store.task(id: first.id)?.status
        let secondStatus = await store.task(id: second.id)?.status
        let transcript = await runtime.channel.allMessages().suffix(12).map { "\($0.kind?.rawValue ?? "-"): \($0.content.prefix(140))" }
        #expect(resumed, "the waiting tasks did not resume after the worker's model changed: \(String(describing: firstStatus)), \(String(describing: secondStatus)); \(transcript)")
        await runtime.stopAll()
    }

    @Test("the user's Play retries the model; if it still can't be used, everything is paused again, never failed")
    func userRetryStillBroken() async throws {
        let runtime = try makeRuntime(brownProvider: PaymentRequiredProvider())
        await runtime.setOrchestrationSettings(OrchestrationSettings.builtIn.applying(OrchestrationSettingsOverride(
            autoRunNextTask: false,
            autoRunInterruptedTasks: false,
            enableTaskCompletionValidators: false,
            scopeToolSetOnTaskStart: false
        )))
        await runtime.setWorkerCapacity(2)
        await runtime.start()
        let store = await runtime.taskStore
        let first = await store.addTask(title: "First", description: "d")
        let second = await store.addTask(title: "Second", description: "d")
        await runtime.restartForNewTask(taskID: first.id, origin: .explicitUser)
        #expect(try await waitUntil { await store.task(id: first.id)?.status == .interrupted })

        // The user presses Play on another task: the outage is released and both are tried.
        await runtime.restartForNewTask(taskID: second.id, origin: .explicitUser)
        let bothPaused = try await waitUntil {
            let firstPaused = await store.task(id: first.id)?.status == .interrupted
            let secondPaused = await store.task(id: second.id)?.status == .interrupted
            return firstPaused && secondPaused
        }
        #expect(bothPaused, "a retry on a still-unusable model must pause, not fail")
        #expect(await runtime.workerProviderOutage() != nil, "the outage was not tripped again")
        await runtime.stopAll()
    }

    @Test("several workers failing on the same model tell the user once")
    func oneAdvisoryPerOutage() async throws {
        // Both workers' calls fail together. If the first failed before the second Play reached the
        // start gate, that Play would (rightly) retry the model and earn its own notice.
        let runtime = try makeRuntime(brownProvider: JointlyRefusingProvider(arrivals: CallArrivals(), refuseAfter: 2))
        await configure(runtime, capacity: 2)
        await runtime.start()
        let store = await runtime.taskStore
        let first = await store.addTask(title: "First", description: "d")
        let second = await store.addTask(title: "Second", description: "d")
        await runtime.restartForNewTask(taskID: first.id, origin: .explicitUser)
        await runtime.restartForNewTask(taskID: second.id, origin: .explicitUser)
        let bothPaused = try await waitUntil {
            let a = await store.task(id: first.id)?.status == .interrupted
            let b = await store.task(id: second.id)?.status == .interrupted
            return a && b
        }
        #expect(bothPaused)
        let advisories = await runtime.channel.allMessages().filter { $0.kind == .advisory && $0.severity == .error }
        #expect(advisories.count == 1, "one outage, one notice — got \(advisories.count)")
        await runtime.stopAll()
    }

    /// A call that started on the old model can fail after the user switched to a working one; its
    /// report must not re-trip the breaker against the NEW model.
    @Test("a failure reported for a model the worker no longer uses restarts the task and trips nothing")
    func staleModelReportIgnored() async throws {
        let runtime = try makeRuntime(brownProvider: StillThinkingLLMProvider())
        await configure(runtime, capacity: 2)
        await runtime.start()
        let store = await runtime.taskStore
        let task = await store.addTask(title: "Task", description: "d")
        await runtime.restartForNewTask(taskID: task.id, origin: .explicitUser)
        #expect(try await waitUntil { await store.task(id: task.id)?.status == .running })
        let worker = try #require(await runtime.liveWorkerID(taskID: task.id))

        await runtime.handleProviderUnavailable(
            ProviderOutage(role: .brown, providerID: "test", modelID: "an-old-model", kind: .paymentRequired, detail: "402"),
            agentID: worker
        )
        #expect(await runtime.workerProviderOutage() == nil, "a stale report tripped the breaker")
        let restarted = try await waitUntil {
            guard await store.task(id: task.id)?.status == .running,
                  let current = await runtime.liveWorkerID(taskID: task.id) else { return false }
            return current != worker
        }
        #expect(restarted, "the task was not restarted on the current model")
        await runtime.stopAll()
    }

    /// Released tasks beyond the free slots must still start — a never-started (pending) one
    /// included — once a slot frees, whatever the auto-run settings.
    @Test("a release with more waiting tasks than slots starts the rest as slots free")
    func releaseUnderCapacity() async throws {
        let runtime = try makeRuntime(brownProvider: PaymentRequiredProvider())
        await configure(runtime, capacity: 1)
        await runtime.start()
        let store = await runtime.taskStore
        let first = await store.addTask(title: "First", description: "d")
        let second = await store.addTask(title: "Second", description: "d")
        await runtime.restartForNewTask(taskID: first.id, origin: .explicitUser)
        #expect(try await waitUntil { await store.task(id: first.id)?.status == .interrupted })
        await runtime.restartForNewTask(taskID: second.id, origin: .smithTool)
        await runtime.waitForPendingRestarts()
        #expect(await store.task(id: second.id)?.status == .pending)

        await switchWorkerToWorkingModel(runtime)
        let oneRunning = try await waitUntil {
            let a = await store.task(id: first.id)?.status == .running
            let b = await store.task(id: second.id)?.status == .running
            return a != b
        }
        #expect(oneRunning, "exactly one of the two should run at capacity 1")
        let runningID = await store.task(id: first.id)?.status == .running ? first.id : second.id
        let waitingID = runningID == first.id ? second.id : first.id

        await runtime.terminateTaskAgents(taskID: runningID)
        _ = await store.driveStatus(id: runningID, to: .completed)
        #expect(try await waitUntil { await store.task(id: waitingID)?.status == .running },
                "the other released task never started when the slot freed")
        await runtime.stopAll()
    }

    @Test("a waiting task archived during the outage is not restarted by the release")
    func archivedWaitingTaskDropped() async throws {
        let runtime = try makeRuntime(brownProvider: PaymentRequiredProvider())
        await configure(runtime, capacity: 2)
        await runtime.start()
        let store = await runtime.taskStore
        let first = await store.addTask(title: "First", description: "d")
        let second = await store.addTask(title: "Second", description: "d")
        await runtime.restartForNewTask(taskID: first.id, origin: .explicitUser)
        #expect(try await waitUntil { await store.task(id: first.id)?.status == .interrupted })
        await runtime.restartForNewTask(taskID: second.id, origin: .smithTool)
        await runtime.waitForPendingRestarts()
        #expect(await store.archive(id: second.id))

        await switchWorkerToWorkingModel(runtime)
        #expect(try await waitUntil { await store.task(id: first.id)?.status == .running })
        await runtime.waitForPendingRestarts()
        let notFound = await runtime.channel.allMessages().filter { $0.content.contains("it was not found in the task store") }
        #expect(notFound.isEmpty, "the archived task was restarted")
        #expect(await store.task(id: second.id) == nil, "the archived task came back to the active list")
        await runtime.stopAll()
    }

    // MARK: - Helpers

    @Test("only a 429 that outlasted every retry is attributed to the model")
    func retryExhaustionClassification() {
        func kind(_ status: Int) -> ProviderUnavailableKind? {
            ProviderUnavailableKind.afterRetriesExhausted(on: LLMProviderError.httpError(statusCode: status, body: "{}"))
        }
        #expect(kind(429) == .rateLimitExhausted)
        #expect(kind(503) == nil, "a server fault says nothing about the account")
        #expect(kind(500) == nil)
        #expect(kind(408) == nil)
        #expect(ProviderUnavailableKind.afterRetriesExhausted(on: URLError(.timedOut)) == nil)
        #expect(ProviderUnavailableKind.of(LLMProviderError.httpError(statusCode: 429, body: "{}")) == nil,
                "a single 429 is transient")
    }

    @Test("a worker whose 429s outlast its retries pauses its task and holds other starts, never fails it")
    func rateLimitExhaustionPauses() async throws {
        let runtime = try makeRuntime(brownProvider: UsageLimitProvider())
        await configure(runtime, capacity: 2)
        await runtime.start()
        let store = await runtime.taskStore
        let first = await store.addTask(title: "First", description: "d")
        let second = await store.addTask(title: "Second", description: "d")
        await runtime.restartForNewTask(taskID: first.id, origin: .explicitUser)

        // Cut the 50-attempt budget down so the exhaustion path runs in seconds.
        #expect(try await waitUntil { await runtime.liveWorkerID(taskID: first.id) != nil })
        let workerID = try #require(await runtime.liveWorkerID(taskID: first.id))
        let worker = try #require(await runtime.liveAgent(id: workerID))
        await worker.limitRetryAttemptsForTesting(to: 2)

        #expect(try await waitUntil(timeout: .seconds(30)) { await store.task(id: first.id)?.status == .interrupted },
                "the task was not paused")
        #expect(await store.task(id: first.id)?.status != .failed)
        let outage = try #require(await runtime.workerProviderOutage())
        #expect(outage.kind == .rateLimitExhausted)
        let messages = await runtime.channel.allMessages()
        let stopLine = messages.first { $0.kind == .agentLifecycle && $0.content.contains("HTTP 429") }
        #expect(stopLine?.content.contains("Its task is paused") == true)
        #expect(stopLine?.severity == .warning)
        #expect(messages.contains { $0.content.contains("once the provider's limit resets") },
                "the advisory names the right way to retry")

        // Another start waits on the outage instead of burning its own 50 retries.
        await runtime.restartForNewTask(taskID: second.id, origin: .smithTool)
        await runtime.waitForPendingRestarts()
        #expect(await store.task(id: second.id)?.status == .pending)
        await runtime.stopAll()
    }

    private func configure(_ runtime: OrchestrationRuntime, capacity: Int) async {
        await runtime.setOrchestrationSettings(OrchestrationSettings.builtIn.applying(OrchestrationSettingsOverride(
            autoRunNextTask: false,
            autoRunInterruptedTasks: false,
            enableTaskCompletionValidators: false,
            scopeToolSetOnTaskStart: false
        )))
        await runtime.setWorkerCapacity(capacity)
    }

    private func switchWorkerToWorkingModel(_ runtime: OrchestrationRuntime) async {
        await runtime.setProviders(
            providers: [.brown: StillThinkingLLMProvider()],
            configurations: [.brown: ModelConfiguration(name: "test", providerID: "test", modelID: "working-model")],
            apiTypes: [.brown: .openAICompatible]
        )
    }

    /// Every call is refused with HTTP 402, as Ollama answers for a model outside the plan.
    private struct PaymentRequiredProvider: LLMProvider {
        func send(messages: [LLMMessage], tools: [LLMToolDefinition], overrides: LLMCallOverrides) async throws -> LLMResponse {
            throw LLMProviderError.httpError(statusCode: 402, body: #"{"error":{"message":"This model is not in the Free plan."}}"#)
        }
    }

    /// Every call is refused with HTTP 429 and no stated delay, as Ollama answers once a free-plan
    /// usage limit is reached.
    private struct UsageLimitProvider: LLMProvider {
        func send(messages: [LLMMessage], tools: [LLMToolDefinition], overrides: LLMCallOverrides) async throws -> LLMResponse {
            throw LLMProviderError.httpError(statusCode: 429, body: #"{"error":"You reached the Free usage limit."}"#)
        }
    }

    private actor CallArrivals {
        private(set) var count = 0
        func arrive() { count += 1 }
    }

    /// Refuses with HTTP 402, but only once `refuseAfter` calls have arrived, so concurrent workers
    /// all fail on the same outage.
    private struct JointlyRefusingProvider: LLMProvider {
        let arrivals: CallArrivals
        let refuseAfter: Int

        func send(messages: [LLMMessage], tools: [LLMToolDefinition], overrides: LLMCallOverrides) async throws -> LLMResponse {
            await arrivals.arrive()
            while await arrivals.count < refuseAfter {
                try await Task.sleep(for: .milliseconds(10))
            }
            throw LLMProviderError.httpError(statusCode: 402, body: #"{"error":{"message":"This model is not in the Free plan."}}"#)
        }
    }

    private func waitUntil(timeout: Duration = .seconds(15), _ predicate: @Sendable () async -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await predicate() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return await predicate()
    }

    private func makeRuntime(brownProvider: any LLMProvider) throws -> OrchestrationRuntime {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-smith-provider-outage-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let config = ModelConfiguration(name: "test", providerID: "test", modelID: "test-model")
        return OrchestrationRuntime(
            providers: [
                .smith: MockLLMProvider(responses: [LLMResponse(text: "Standing by.")]),
                .securityAgent: MockLLMProvider(responses: [LLMResponse(text: "SAFE")]),
                .brown: brownProvider
            ],
            configurations: [.smith: config, .securityAgent: config, .brown: config],
            providerAPITypes: [.smith: .openAICompatible, .securityAgent: .openAICompatible, .brown: .openAICompatible],
            agentTuning: [
                .brown: AgentTuningConfig(pollInterval: 3600),
                .smith: AgentTuningConfig(pollInterval: 3600),
                .securityAgent: AgentTuningConfig(pollInterval: 3600)
            ],
            semanticSearchEngine: Self.sharedEngine,
            usageStore: UsageStore(persistence: PersistenceManager(testingRoot: tmpRoot)),
            autoAdvanceEnabled: false,
            autoRunInterruptedTasks: false,
            memoryStore: nil
        )
    }
}
