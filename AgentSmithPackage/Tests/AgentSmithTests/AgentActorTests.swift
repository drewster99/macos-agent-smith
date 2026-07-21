import Testing
import Foundation
@testable import AgentSmithKit

@Suite("Tool Tests")
struct AgentActorTests {
    /// One engine for the whole suite. None of the tool tests embed or search, so we
    /// don't need a prepared model — we just need a non-nil engine to construct
    /// `MemoryStore`. Sharing avoids paying the engine init cost N times.
    private static let sharedEngine = SemanticSearchEngine()

    private actor RestartRecorder {
        private var recordedIDs: [UUID] = []

        func record(_ id: UUID) {
            recordedIDs.append(id)
        }

        func ids() -> [UUID] {
            recordedIDs
        }
    }

    private func makeContext(
        channel: MessageChannel = MessageChannel(),
        taskStore: TaskStore = TaskStore(),
        role: AgentRole = .brown,
        restartForNewTask: @escaping @Sendable (UUID, String?) async -> Void = { _, _ in }
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
            restartForNewTask: restartForNewTask,
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

    @Test("CreateTaskTool creates template input definitions only for templates")
    func createTaskTemplateInputsRequireTemplate() async throws {
        let taskStore = TaskStore()
        let context = try makeContext(taskStore: taskStore, role: .smith)
        let tool = CreateTaskTool()

        let rejected = try await tool.execute(
            arguments: [
                "title": .string("Ordinary"),
                "description": .string("A test"),
                "template_inputs": .array([
                    .dictionary([
                        "name": .string("target_app"),
                        "description": .string("App name"),
                        "required": .bool(true)
                    ])
                ])
            ],
            context: context
        )
        #expect(!rejected.succeeded)
        #expect(rejected.output.contains("is_template is true"))

        let created = try await tool.execute(
            arguments: [
                "title": .string("Template"),
                "description": .string("A reusable task"),
                "is_template": .bool(true),
                "template_inputs": .array([
                    .dictionary([
                        "name": .string("target_app"),
                        "description": .string("App name or bundle ID"),
                        "required": .bool(true)
                    ])
                ])
            ],
            context: context
        )
        #expect(created.succeeded)
        let template = try #require(await taskStore.allTasks().first { $0.title == "Template" })
        #expect(template.isTemplate)
        #expect(template.templateInputDefinitions.map(\.name) == ["target_app"])
        #expect(template.templateInputDefinitions.first?.required == true)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let scheduled = try await tool.execute(
            arguments: [
                "title": .string("Scheduled template"),
                "description": .string("A scheduled reusable task"),
                "scheduled_run_at": .string(formatter.string(from: Date().addingTimeInterval(60))),
                "is_template": .bool(true),
                "template_inputs": .array([
                    .dictionary([
                        "name": .string("target_app"),
                        "description": .string("App name or bundle ID"),
                        "required": .bool(true)
                    ])
                ])
            ],
            context: context
        )
        #expect(!scheduled.succeeded)
        #expect(scheduled.output.contains("scheduled_run_at cannot be used with required template_inputs"))
    }

    @Test("SetTemplateInputsTool replaces definitions on templates only")
    func setTemplateInputsReplacesDefinitions() async throws {
        let taskStore = TaskStore()
        let ordinary = await taskStore.addTask(title: "Ordinary", description: "d")
        let template = await taskStore.addTask(title: "Template", description: "d", isTemplate: true)
        let context = try makeContext(taskStore: taskStore, role: .smith)
        let tool = SetTemplateInputsTool()

        let rejected = try await tool.execute(
            arguments: [
                "task_id": .string(ordinary.id.uuidString),
                "template_inputs": .array([])
            ],
            context: context
        )
        #expect(!rejected.succeeded)
        #expect(rejected.output.contains("not a template"))

        let updated = try await tool.execute(
            arguments: [
                "task_id": .string(template.id.uuidString),
                "template_inputs": .array([
                    .dictionary([
                        "name": .string("target_app"),
                        "description": .string("App name"),
                        "required": .bool(true)
                    ]),
                    .dictionary([
                        "name": .string("locale"),
                        "description": .string("Locale"),
                        "required": .bool(false)
                    ])
                ])
            ],
            context: context
        )
        #expect(updated.succeeded)
        let refreshed = try #require(await taskStore.task(id: template.id))
        #expect(refreshed.templateInputDefinitions.map(\.name) == ["target_app", "locale"])
    }

