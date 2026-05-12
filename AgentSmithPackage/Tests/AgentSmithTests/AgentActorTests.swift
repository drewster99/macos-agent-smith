import Testing
import Foundation
@testable import AgentSmithKit

@Suite("Tool Tests")
struct AgentActorTests {
    /// One engine for the whole suite. None of the tool tests embed or search, so we
    /// don't need a prepared model — we just need a non-nil engine to construct
    /// `MemoryStore`. Sharing avoids paying the engine init cost N times.
    private static let sharedEngine = SemanticSearchEngine()

    private func makeContext(
        channel: MessageChannel = MessageChannel(),
        taskStore: TaskStore = TaskStore(),
        role: AgentRole = .brown
    ) throws -> ToolContext {
        ToolContext(
            agentID: UUID(),
            agentRole: role,
            channel: channel,
            taskStore: taskStore,
            spawnBrown: { nil },
            terminateAgent: { _, _ in false },
            abort: { _, _ in },
            agentRoleForID: { _ in nil },
            memoryStore: MemoryStore(engine: Self.sharedEngine),
            setToolExecutionStatus: { _, _ in },
            hasToolSucceeded: { _ in false },
            hasToolFailed: { _ in false }
        )
    }

    // MARK: - BashTool

    @Test("BashTool allows safe commands")
    func shellAllowsSafeCommands() async throws {
        let tool = BashTool()
        let result = try await tool.execute(
            arguments: ["command": .string("echo hello")],
            context: makeContext()
        )
        #expect(result.output.contains("hello"))
        #expect(result.succeeded)
    }

    @Test("BashTool allows ls")
    func shellAllowsLs() async throws {
        let tool = BashTool()
        let result = try await tool.execute(
            arguments: ["command": .string("ls /tmp")],
            context: makeContext()
        )
        #expect(result.output.contains("BLOCKED") == false)
        #expect(result.succeeded)
    }

    // MARK: - CreateTaskTool

    @Test("CreateTaskTool adds task to store")
    func createTaskAddsToStore() async throws {
        let taskStore = TaskStore()
        let context = try makeContext(taskStore: taskStore, role: .smith)
        let tool = CreateTaskTool()

        let result = try await tool.execute(
            arguments: [
                "title": .string("Test task"),
                "description": .string("A test")
            ],
            context: context
        )

        #expect(result.output.contains("Task created"))
        let tasks = await taskStore.allTasks()
        #expect(tasks.count == 1)
        #expect(tasks[0].title == "Test task")
    }

    // MARK: - MessageUserTool

    @Test("MessageUserTool posts to channel")
    func messageUserPostsToChannel() async throws {
        let channel = MessageChannel()
        let context = try makeContext(channel: channel, role: .smith)
        let tool = MessageUserTool()

        _ = try await tool.execute(
            arguments: ["message": .string("Hello world")],
            context: context
        )

        let messages = await channel.allMessages()
        #expect(messages.count == 1)
        #expect(messages[0].content == "Hello world")
    }

    // MARK: - ListTasksTool

    @Test("ListTasksTool returns all tasks")
    func listTasksReturnsAll() async throws {
        let taskStore = TaskStore()
        await taskStore.addTask(title: "Task A", description: "First")
        await taskStore.addTask(title: "Task B", description: "Second")

        let tool = ListTasksTool()
        let result = try await tool.execute(
            arguments: [:],
            context: makeContext(taskStore: taskStore)
        )

        #expect(result.output.contains("Showing tasks 1–2 of 2"))
        #expect(result.output.contains("Task A"))
        #expect(result.output.contains("Task B"))
        #expect(result.succeeded)
    }

    @Test("ListTasksTool filters by status")
    func listTasksFiltersByStatus() async throws {
        let taskStore = TaskStore()
        let task = await taskStore.addTask(title: "Done task", description: "Completed")
        await taskStore.updateStatus(id: task.id, status: .completed)
        await taskStore.addTask(title: "Pending task", description: "Waiting")

        let tool = ListTasksTool()
        let result = try await tool.execute(
            arguments: ["status_filter": .string("completed")],
            context: makeContext(taskStore: taskStore)
        )

        #expect(result.output.contains("Showing tasks 1–1 of 1"))
        #expect(result.output.contains("Done task"))
        #expect(!result.output.contains("Pending task"))
        #expect(result.succeeded)
    }

    @Test("ListTasksTool returns empty message when no tasks")
    func listTasksEmpty() async throws {
        let tool = ListTasksTool()
        let result = try await tool.execute(
            arguments: [:],
            context: makeContext()
        )
        #expect(result.output == "No tasks found matching the given filters.")
        // Empty result is a successful query — the search worked, nothing matched.
        #expect(result.succeeded)
    }

    // MARK: - ChannelMessage Codable

    @Test("ChannelMessage round-trips with attachments")
    func channelMessageRoundTrip() throws {
        let original = ChannelMessage(
            sender: .user,
            content: "With file",
            attachments: [
                Attachment(filename: "test.txt", mimeType: "text/plain", byteCount: 42)
            ]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChannelMessage.self, from: data)
        #expect(decoded.content == "With file")
        #expect(decoded.attachments.count == 1)
        #expect(decoded.attachments[0].filename == "test.txt")
    }

    // MARK: - MemoryEntry round-trip

    @Test("MemoryEntry round-trips [Float] embedding format")
    func memoryEntryRoundTripsCurrentFormat() throws {
        let original = MemoryEntry(
            content: "current format memory",
            embedding: [0.1, 0.2, 0.3],
            source: .user,
            tags: ["roundtrip"]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MemoryEntry.self, from: data)
        #expect(decoded.content == original.content)
        #expect(decoded.embedding == original.embedding)
        #expect(decoded.tags == ["roundtrip"])
    }

    // MARK: - Filename Sanitization

    @Test("PersistenceManager sanitizes path traversal in filenames")
    func sanitizeFilename() {
        #expect(PersistenceManager.sanitizeFilename("../../../etc/passwd") == "passwd")
        #expect(PersistenceManager.sanitizeFilename("normal.txt") == "normal.txt")
        #expect(PersistenceManager.sanitizeFilename("/absolute/path/file.pdf") == "file.pdf")
        #expect(PersistenceManager.sanitizeFilename("") == "unnamed")
    }

    // MARK: - UpdateTaskTool

    @Test("UpdateTaskTool rejects invalid status")
    func updateTaskRejectsInvalidStatus() async throws {
        let taskStore = TaskStore()
        let task = await taskStore.addTask(title: "Test", description: "desc")

        let tool = UpdateTaskTool()
        let result = try await tool.execute(
            arguments: [
                "task_id": .string(task.id.uuidString),
                "status": .string("bogus")
            ],
            context: makeContext(taskStore: taskStore)
        )

        #expect(result.output.contains("Invalid status"))
        #expect(!result.succeeded)
        let stored = await taskStore.task(id: task.id)
        #expect(stored?.status == .pending)
    }

    // MARK: - MockLLMProvider

    @Test("MockLLMProvider returns canned responses in order")
    func mockProviderReturnsCannedResponses() async throws {
        let provider = MockLLMProvider(responses: [
            LLMResponse(text: "Response 1"),
            LLMResponse(text: "Response 2")
        ])

        let r1 = try await provider.send(messages: [], tools: [])
        let r2 = try await provider.send(messages: [], tools: [])

        #expect(r1.text == "Response 1")
        #expect(r2.text == "Response 2")
        #expect(provider.callCount == 2)
    }
}
