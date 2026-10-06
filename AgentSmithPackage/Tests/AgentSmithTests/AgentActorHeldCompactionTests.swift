import Testing
import Foundation
import SwiftLLMKit
@testable import AgentSmithKit

/// A compaction summary that arrives while Smith is mid-tool-turn is HELD for the next loop top
/// rather than spliced into a turn in progress (2026-10-06). These pin what happens to held
/// summaries: two for one boundary keep the one covering more, and a `/clear` waiting at the same
/// boundary wins over any of them.
@Suite("AgentActor held compactions")
struct AgentActorHeldCompactionTests {

    private static let sharedEngine = SemanticSearchEngine()

    @Test("held summaries: the one covering more is kept, and a /clear at the same boundary wins")
    func heldSummariesSupersedeThenYieldToClear() async throws {
        let gate = ToolGate()
        let channel = MessageChannel()
        let agent = await makeSmith(gate: gate, channel: channel)
        for index in 1...12 { await agent.appendUserMessage("message \(index)") }
        await agent.start()

        let parked = await waitUntil { await gate.isWaiting }
        try #require(parked, "Smith never reached the tool call")
        let snapshot = await agent.contextSnapshot()
        let outcomes = OutcomeRecorder()

        // Held while the tool runs.
        let held = await agent.compactConversationHistory(
            summaryText: "FULL", summarizing: snapshot, keepingRecentTurns: 3,
            onDeferredApplication: { outcome, _ in await outcomes.record("FULL", outcome) }
        )
        #expect(held == .deferredToTurnEnd)
        #expect(await agent.hasPendingCompaction)

        // A summary of LESS of the history loses to the held one, and is told so at once.
        let narrower = await agent.compactConversationHistory(
            summaryText: "NARROW", summarizing: Array(snapshot.dropLast(2)), keepingRecentTurns: 3,
            onDeferredApplication: { outcome, _ in await outcomes.record("NARROW", outcome) }
        )
        #expect(narrower == .superseded)

        // One covering as much replaces it; the replaced one is told it was superseded.
        let replacing = await agent.compactConversationHistory(
            summaryText: "REPLACING", summarizing: snapshot, keepingRecentTurns: 3,
            onDeferredApplication: { outcome, _ in await outcomes.record("REPLACING", outcome) }
        )
        #expect(replacing == .deferredToTurnEnd)
        let fullSuperseded = await waitUntil { await outcomes.outcome(of: "FULL") == .superseded }
        #expect(fullSuperseded)

        // A /clear arriving mid-turn waits for the same boundary, and wins there.
        await agent.resetConversationHistory(orientation: "fresh start")
        await gate.open()

        let replacingDiscarded = await waitUntil { await outcomes.outcome(of: "REPLACING") == .historyChanged }
        #expect(replacingDiscarded, "a summary spliced in ahead of a /clear would be reported applied, then erased")
        let history = await agent.contextSnapshot()
        #expect(!history.contains { $0.content.textValue?.contains("REPLACING") == true })
        #expect(history.contains { $0.content.textValue == "fresh start" })
        #expect(await outcomes.outcome(of: "NARROW") == nil, "an immediately-superseded summary is not reported again")
        await agent.stop()
    }

    @Test("a held summary is applied at the loop top once the turn ends")
    func heldSummaryAppliedAfterTurn() async throws {
        let gate = ToolGate()
        let agent = await makeSmith(gate: gate, channel: MessageChannel())
        for index in 1...12 { await agent.appendUserMessage("message \(index)") }
        await agent.start()

        let parked = await waitUntil { await gate.isWaiting }
        try #require(parked, "Smith never reached the tool call")
        let snapshot = await agent.contextSnapshot()
        let outcomes = OutcomeRecorder()
        let held = await agent.compactConversationHistory(
            summaryText: "THE SUMMARY", summarizing: snapshot, keepingRecentTurns: 3,
            onDeferredApplication: { outcome, _ in await outcomes.record("SUMMARY", outcome) }
        )
        #expect(held == .deferredToTurnEnd)
        await gate.open()

        let applied = await waitUntil {
            if case .compacted? = await outcomes.outcome(of: "SUMMARY") { return true }
            return false
        }
        #expect(applied)
        let history = await agent.contextSnapshot()
        #expect(history.contains { $0.content.textValue?.contains("THE SUMMARY") == true })
        #expect(!(await agent.hasPendingCompaction))
        // The tool call and its result survived as a pair (the result arrived after the snapshot).
        #expect(Self.orphanedToolResultCount(in: history) == 0)
        await agent.stop()
    }

