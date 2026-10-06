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

    // MARK: - Runtime

    @Test("an unusable worker model pauses its task, holds back other starts, and a model change resumes them")
    func pauseHoldAndRelease() async throws {
        let runtime = makeRuntime(brownProvider: PaymentRequiredProvider())
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

        #expect(await waitUntil { await store.task(id: first.id)?.status == .interrupted },
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
            providers: [.brown: ThinkingProvider()],
            configurations: [.brown: ModelConfiguration(name: "test", providerID: "test", modelID: "working-model")],
            apiTypes: [.brown: .openAICompatible]
        )
        #expect(await runtime.workerProviderOutage() == nil)
        let resumed = await waitUntil {
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
        let runtime = makeRuntime(brownProvider: PaymentRequiredProvider())
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
        #expect(await waitUntil { await store.task(id: first.id)?.status == .interrupted })

        // The user presses Play on another task: the outage is released and both are tried.
        await runtime.restartForNewTask(taskID: second.id, origin: .explicitUser)
        let bothPaused = await waitUntil {
            let firstPaused = await store.task(id: first.id)?.status == .interrupted
            let secondPaused = await store.task(id: second.id)?.status == .interrupted
            return firstPaused && secondPaused
        }
        #expect(bothPaused, "a retry on a still-unusable model must pause, not fail")
        #expect(await runtime.workerProviderOutage() != nil, "the outage was not tripped again")
        await runtime.stopAll()
    }

    // MARK: - Helpers

    /// Every call is refused with HTTP 402, as Ollama answers for a model outside the plan.
    private struct PaymentRequiredProvider: LLMProvider {
        func send(messages: [LLMMessage], tools: [LLMToolDefinition], overrides: LLMCallOverrides) async throws -> LLMResponse {
            throw LLMProviderError.httpError(statusCode: 402, body: #"{"error":{"message":"This model is not in the Free plan."}}"#)
        }
    }

    /// A working model that is still thinking: keeps a resumed task running (cancellably).
    private struct ThinkingProvider: LLMProvider {
        func send(messages: [LLMMessage], tools: [LLMToolDefinition], overrides: LLMCallOverrides) async throws -> LLMResponse {
            try await Task.sleep(for: .seconds(3600))
            return LLMResponse(text: "unreachable")
        }
    }

    private func waitUntil(timeout: Duration = .seconds(15), _ predicate: @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await predicate()
    }

    private func makeRuntime(brownProvider: any LLMProvider) -> OrchestrationRuntime {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-smith-provider-outage-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
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
