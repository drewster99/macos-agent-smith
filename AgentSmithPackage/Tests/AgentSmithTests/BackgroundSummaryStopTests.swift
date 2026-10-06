import Foundation
import Testing
import SemanticSearch
import SwiftLLMKit
@testable import AgentSmithKit

/// Task summaries run in the background (2026-10-06). A full Stop cancels the ones still running —
/// they would keep billing the Summarizer after the user stopped, and land on a task store the next
/// Start retires — and names each task whose summary was therefore never written.
@Suite("Background summaries on Stop")
struct BackgroundSummaryStopTests {

    private static let sharedEngine = SemanticSearchEngine()

    @Test("Stop cancels a running summary and says which task's summary was not written")
    func stopCancelsRunningSummary() async throws {
        let summarizer = HangingSummarizerProvider()
        let runtime = try makeRuntime(summarizerProvider: summarizer)
        await runtime.start()
        let store = await runtime.taskStore
        await store.restore([AgentTask(title: "Finished work", description: "d", status: .completed)])
        let task = try #require(await store.allTasks().first { $0.title == "Finished work" })

        await runtime.summarizeAndEmbedTaskInBackground(taskID: task.id)
        #expect(try await waitUntil { await summarizer.callStarted }, "the summary never reached the Summarizer")

        await runtime.stopAll()

        #expect(await summarizer.wasCancelled, "Stop must end the Summarizer call, not leave it billing")
        let note = await runtime.channel.allMessages().first {
            $0.kind == .advisory && $0.taskID == task.id && $0.content.contains("Stopped before the summary")
        }
        #expect(note != nil)
        #expect(note?.content.contains("Finished work") == true)
        #expect(note?.severity == .warning)
        #expect(await store.task(id: task.id)?.summary == nil)
    }

    @Test("a summary that finished before Stop is kept and not reported")
    func finishedSummaryIsNotReported() async throws {
        let runtime = try makeRuntime(summarizerProvider: MockLLMProvider(responses: [LLMResponse(text: "What was done.")]))
        await runtime.start()
        let store = await runtime.taskStore
        await store.restore([AgentTask(title: "Quick work", description: "d", status: .completed)])
        let task = try #require(await store.allTasks().first { $0.title == "Quick work" })

        await runtime.summarizeAndEmbedTaskInBackground(taskID: task.id)
        #expect(try await waitUntil { await store.task(id: task.id)?.summary != nil })

        await runtime.stopAll()
        #expect(!(await runtime.channel.allMessages().contains { $0.content.contains("Stopped before the summary") }))
    }

    // MARK: - Helpers

    /// A Summarizer call that never answers until cancelled, recording both.
    private actor HangingSummarizerProvider: LLMProvider {
        private(set) var callStarted = false
        private(set) var wasCancelled = false

        func send(messages: [LLMMessage], tools: [LLMToolDefinition], overrides: LLMCallOverrides) async throws -> LLMResponse {
            callStarted = true
            do {
                try await Task.sleep(for: .seconds(3600))
            } catch {
                wasCancelled = true
                throw error
            }
            return LLMResponse(text: "unreachable")
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

    private func makeRuntime(summarizerProvider: any LLMProvider) throws -> OrchestrationRuntime {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-smith-background-summary-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let config = ModelConfiguration(name: "test", providerID: "test", modelID: "test-model")
        return OrchestrationRuntime(
            providers: [
                .smith: MockLLMProvider(responses: [LLMResponse(text: "Standing by.")]),
                .securityAgent: MockLLMProvider(responses: [LLMResponse(text: "SAFE")]),
                .brown: MockLLMProvider(responses: [LLMResponse(text: "Working.")]),
                .summarizer: summarizerProvider
            ],
            configurations: [.smith: config, .securityAgent: config, .brown: config, .summarizer: config],
            providerAPITypes: [.smith: .openAICompatible, .securityAgent: .openAICompatible, .brown: .openAICompatible, .summarizer: .openAICompatible],
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