    @Test("RunTaskTool instantiates templates with input values")
    func runTaskInstantiatesTemplateWithInputValues() async throws {
        let taskStore = TaskStore()
        let channel = MessageChannel()
        let recorder = RestartRecorder()
        let template = await taskStore.addTask(title: "Localization", description: "Base description", isTemplate: true)
        _ = await taskStore.setTemplateInputDefinitions(id: template.id, definitions: [
            TemplateInputDefinition(name: "target_app", description: "App name", required: true),
            TemplateInputDefinition(name: "locale", description: "Locale", required: false)
        ])
        let context = try makeContext(
            channel: channel,
            taskStore: taskStore,
            role: .smith,
            restartForNewTask: { id, _ in await recorder.record(id) }
        )

        let result = try await RunTaskTool().execute(
            arguments: [
                "task_id": .string(template.id.uuidString),
                "instructions": .string("Run the smoke suite only."),
                "input_values": .dictionary([
                    "target_app": .string("  Localizer  "),
                    "locale": .string(" ")
                ])
            ],
            context: context
        )

        #expect(result.succeeded)
        let restartedIDs = await recorder.ids()
        #expect(restartedIDs.count == 1)
        let instanceID = try #require(restartedIDs.first)
        let instance = try #require(await taskStore.task(id: instanceID))
        #expect(instance.parentTaskID == template.id)
        #expect(instance.templateInputValues == ["target_app": "Localizer"])
        #expect(instance.description.contains("Run the smoke suite only."))
        #expect(await taskStore.task(id: template.id)?.description == "Base description")

        let messages = await channel.allMessages()
        let createdMessage = try #require(messages.first { $0.metadata?["clonedFromTemplate"] == .string(template.id.uuidString) })
        guard case .string(let taskDescription)? = createdMessage.metadata?["taskDescription"] else {
            Issue.record("missing taskDescription metadata")
            return
        }
        #expect(taskDescription.contains("## Template inputs"))
        #expect(taskDescription.contains("target_app: Localizer"))
    }

    @Test("RunTaskTool rejects invalid template input values before instantiating")
    func runTaskRejectsInvalidTemplateInputs() async throws {
        let taskStore = TaskStore()
        let recorder = RestartRecorder()
        let ordinary = await taskStore.addTask(title: "Ordinary", description: "d")
        let template = await taskStore.addTask(title: "Localization", description: "Base description", isTemplate: true)
        _ = await taskStore.setTemplateInputDefinitions(id: template.id, definitions: [
            TemplateInputDefinition(name: "target_app", description: "App name", required: true)
        ])
        let context = try makeContext(
            taskStore: taskStore,
            role: .smith,
            restartForNewTask: { id, _ in await recorder.record(id) }
        )

        let nonTemplate = try await RunTaskTool().execute(
            arguments: [
                "task_id": .string(ordinary.id.uuidString),
                "instructions": .string("User confirmed: proceed as described"),
                "input_values": .dictionary(["target_app": .string("Localizer")])
            ],
            context: context
        )
        #expect(!nonTemplate.succeeded)
        #expect(nonTemplate.output.contains("Ordinary non-template tasks cannot accept template inputs"))

        let missing = try await RunTaskTool().execute(
            arguments: [
                "task_id": .string(template.id.uuidString),
                "instructions": .string("User confirmed: proceed as described")
            ],
            context: context
        )
        #expect(!missing.succeeded)
        #expect(missing.output.contains("Missing required template input"))

        let unknown = try await RunTaskTool().execute(
            arguments: [
                "task_id": .string(template.id.uuidString),
                "instructions": .string("User confirmed: proceed as described"),
                "input_values": .dictionary(["target_ap": .string("Typo")])
            ],
            context: context
        )
        #expect(!unknown.succeeded)
        #expect(unknown.output.contains("Unknown template input"))
        #expect((await taskStore.allTasks().filter { $0.parentTaskID == template.id }).isEmpty)
        #expect(await recorder.ids().isEmpty)
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

        #expect(result.succeeded)
        let json = try #require(Self.decodeJSONObject(result.output))
        #expect(json["completeDetails"] as? Bool == false)
        let pagination = try #require(json["pagination"] as? [String: Any])
        #expect(pagination["totalMatching"] as? Int == 2)
        let tasks = try #require(json["tasks"] as? [[String: Any]])
        #expect(tasks.count == 2)
        #expect(tasks.contains { $0["title"] as? String == "Task A" })
        #expect(tasks.contains { $0["title"] as? String == "Task B" })
        #expect(tasks.allSatisfy { $0.keys.contains("truncatedDescriptionPreview") })
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

        #expect(result.succeeded)
        let json = try #require(Self.decodeJSONObject(result.output))
        let tasks = try #require(json["tasks"] as? [[String: Any]])
        #expect(tasks.count == 1)
        #expect(tasks.first?["title"] as? String == "Done task")
        #expect(tasks.first?["status"] as? String == "completed")
    }

    @Test("ListTasksTool returns empty message when no tasks")
    func listTasksEmpty() async throws {
        let tool = ListTasksTool()
        let result = try await tool.execute(
            arguments: [:],
            context: makeContext()
        )
        // Empty result is a successful query — the search worked, nothing matched.
        #expect(result.succeeded)
        let json = try #require(Self.decodeJSONObject(result.output))
        #expect(json["note"] as? String == "No tasks found matching the given filters.")
        let pagination = try #require(json["pagination"] as? [String: Any])
        #expect(pagination["totalMatching"] as? Int == 0)
        let tasks = try #require(json["tasks"] as? [[String: Any]])
        #expect(tasks.isEmpty)
    }

