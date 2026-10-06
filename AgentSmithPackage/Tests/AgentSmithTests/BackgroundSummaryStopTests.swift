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
        try await withRuntime(summarizerProvider: summarizer) { runtime, store in
            let taskID = try await addCompletedTask("Finished work", to: store)
            await runtime.summarizeAndEmbedTaskInBackground(taskID: taskID)
            let called = try await waitUntil { await summarizer.callCount == 1 }
            #expect(called, "the summary never reached the Summarizer")

            await runtime.stopAll()

            #expect(await summarizer.cancellations == 1, "Stop must end the Summarizer call, not leave it billing")
            let messages = await runtime.channel.allMessages()
            let note = messages.first { $0.kind == .advisory && $0.taskID == taskID && $0.content.contains("Stopped before the summary") }
            #expect(note?.content.contains("Finished work") == true)
            #expect(note?.severity == .warning)
            // A cancelled transfer throws URLError.cancelled, which reads as transient: it must not
            // be announced as a retry.
            #expect(!messages.contains { $0.content.contains("Summarization retry") })
        }
    }

    @Test("a summary that finished before Stop is kept and not reported")
    func finishedSummaryIsNotReported() async throws {
        try await withRuntime(summarizerProvider: MockLLMProvider(responses: [LLMResponse(text: "What was done.")])) { runtime, store in
            let taskID = try await addCompletedTask("Quick work", to: store)
            await runtime.summarizeAndEmbedTaskInBackground(taskID: taskID)
            let written = try await waitUntil { await store.task(id: taskID)?.summary != nil }
            #expect(written)
            await runtime.stopAll()
            #expect(!(await runtime.channel.allMessages().contains { $0.content.contains("Stopped before the summary") }))
        }
    }

    /// A completion can land while Stop runs (its lifecycle step queued behind the Stop). Its
    /// summary must not start after Stop has already cancelled the others.
    @Test("a summary requested after Stop is not started, and says so")
    func summaryAfterStopIsNotStarted() async throws {
        let summarizer = HangingSummarizerProvider()
        try await withRuntime(summarizerProvider: summarizer) { runtime, store in
            let taskID = try await addCompletedTask("Late completion", to: store)
            await runtime.stopAll()
            await runtime.summarizeAndEmbedTaskInBackground(taskID: taskID)
            let noted = try await waitUntil {
                await runtime.channel.allMessages().contains { $0.taskID == taskID && $0.content.contains("Stopped before the summary") }
            }
            #expect(noted)
            #expect(await summarizer.callCount == 0, "a summary started after Stop")
        }
    }

    /// A task reopened and completed again is summarized again; the older run, still waiting on
    /// its provider, would otherwise overwrite the newer summary with an older snapshot.
    @Test("a newer summary of a task cancels the older one still running")
    func newerSummarySupersedesOlder() async throws {
        let summarizer = HangingSummarizerProvider()
        try await withRuntime(summarizerProvider: summarizer) { runtime, store in
            let taskID = try await addCompletedTask("Done twice", to: store)
            await runtime.summarizeAndEmbedTaskInBackground(taskID: taskID)
            let firstCalled = try await waitUntil { await summarizer.callCount == 1 }
            #expect(firstCalled)
            await runtime.summarizeAndEmbedTaskInBackground(taskID: taskID)
            let superseded = try await waitUntil {
                let cancellations = await summarizer.cancellations
                let calls = await summarizer.callCount
                return cancellations == 1 && calls == 2
            }
            #expect(superseded, "the older summary was not cancelled")

            await runtime.stopAll()
            let notes = await runtime.channel.allMessages().filter { $0.taskID == taskID && $0.content.contains("Stopped before the summary") }
            #expect(notes.count == 1, "only the run Stop cancelled is reported")
        }
    }

    // MARK: - Helpers

    /// A Summarizer call that never answers until cancelled, failing then the way a real transfer
    /// does (`URLError.cancelled`, not `CancellationError`).
    private actor HangingSummarizerProvider: LLMProvider {
        private(set) var callCount = 0
        private(set) var cancellations = 0

        func send(messages: [LLMMessage], tools: [LLMToolDefinition], overrides: LLMCallOverrides) async throws -> LLMResponse {
            callCount += 1
            do {
                try await Task.sleep(for: .seconds(3600))
            } catch {
                cancellations += 1
                throw URLError(.cancelled)
            }
            throw URLError(.timedOut)
        }
    }

    private func addCompletedTask(_ title: String, to store: TaskStore) async throws -> UUID {
        let taskID = await store.addTask(title: title, description: "d").id
        let completed = await store.driveStatus(id: taskID, to: .completed)
        try #require(completed)
        return taskID
    }

    /// Runs `body` on a started runtime and always stops it and removes its files, even when the
    /// body throws.
    private func withRuntime(
        summarizerProvider: any LLMProvider,
        _ body: (OrchestrationRuntime, TaskStore) async throws -> Void
    ) async throws {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-smith-background-summary-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let runtime = makeRuntime(summarizerProvider: summarizerProvider, tmpRoot: tmpRoot)
        await runtime.start()
        var failure: Error?
        do {
            try await body(runtime, await runtime.taskStore)
        } catch {
            failure = error
        }
        await runtime.stopAll()
        do {
            try FileManager.default.removeItem(at: tmpRoot)
        } catch {
            Issue.record("could not remove the test's files at \(tmpRoot.path): \(error)")
        }
        if let failure { throw failure }
    }

    private func waitUntil(timeout: Duration = .seconds(15), _ predicate: @Sendable () async -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await predicate() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return await predicate()
    }

    private func makeRuntime(summarizerProvider: any LLMProvider, tmpRoot: URL) -> OrchestrationRuntime {
        let config = ModelConfiguration(name: "test", providerID: "test", modelID: "test-model")
        return OrchestrationRuntime(
            providers: [
                .smith: MockLLMProvider(responses: [LLMResponse(text: "Standing by.")]),
                .securityAgent: MockLLMProvider(responses: [LLMResponse(text: "SAFE")]),
                .brown: StillThinkingLLMProvider(),
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