    // MARK: - Helpers

    /// Blocks the tool call until opened, so the test can act while Smith is mid-tool-turn.
    private actor ToolGate {
        private(set) var isWaiting = false
        private var isOpen = false

        func wait() async {
            isWaiting = true
            while !isOpen {
                do {
                    try await Task.sleep(for: .milliseconds(10))
                } catch {
                    return
                }
            }
        }

        func open() { isOpen = true }
    }

    private struct GatedTool: AgentTool {
        let name = "gated_read"
        let toolDescription = "Test stub: returns once the test opens its gate."
        let parameters: [String: AnyCodable] = [
            "type": .string("object"),
            "properties": .dictionary([:]),
            "required": .array([])
        ]
        let gate: ToolGate

        func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
            await gate.wait()
            return .success("read")
        }
    }

    private actor OutcomeRecorder {
        private var outcomes: [String: AgentActor.CompactionOutcome] = [:]
        func record(_ label: String, _ outcome: AgentActor.CompactionOutcome) { outcomes[label] = outcome }
        func outcome(of label: String) -> AgentActor.CompactionOutcome? { outcomes[label] }
    }

    private static func orphanedToolResultCount(in messages: [LLMMessage]) -> Int {
        var callIDs: Set<String> = []
        var orphans = 0
        for message in messages {
            switch message.content {
            case .toolCalls(let calls), .mixed(_, let calls):
                callIDs.formUnion(calls.map(\.id))
            case .toolResult(let callID, _):
                if !callIDs.contains(callID) { orphans += 1 }
            default:
                break
            }
        }
        return orphans
    }

    private func waitUntil(timeout: Duration = .seconds(10), _ predicate: @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await predicate() { return true }
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                break
            }
        }
        return await predicate()
    }

    private func makeSmith(gate: ToolGate, channel: MessageChannel) async -> AgentActor {
        let llmConfig = ModelConfiguration(
            name: "test", providerID: "test", modelID: "test-model",
            maxOutputTokens: 1024, maxContextTokens: 100_000
        )
        let config = AgentConfiguration(role: .smith, llmConfig: llmConfig, systemPrompt: "test-system")
        let agentID = UUID()
        let context = ToolContext(
            agentID: agentID,
            agentRole: .smith,
            channel: channel,
            taskStore: TaskStore(),
            spawnBrown: { _ in nil },
            terminateAgent: { _, _ in false },
            abort: { _, _ in },
            agentRoleForID: { _ in .smith },
            memoryStore: MemoryStore(engine: Self.sharedEngine),
            setToolExecutionStatus: { _, _ in },
            hasToolSucceeded: { _ in false },
            hasToolFailed: { _ in false }
        )
        // One tool turn (held open by the gate), then text replies while Smith idles.
        let provider = MockLLMProvider(responses: [
            LLMResponse(toolCalls: [LLMToolCall(id: "call-1", name: "gated_read", arguments: "{}")]),
            LLMResponse(text: "Done.")
        ])
        let agent = AgentActor(
            id: agentID, configuration: config, provider: provider,
            tools: [GatedTool(gate: gate)], toolContext: context
        )
        // Every tool call goes through the Security Agent; approve them so the gated tool runs.
        await agent.setSecurityEvaluator(SecurityEvaluator(
            provider: MockLLMProvider(responses: Array(repeating: LLMResponse(text: "SAFE: fine for test"), count: 20)),
            systemPrompt: "security gatekeeper",
            channel: MessageChannel(),
            abort: { _, _ in },
            hasToolSucceeded: { _ in false },
            hasToolFailed: { _ in false }
        ))
        return agent
    }
}