    @Test("ListTasksTool supports template, schedule, query, and date filters")
    func listTasksAdvancedFilters() async throws {
        let taskStore = TaskStore()
        let scheduledRunAt = Date().addingTimeInterval(3_600)
        let template = await taskStore.addTask(
            title: "Daily translation audit",
            description: String(repeating: "Translation ", count: 80),
            scheduledRunAt: scheduledRunAt,
            isTemplate: true
        )
        await taskStore.setAcceptanceCriteria(id: template.id, criteria: [
            AcceptanceCriterion(name: "Audit exists", validationPrompt: "full prompt is hidden from list_tasks", inputEnumeratorPrompt: "full enumerator is hidden from list_tasks", origin: .smith)
        ])
        _ = await taskStore.setTemplateInputDefinitions(id: template.id, definitions: [
            TemplateInputDefinition(name: "target_app", description: "App name", required: true)
        ])
        await taskStore.addTask(title: "Unrelated", description: "nothing to see")

        let tool = ListTasksTool()
        let result = try await tool.execute(
            arguments: [
                "status_filter": .string("scheduled"),
                "is_template": .bool(true),
                "is_scheduled": .bool(true),
                "query": .string("translation"),
                "created_before": .string(ISO8601DateFormatter().string(from: Date().addingTimeInterval(60))),
                "scheduled_after": .string(ISO8601DateFormatter().string(from: Date())),
                "scheduled_before": .string(ISO8601DateFormatter().string(from: Date().addingTimeInterval(7_200)))
            ],
            context: makeContext(taskStore: taskStore)
        )

        #expect(result.succeeded)
        let json = try #require(Self.decodeJSONObject(result.output))
        let filters = try #require(json["filters"] as? [String: Any])
        #expect(filters["is_template"] as? Bool == true)
        #expect(filters["is_scheduled"] as? Bool == true)
        let tasks = try #require(json["tasks"] as? [[String: Any]])
        #expect(tasks.count == 1)
        let task = try #require(tasks.first)
        #expect(task["id"] as? String == template.id.uuidString)
        #expect(task["isTemplate"] as? Bool == true)
        #expect(task["isScheduled"] as? Bool == true)
        #expect(task["scheduledRunAt"] as? String != nil)
        #expect(task["descriptionWasTruncated"] as? Bool == true)
        #expect(task["templateInputDefinitionCount"] as? Int == 1)
        #expect(task["requiredTemplateInputCount"] as? Int == 1)
        #expect(task["missingRequiredTemplateInputNames"] as? [String] == ["target_app"])
        let criteria = try #require(task["acceptanceCriteriaSummaries"] as? [[String: Any]])
        #expect(criteria.first?["name"] as? String == "Audit exists")
        #expect(criteria.first?["hasInputEnumeratorPrompt"] as? Bool == true)
        #expect(!result.output.contains("full prompt is hidden from list_tasks"))
        #expect(!result.output.contains("full enumerator is hidden from list_tasks"))
    }

    @Test("ListTasksTool supports parent template and inactive disposition filters")
    func listTasksParentAndDispositionFilters() async throws {
        let inactive = InactiveTaskStore()
        let taskStore = TaskStore(inactiveStore: inactive)
        let template = await taskStore.addTask(title: "Template", description: "Reusable", isTemplate: true)
        let instance = try #require(await taskStore.cloneTemplateInstance(templateID: template.id))
        let archived = await taskStore.addTask(title: "Archived", description: "Inactive")
        _ = await taskStore.archive(id: archived.id)

        let tool = ListTasksTool()
        let instances = try await tool.execute(
            arguments: [
                "has_parent_template": .bool(true),
                "parent_task_id": .string(template.id.uuidString)
            ],
            context: makeContext(taskStore: taskStore)
        )
        let instanceTasks = try #require((Self.decodeJSONObject(instances.output)?["tasks"]) as? [[String: Any]])
        #expect(instanceTasks.count == 1)
        #expect(instanceTasks.first?["id"] as? String == instance.id.uuidString)
        #expect(instanceTasks.first?["hasParentTemplate"] as? Bool == true)
        #expect(instanceTasks.first?["parentTemplateID"] as? String == template.id.uuidString)

        let archivedResult = try await tool.execute(
            arguments: ["disposition_filter": .string("archived")],
            context: makeContext(taskStore: taskStore)
        )
        let archivedTasks = try #require((Self.decodeJSONObject(archivedResult.output)?["tasks"]) as? [[String: Any]])
        #expect(archivedTasks.count == 1)
        #expect(archivedTasks.first?["id"] as? String == archived.id.uuidString)
        #expect(archivedTasks.first?["disposition"] as? String == "archived")
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

    private static func decodeJSONObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        do {
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
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
