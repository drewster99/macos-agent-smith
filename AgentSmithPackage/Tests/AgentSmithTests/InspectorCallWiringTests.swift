import Foundation
import Testing
import SemanticSearch
@testable import AgentSmithKit

/// End-to-end wiring: a worker's tool call reviewed by its Security evaluator must reach the
/// runtime's `onLLMCallRecorded` observer as a Security Agent call — the path the inspector's
/// Security LLM Turns section reads.
@Suite("Inspector call wiring")
struct InspectorCallWiringTests {

    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [(AgentInstanceRef, LLMCallEvent)] = []
        func record(_ ref: AgentInstanceRef, _ event: LLMCallEvent) { lock.withLock { events.append((ref, event)) } }
        func roles() -> [AgentRole] { lock.withLock { events.map(\.0.role) } }
    }

    private final class SessionLog: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [UUID?] = []
        func record(_ id: UUID?) { lock.withLock { recorded.append(id) } }
        var values: [UUID?] { lock.withLock { recorded } }
    }

    private func waitUntil(timeout: Duration = .seconds(20), _ predicate: @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return await predicate()
    }

    @Test("a worker tool call's Security review reaches the call observer")
    func securityReviewReachesObserver() async throws {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-smith-inspector-wiring", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        let brownCall = LLMResponse(toolCalls: [
            LLMToolCall(id: "c1", name: "file_read", arguments: #"{"path":"/nonexistent/agent-smith-wiring"}"#)
        ])
        let config = ModelConfiguration(name: "test", providerID: "test", modelID: "test-model")
        let runtime = OrchestrationRuntime(
            providers: [
                .smith: MockLLMProvider(responses: [LLMResponse(text: "Standing by.")]),
                .securityAgent: MockLLMProvider(responses: [LLMResponse(text: "SAFE reading a file")]),
                .brown: MockLLMProvider(responses: [brownCall]),
            ],
            configurations: [.smith: config, .securityAgent: config, .brown: config],
            providerAPITypes: [:],
            agentTuning: [
                .brown: AgentTuningConfig(pollInterval: 3600),
                .smith: AgentTuningConfig(pollInterval: 3600),
                .securityAgent: AgentTuningConfig(pollInterval: 3600),
            ],
            semanticSearchEngine: SemanticSearchEngine(),
            usageStore: UsageStore(persistence: PersistenceManager(testingRoot: tmpRoot)),
            autoAdvanceEnabled: false,
            autoRunInterruptedTasks: false,
            memoryStore: nil
        )
        await runtime.setOrchestrationSettings(OrchestrationSettings.builtIn.applying(
            OrchestrationSettingsOverride(scopeToolSetOnTaskStart: false)))
        let log = EventLog()
        let sessions = SessionLog()
        await runtime.setOnLLMCallRecorded { ref, event in log.record(ref, event) }
        await runtime.setOnRunSessionChanged { sessions.record($0) }
        await runtime.start()
        let startedSession = await runtime.currentSessionID
        #expect(startedSession != nil)
        #expect(sessions.values.last == startedSession, "the run's session id must be pushed to observers")

        let task = await runtime.taskStore.addTask(title: "Read", description: "read a file")
        await runtime.restartForNewTask(taskID: task.id, origin: .explicitUser)
        await runtime.waitForPendingRestarts()

        let reviewed = await waitUntil { log.roles().contains(.securityAgent) }
        #expect(reviewed, "no Security Agent call reached the observer; roles seen: \(log.roles())")
        await runtime.stopAll()
    }

    @Test("Smith context compaction is recorded as a typed Summarizer call")
    func compactionIsRecordedUnderTheSummarizer() async throws {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-smith-inspector-wiring", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        let config = ModelConfiguration(name: "test", providerID: "test", modelID: "test-model")
        let summarizerProvider = MockLLMProvider(responses: [LLMResponse(text: "THE SUMMARY")])
        let runtime = OrchestrationRuntime(
            providers: [
                .smith: MockLLMProvider(responses: [LLMResponse(text: "Standing by.")]),
                .securityAgent: MockLLMProvider(responses: [LLMResponse(text: "SAFE")]),
                .summarizer: summarizerProvider,
            ],
            configurations: [.smith: config, .securityAgent: config, .summarizer: config],
            providerAPITypes: [:],
            agentTuning: [:],
            semanticSearchEngine: SemanticSearchEngine(),
            usageStore: UsageStore(persistence: PersistenceManager(testingRoot: tmpRoot)),
            autoAdvanceEnabled: false,
            autoRunInterruptedTasks: false,
            memoryStore: nil
        )
        let calls = EventCalls()
        await runtime.setOnLLMCallRecorded { ref, event in calls.record(ref, event) }
        await runtime.start()
        let smith = try #require(await runtime.supervisor.firstHandle(role: .smith)?.agent)
        for index in 1...8 {
            await smith.appendUserMessage("message \(index)")
        }
        // compactSmithContext declines at `compactionRecentTurnsKept + 3` (= 9) messages or fewer.
        let grown = await waitUntil { (await runtime.contextSnapshot(for: .smith)?.count ?? 0) > 9 }
        #expect(grown, "Smith's context must grow past the compaction minimum for this test to mean anything")

        _ = await runtime.compactSmithContext()

        let compaction = calls.completed.first { $0.turn.annotation?.operation == .contextCompaction }
        #expect(compaction != nil, "the compaction call must reach the call observer")
        #expect(compaction?.ref.role == .summarizer)
        #expect(compaction?.turn.isSelfContainedRequest == true)
        #expect(compaction?.turn.contextSnapshot == summarizerProvider.receivedMessages.first)
        await runtime.stopAll()
    }

    private final class EventCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var turns: [(ref: AgentInstanceRef, turn: LLMTurnRecord)] = []
        func record(_ ref: AgentInstanceRef, _ event: LLMCallEvent) {
            guard case .completed(let turn) = event else { return }
            lock.withLock { turns.append((ref, turn)) }
        }
        var completed: [(ref: AgentInstanceRef, turn: LLMTurnRecord)] { lock.withLock { turns } }
    }
}
