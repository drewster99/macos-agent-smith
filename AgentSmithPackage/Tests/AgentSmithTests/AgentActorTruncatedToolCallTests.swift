import Foundation
import SwiftLLMKit
import Testing
@testable import AgentSmithKit

@Suite("AgentActor truncated Qwen tool-call recovery")
struct AgentActorTruncatedToolCallTests {
    private static let sharedEngine = SemanticSearchEngine()

    @Test("Detection requires an output-limit finish and an unfinished text wrapper")
    func detectionIsNarrow() {
        let unfinished = LLMResponse(
            text: #"<tool_call>{"name":"file_write","arguments":{"content":"partial"}"#,
            finishReason: "length"
        )
        let complete = LLMResponse(
            text: #"<tool_call>{"name":"file_write"}</tool_call>"#,
            finishReason: "length"
        )
        let normalStop = LLMResponse(text: "<tool_call>{", finishReason: "stop")
        let structured = LLMResponse(
            text: "<tool_call>{",
            toolCalls: [LLMToolCall(id: "call-1", name: "file_write", arguments: "{}")],
            finishReason: "length"
        )

        #expect(AgentActor.isTruncatedQwenToolCall(unfinished))
        #expect(!AgentActor.isTruncatedQwenToolCall(complete))
        #expect(!AgentActor.isTruncatedQwenToolCall(normalStop))
        #expect(!AgentActor.isTruncatedQwenToolCall(structured))
    }

    @Test("Brown hides a truncated wrapper and receives a smaller-call retry instruction")
    func brownRetriesTruncatedWrapperInternally() async throws {
        let channel = MessageChannel()
        let taskStore = TaskStore()
        let memoryStore = MemoryStore(engine: Self.sharedEngine)
        let provider = MockLLMProvider(responses: [
            LLMResponse(
                text: #"<tool_call>{"name":"file_write","arguments":{"content":"partial"}"#,
                finishReason: "length"
            ),
            LLMResponse(text: "", finishReason: "stop")
        ])

        let agentID = UUID()
        let context = ToolContext(
            agentID: agentID,
            agentRole: .brown,
            channel: channel,
            taskStore: taskStore,
            spawnBrown: { nil },
            terminateAgent: { _, _ in false },
            abort: { _, _ in },
            agentRoleForID: { _ in .brown },
            memoryStore: memoryStore,
            setToolExecutionStatus: { _, _ in },
            hasToolSucceeded: { _ in false },
            hasToolFailed: { _ in false }
        )
        let config = AgentConfiguration(
            role: .brown,
            llmConfig: ModelConfiguration(
                name: "test", providerID: "test", modelID: "test-model",
                maxOutputTokens: 1024, maxContextTokens: 100_000
            ),
            systemPrompt: "test"
        )
        let agent = AgentActor(
            id: agentID,
            configuration: config,
            provider: provider,
            tools: [],
            toolContext: context
        )

        let task = await taskStore.addTask(
            title: "truncated tool-call test",
            description: "verify internal retry recovery"
        )
        await taskStore.updateStatus(id: task.id, status: .running)
        await taskStore.assignAgent(taskID: task.id, agentID: agentID)
        await agent.start(initialInstruction: "write the file")

        let deadline = Date().addingTimeInterval(3)
        while provider.callCount < 2, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        await agent.stop()

        #expect(provider.callCount >= 2, "Brown should retry immediately after the truncated call")

        let posted = await channel.allMessages()
        #expect(!posted.contains { $0.content.contains("<tool_call") })
        #expect(posted.contains {
            $0.sender == .system
                && $0.content.contains("truncated by the output-token limit")
                && $0.content.contains("smaller, chunked retry")
        })

        let retryMessages = provider.receivedMessages.dropFirst().first ?? []
        #expect(retryMessages.contains {
            $0.role == .user
                && ($0.content.textValue?.contains("was not executed") ?? false)
                && ($0.content.textValue?.contains("Split large file_write/file_edit content") ?? false)
        })
        #expect(!retryMessages.contains {
            $0.role == .assistant && ($0.content.textValue?.contains("<tool_call") ?? false)
        })
    }
}
