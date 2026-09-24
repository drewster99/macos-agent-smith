import Testing
import Foundation
@testable import AgentSmithKit

/// Every Summarizer provider call — task summary, memory reconciliation, web extraction — reaches
/// the inspector with its exact request, operation, task, and correlation; a thrown call is a
/// failure record. These are the same calls the Summarizer's session cost is made of.
@Suite("TaskSummarizer inspector call capture")
struct TaskSummarizerInspectorTests {
    private static let sharedEngine = SemanticSearchEngine()

    private func makeSummarizer(_ provider: ScriptedProvider) async -> (TaskSummarizer, EventCollector) {
        let summarizer = TaskSummarizer(
            provider: provider,
            memoryStore: MemoryStore(engine: Self.sharedEngine),
            channel: MessageChannel(),
            contextWindowSize: 100_000,
            maxOutputTokens: 1_000
        )
        let collector = EventCollector()
        await summarizer.setOnLLMCallRecorded { collector.record($0) }
        return (summarizer, collector)
    }

    @Test("memory reconciliation records its exact request, task, and correlation")
    func reconciliationIsCaptured() async {
        let provider = ScriptedProvider([.respond(LLMResponse(text: "SAME\nmerged text"))])
        let (summarizer, collector) = await makeSummarizer(provider)
        let correlationID = UUID()
        let taskID = UUID()
        let result = await summarizer.reconcileMemoryTexts(
            existing: "old", new: "new", correlationID: correlationID, taskID: taskID, taskTitle: "T")

        #expect(result == .merged("merged text"))
        let turns = collector.turns
        #expect(turns.count == 1)
        #expect(turns.first?.outgoingMessages == provider.receivedRequests.first)
        #expect(turns.first?.contextSnapshot == provider.receivedRequests.first)
        #expect(turns.first?.annotation?.operation == .memoryReconciliation)
        #expect(turns.first?.annotation?.correlationID == correlationID)
        #expect(turns.first?.annotation?.taskID == taskID)
        #expect(turns.first?.annotation?.taskTitle == "T")
    }

    @Test("web extraction records its exact request and task")
    func webExtractionIsCaptured() async {
        let provider = ScriptedProvider([.respond(LLMResponse(text: "the answer"))])
        let (summarizer, collector) = await makeSummarizer(provider)
        let taskID = UUID()
        let answer = await summarizer.extractWebContent(content: "page", prompt: "what?", taskID: taskID, taskTitle: "W")

        #expect(answer == "the answer")
        #expect(collector.turns.first?.outgoingMessages == provider.receivedRequests.first)
        #expect(collector.turns.first?.annotation?.operation == .webContentExtraction)
        #expect(collector.turns.first?.annotation?.taskID == taskID)
    }

    @Test("task summarization records its exact request and task")
    func taskSummaryIsCaptured() async throws {
        let provider = ScriptedProvider([.respond(LLMResponse(text: "It was done."))])
        let (summarizer, collector) = await makeSummarizer(provider)
        let task = AgentTask(title: "Summarize me", description: "d")
        let annotation = LLMCallAnnotation(operation: .taskSummary, taskID: task.id, taskTitle: task.title)
            .forCall(1)
        let summary = try await summarizer.generateSummary(for: task, annotation: annotation)

        #expect(summary == "It was done.")
        #expect(collector.turns.first?.outgoingMessages == provider.receivedRequests.first)
        #expect(collector.turns.first?.annotation == annotation)
    }

    @Test("a transient failure is a failure record, and the retry is its own numbered call")
    func retriesAreRepresented() async {
        let provider = ScriptedProvider([
            .fail(.httpError(statusCode: 503, body: "busy")),
            .respond(LLMResponse(text: "DIFFERENT")),
        ])
        let (summarizer, collector) = await makeSummarizer(provider)
        let result = await summarizer.reconcileMemoryTexts(
            existing: "a", new: "b", correlationID: UUID(), taskID: nil, taskTitle: nil)

        #expect(result == .different)
        let events = collector.events
        #expect(events.count == 2)
        #expect(collector.failures.first?.disposition == .transient)
        #expect(collector.failures.first?.annotation?.callNumberWithinOperation == 1)
        #expect(collector.turns.first?.annotation?.callNumberWithinOperation == 2)
    }

    @Test("a permanent failure records one failure and no turn")
    func permanentFailureIsRecordedOnce() async {
        let provider = ScriptedProvider([.fail(.httpError(statusCode: 401, body: "bad key"))])
        let (summarizer, collector) = await makeSummarizer(provider)
        let answer = await summarizer.extractWebContent(content: "page", prompt: "q", taskID: nil, taskTitle: nil)

        #expect(answer == nil)
        #expect(collector.turns.isEmpty)
        #expect(collector.failures.count == 1)
        #expect(collector.failures.first?.disposition == .permanent)
    }
}
