import Testing
import Foundation
import SwiftLLMKit
@testable import AgentSmithKit

/// Regression for the empty-response feedback loop.
///
/// When a non-Brown agent returns an empty completion, the app appends a synthetic
/// `AgentActor.emptyResponseTurnMarker` ("(no response)") to `conversationHistory` as a turn
/// boundary. Because that marker lives in the model's own context, the model can PARROT it back as
/// literal text on a later turn — which the normal text paths (raw-text post, Smith's implicit
/// message_user) would then post to the channel, spamming the transcript with "(no response)".
///
/// The fix: canonical, whitespace-padded, and observed one-character-short marker echoes are treated
/// as empty responses — never posted, never recorded as real text — while the synthetic marker still
/// closes the turn in history (which is fine to show there).
@Suite("AgentActor empty-response marker")
struct AgentActorEmptyResponseTests {

    private static let sharedEngine = SemanticSearchEngine()

    @Test(
        "Legitimate text containing the marker words remains visible",
        arguments: [
            "no response",
            "(no response) from the server",
            "There was (no response) during the probe."
        ]
    )
    func legitimateTextIsNotAnEmptyMarkerEcho(responseText: String) {
        #expect(!AgentActor.isEmptyResponseTurnMarkerEcho(responseText))
    }

    @Test(
        "A parroted marker is treated as empty and never posted to the channel",
        arguments: [
            AgentActor.emptyResponseTurnMarker,
            "(no response",
            " \n(no response)\t"
        ]
    )
    func markerEchoNotPostedToChannel(responseText: String) async throws {
        let channel = MessageChannel()
        let taskStore = TaskStore()
        let memoryStore = MemoryStore(engine: Self.sharedEngine)

        let llmConfig = ModelConfiguration(
            name: "test", providerID: "test", modelID: "test-model",
            maxOutputTokens: 1024, maxContextTokens: 100_000
        )
        let config = AgentConfiguration(role: .smith, llmConfig: llmConfig, systemPrompt: "test-system")

        // The model parrots the synthetic marker, or its observed malformed variant, as text.
        let provider = MockLLMProvider(responses: [
            LLMResponse(text: responseText)
        ])

        let agentID = UUID()
        let context = ToolContext(
            agentID: agentID,
            agentRole: .smith,
            channel: channel,
            taskStore: taskStore,
            spawnBrown: { nil },
            terminateAgent: { _, _ in false },
            abort: { _, _ in },
            agentRoleForID: { _ in .smith },
            memoryStore: memoryStore,
            setToolExecutionStatus: { _, _ in },
            hasToolSucceeded: { _ in false },
            hasToolFailed: { _ in false }
        )
        let agent = AgentActor(id: agentID, configuration: config, provider: provider, tools: [], toolContext: context)

        await agent.appendUserMessage("say something")
        await agent.start()

        // Poll until the turn is closed (synthetic marker appears in history), then stop. Smith
        // goes idle after an empty response rather than self-terminating, so we can't poll `running`.
        let deadline = Date().addingTimeInterval(3.0)
        var closed = false
        while Date() < deadline {
            let ctx = await agent.contextSnapshot()
            if ctx.contains(where: { $0.role == .assistant && $0.content.textValue == AgentActor.emptyResponseTurnMarker }) {
                closed = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        await agent.stop()

        #expect(closed, "Smith should have processed the parroted-marker turn and closed it with the synthetic marker")

        let posted = await channel.allMessages()
        #expect(posted.isEmpty, "the parroted marker must never reach the channel transcript")
    }
}
