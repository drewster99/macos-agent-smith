import Testing
import Foundation
@testable import AgentSmithKit

/// The Security Agent's inspector turns must carry the EXACT request each provider call received —
/// captured before the call, never reconstructed from the evaluator's working conversation, which
/// keeps growing after the call returns — and a call that throws must surface as a failed-attempt
/// record rather than a fabricated response.
@Suite("SecurityEvaluator inspector call capture")
struct SecurityEvaluatorTurnCaptureTests {

    private func makeEvaluator(_ provider: ScriptedProvider) async -> (SecurityEvaluator, EventCollector) {
        let evaluator = SecurityEvaluator(
            provider: provider,
            systemPrompt: "security system prompt",
            channel: MessageChannel(),
            abort: { _, _ in },
            hasToolSucceeded: { _ in false },
            hasToolFailed: { _ in false }
        )
        let collector = EventCollector()
        await evaluator.setOnLLMCallRecorded { collector.record($0) }
        return (evaluator, collector)
    }

    private func review(_ evaluator: SecurityEvaluator, taskID: UUID = UUID()) async -> SecurityDisposition {
        await evaluator.evaluate(
            toolName: "bash",
            toolParams: "{\"command\":\"ls\"}",
            toolDescription: "Run a shell command",
            toolParameterDefs: "",
            taskTitle: "Capture task",
            taskID: taskID.uuidString,
            taskDescription: "desc",
            siblingCalls: nil,
            agentRoleName: "Brown",
            callerRole: .brown,
            toolGroupDescription: nil,
            toolCallID: "call-1",
            evaluatingForAgentID: UUID()
        )
    }

    private func fileReadCall(_ index: Int) -> LLMResponse {
        LLMResponse(toolCalls: [LLMToolCall(id: "read-\(index)", name: "file_read",
                                            arguments: #"{"path":"/nonexistent/agent-smith-test"}"#)])
    }

    @Test("first call: the turn carries the exact request, as outgoing input and full snapshot")
    func firstCallCapturesExactRequest() async {
        let provider = ScriptedProvider([.respond(LLMResponse(text: "SAFE listing a directory"))])
        let (evaluator, collector) = await makeEvaluator(provider)
        let taskID = UUID()
        _ = await review(evaluator, taskID: taskID)

        let turns = collector.turns
        #expect(turns.count == 1)
        #expect(turns.first?.inputDelta == provider.receivedRequests.first)
        #expect(turns.first?.contextSnapshot == provider.receivedRequests.first)
        #expect(turns.first?.inputDelta.first?.role == .system)
        #expect(turns.first?.annotation?.operation == .securityToolReview(toolName: "bash"))
        #expect(turns.first?.annotation?.taskID == taskID)
        #expect(turns.first?.annotation?.taskTitle == "Capture task")
        #expect(turns.first?.annotation?.callNumberWithinOperation == 1)
    }

    @Test("a malformed but returned response is a normal turn, and the parse retry is its own turn")
    func parseRetryIsItsOwnTurn() async {
        let provider = ScriptedProvider([
            .respond(LLMResponse(text: "I am not sure what to say")),
            .respond(LLMResponse(text: "SAFE ok")),
        ])
        let (evaluator, collector) = await makeEvaluator(provider)
        let disposition = await review(evaluator)

        #expect(disposition.approved)
        let turns = collector.turns
        #expect(turns.count == 2)
        #expect(turns.first?.response.text == "I am not sure what to say")
        #expect(turns.map(\.inputDelta) == provider.receivedRequests)
        #expect(turns.map { $0.annotation?.callNumberWithinOperation } == [1, 2])
        #expect(collector.failures.isEmpty)
    }

    @Test("an evidence round's turn holds the request as sent, not the conversation after it")
    func evidenceRoundCapturesRequestAsSent() async {
        let provider = ScriptedProvider([
            .respond(fileReadCall(1)),
            .respond(LLMResponse(text: "SAFE fine")),
        ])
        let (evaluator, collector) = await makeEvaluator(provider)
        _ = await review(evaluator)

        let turns = collector.turns
        let requests = provider.receivedRequests
        #expect(turns.count == 2)
        #expect(turns.map(\.inputDelta) == requests)
        // The first request precedes the tool round; the second includes the assistant tool call
        // and its tool result.
        #expect(requests.count == 2)
        #expect(requests[0].count == 2)
        #expect(requests[1].count == 4)
        #expect(requests[1][2].role == .assistant)
        #expect(turns[0].inputDelta.count == 2, "the first turn must not absorb the later tool round")
    }

    @Test("the forced-verdict instruction appears in the request that carried it")
    func forcedVerdictRequestIsCaptured() async {
        var steps: [ScriptedProvider.Step] = (1...16).map { .respond(fileReadCall($0)) }
        steps.append(.respond(LLMResponse(text: "SAFE done")))
        let provider = ScriptedProvider(steps)
        let (evaluator, collector) = await makeEvaluator(provider)
        _ = await review(evaluator)

        let turns = collector.turns
        #expect(turns.count == 17)
        let lastRequestText = turns.last?.inputDelta.last?.content.textValue ?? ""
        #expect(lastRequestText.contains("reached the evidence-gathering limit"))
        #expect(turns.map(\.inputDelta) == provider.receivedRequests)
    }

    @Test("a thrown provider call is a failure record, never a turn")
    func transportFailureIsAFailureRecord() async {
        let provider = ScriptedProvider([.fail(.httpError(statusCode: 401, body: "bad key"))])
        let (evaluator, collector) = await makeEvaluator(provider)
        _ = await review(evaluator)

        #expect(collector.turns.isEmpty)
        let failures = collector.failures
        #expect(failures.count == 1)
        #expect(failures.first?.disposition == .permanent)
        #expect(failures.first?.annotation?.operation == .securityToolReview(toolName: "bash"))
    }

    @Test("tool scoping records the exact request it sent")
    func scopingCapturesExactRequest() async {
        let provider = ScriptedProvider([
            .respond(LLMResponse(text: #"{"toolResponses":[{"toolID":"get_current_time","isAllowed":true}]}"#))
        ])
        let (evaluator, collector) = await makeEvaluator(provider)
        let taskID = UUID()
        let result = await evaluator.scopeTools(
            candidateTools: [CurrentTimeTool()],
            taskTitle: "Scope task",
            taskID: taskID.uuidString,
            taskDescription: "Check the time"
        )

        #expect(result.succeeded)
        let turns = collector.turns
        #expect(turns.count == 1)
        #expect(turns.first?.inputDelta == provider.receivedRequests.first)
        #expect(turns.first?.annotation?.operation == .securityToolScoping)
        #expect(turns.first?.annotation?.taskID == taskID)
    }

    @Test("the recorded request keeps text but drops binary attachment bytes")
    func recordedRequestDropsBinaryAttachments() {
        let image = LLMImageContent(data: Data([0x89, 0x50]), mimeType: "image/png")
        let request: [LLMMessage] = [.system("s"), .user("look [attachment: a.png]", images: [image])]
        let recorded = SecurityEvaluator.withoutBinaryAttachments(request)
        #expect(recorded[1].content.textValue == "look [attachment: a.png]")
        #expect(recorded[1].images == nil)
        #expect(recorded[0] == request[0])
    }
}
