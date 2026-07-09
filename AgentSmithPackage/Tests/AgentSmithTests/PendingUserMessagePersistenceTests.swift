import Testing
import Foundation
@testable import AgentSmithKit

/// Tests the pending-user-message buffer that keeps a message typed while Smith is
/// stopped / mid-startup from being silently dropped (the "message ignored during
/// 'Preparing task — starting MCP servers…'" bug).
///
/// Pins the invariants that don't require driving a live agent run loop:
///   1. `PendingUserMessage` strips attachment bytes (they live on disk) yet keeps identity.
///   2. It round-trips through the per-session JSON store; a missing file loads as empty.
///   3. `AgentActor.acceptChannelMessage` refuses a message while the agent is not running —
///      so the drain's "remove only after acceptance" can never lose a message to a Smith
///      that stopped between post and delivery.
@Suite("Pending user-message buffer", .serialized)
struct PendingUserMessagePersistenceTests {

    @Test("PendingUserMessage strips attachment bytes but preserves identity fields")
    func stripsBytes() {
        let withData = Attachment(filename: "a.png", mimeType: "image/png", byteCount: 3, data: Data([1, 2, 3]))
        let msg = PendingUserMessage(text: "hi", attachments: [withData], receivedAt: Date(timeIntervalSince1970: 1000))
        #expect(msg.attachments.count == 1)
        #expect(msg.attachments[0].data == nil)
        #expect(msg.attachments[0].id == withData.id)
        #expect(msg.attachments[0].filename == "a.png")
        #expect(msg.attachments[0].byteCount == 3)
    }

    @Test("PendingUserMessage round-trips through JSON")
    func roundTripsThroughJSON() throws {
        let original = PendingUserMessage(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
            channelMessageID: UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!,
            text: "do a thing",
            attachments: [Attachment(filename: "x.txt", mimeType: "text/plain", byteCount: 5)],
            receivedAt: Date(timeIntervalSince1970: 800_000_000)
        )
        let decoded = try JSONDecoder().decode(PendingUserMessage.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        #expect(decoded.attachments[0].data == nil)
    }

    @Test("PersistenceManager saves and loads the pending buffer; missing file is empty")
    func persistenceRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pum-tests-\(UUID().uuidString)")
        let manager = PersistenceManager(testingRoot: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let empty = try await manager.loadPendingUserMessages()
        #expect(empty.isEmpty)

        let messages = [
            PendingUserMessage(text: "first", attachments: [], receivedAt: Date(timeIntervalSince1970: 1)),
            PendingUserMessage(text: "second", attachments: [], receivedAt: Date(timeIntervalSince1970: 2))
        ]
        try await manager.savePendingUserMessages(messages)
        let loaded = try await manager.loadPendingUserMessages()
        #expect(loaded == messages)
        #expect(loaded.map(\.text) == ["first", "second"])

        try await manager.savePendingUserMessages([])
        let cleared = try await manager.loadPendingUserMessages()
        #expect(cleared.isEmpty)
    }

    @Test("acceptChannelMessage refuses delivery while the agent is not running")
    func acceptRefusedWhenNotRunning() async {
        let actor = makeActor()
        // A never-started actor is not running; the `guard isRunning` refuses delivery before
        // any addressing check, so the runtime's drain keeps the message buffered rather than
        // removing it. (recipient is irrelevant here — the running guard short-circuits first.)
        let delivery = ChannelMessage(
            sender: .user,
            recipientID: UUID(),
            recipient: .agent(.smith),
            content: "please run"
        )
        let accepted = await actor.acceptChannelMessage(delivery)
        #expect(accepted == false)
    }

    private func makeActor() -> AgentActor {
        let provider = MockLLMProvider(responses: [])
        let channel = MessageChannel()
        let taskStore = TaskStore()
        let memoryStore = MemoryStore(engine: SemanticSearchEngine())
        let config = AgentConfiguration(
            role: .smith,
            llmConfig: ModelConfiguration(name: "test", providerID: "test", modelID: "test-model"),
            systemPrompt: "test prompt"
        )
        let context = ToolContext(
            agentID: UUID(),
            agentRole: .smith,
            channel: channel,
            taskStore: taskStore,
            spawnBrown: { nil },
            terminateAgent: { _, _ in false },
            abort: { _, _ in },
            agentRoleForID: { _ in nil },
            memoryStore: memoryStore,
            setToolExecutionStatus: { _, _ in },
            hasToolSucceeded: { _ in false },
            hasToolFailed: { _ in false }
        )
        return AgentActor(
            configuration: config,
            provider: provider,
            tools: [],
            toolContext: context
        )
    }
}
