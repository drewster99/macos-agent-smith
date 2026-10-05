import Foundation
import Testing
import SemanticSearch
import SwiftLLMKit
@testable import AgentSmithKit

/// A task's required capabilities: its own field (decided 2026-10-05, user), what the Security
/// Agent's tool scoping pays special attention to, and where Smith records a running worker's unmet
/// need — marked as a later addition, with its reason — instead of granting a tool.
@Suite("Required capabilities")
struct RequiredCapabilityTests {

    private static let sharedEngine = SemanticSearchEngine()

    // MARK: - Store

    @Test("a later addition is marked, attributed, recorded in the update history, and emits a change")
    func addLater() async throws {
        let store = TaskStore()
        let task = await store.addTask(title: "Audit", description: "Audit the calendar.")
        let events = EventCollector()
        await store.setEventObserver { events.append($0) }

        let outcome = await store.addRequiredCapability(
            id: task.id, text: "  Read the user's calendar ", addedBy: .smith, reason: "worker could not read it"
        )
        guard case .added(let added) = outcome else {
            Issue.record("expected .added, got \(outcome)")
            return
        }
        #expect(added.text == "Read the user's calendar")
        #expect(added.origin == .addedLater)
        #expect(added.addedBy == .smith)
        #expect(added.reason == "worker could not read it")

        let stored = try #require(await store.task(id: task.id))
        #expect(stored.requiredCapabilities == [added])
        #expect(stored.updates.last?.message == "Required capability added by Smith: Read the user's calendar — reason: worker could not read it")
        #expect(events.values.contains(.requiredCapabilitiesChanged(taskID: task.id)))
    }

    @Test("an item already listed is not added twice and changes nothing")
    func duplicateNotAdded() async throws {
        let store = TaskStore()
        let task = await store.addTask(
            title: "Audit", description: "d",
            requiredCapabilities: [RequiredCapability(text: "Edit files", addedBy: .smith, origin: .asWritten)]
        )
        let events = EventCollector()
        await store.setEventObserver { events.append($0) }

        let outcome = await store.addRequiredCapability(id: task.id, text: "edit   FILES", addedBy: .smith, reason: "again")
        guard case .alreadyListed(let existing) = outcome else {
            Issue.record("expected .alreadyListed, got \(outcome)")
            return
        }
        #expect(existing.text == "Edit files")
        #expect(await store.task(id: task.id)?.requiredCapabilities.count == 1)
        #expect(!events.values.contains(.requiredCapabilitiesChanged(taskID: task.id)))
    }

    @Test("a completed task refuses additions and edits")
    func completedRefuses() async throws {
        let store = TaskStore()
        let task = await store.addTask(title: "Done", description: "d")
        await store.driveStatus(id: task.id, to: .completed)

        let outcome = await store.addRequiredCapability(id: task.id, text: "Edit files", addedBy: .smith, reason: "late")
        guard case .refused = outcome else {
            Issue.record("expected .refused, got \(outcome)")
            return
        }
        let replacement = [RequiredCapability(text: "Edit files", addedBy: .user, origin: .addedLater)]
        #expect(await store.setRequiredCapabilities(id: task.id, replacement, editedFrom: []) != nil)
        #expect(await store.task(id: task.id)?.requiredCapabilities.isEmpty == true)
    }

    @Test("a template refuses an undefined placeholder; an instance substitutes the run's values")
    func templatePlaceholders() async throws {
        let store = TaskStore()
        let template = await store.addTask(
            title: "Build {{app_name}}", description: "Build {{app_name}}.",
            isTemplate: true,
            templateInputDefinitions: [TemplateInputDefinition(name: "app_name", description: "App", required: true)],
            requiredCapabilities: [RequiredCapability(text: "Compile {{app_name}}", addedBy: .smith, origin: .asWritten)]
        )
        guard case .refused(let problem) = await store.addRequiredCapability(
            id: template.id, text: "Sign {{app_nmae}}", addedBy: .smith, reason: "typo"
        ) else {
            Issue.record("an undefined placeholder was accepted on a template")
            return
        }
        #expect(problem.contains("required capability"))
        guard case .added = await store.addRequiredCapability(
            id: template.id, text: "Sign {{app_name}}", addedBy: .smith, reason: "needs signing"
        ) else {
            Issue.record("a defined placeholder was refused on a template")
            return
        }

        guard case .success(let instance) = await store.instantiateTemplate(templateID: template.id, inputValues: ["app_name": "Foo"]) else {
            Issue.record("instantiation failed")
            return
        }
        // Everything an instance starts with was part of it as written, but keeps who added it and why.
        #expect(instance.requiredCapabilities.map(\.text) == ["Compile Foo", "Sign Foo"])
        #expect(instance.requiredCapabilities.allSatisfy { $0.origin == .asWritten })
        #expect(instance.requiredCapabilities.last?.reason == "needs signing")

        guard case .added(let onInstance) = await store.addRequiredCapability(
            id: instance.id, text: "Notarize {{app_name}}", addedBy: .smith, reason: "release"
        ) else {
            Issue.record("addition to an instance failed")
            return
        }
        #expect(onInstance.text == "Notarize Foo")
    }

    @Test("the user's wholesale edit keeps provenance and emits a change only when something changed")
    func setWholesale() async throws {
        let store = TaskStore()
        let original = RequiredCapability(text: "Edit files", addedBy: .smith, origin: .asWritten)
        let task = await store.addTask(title: "T", description: "d", requiredCapabilities: [original])
        let events = EventCollector()
        await store.setEventObserver { events.append($0) }

        #expect(await store.setRequiredCapabilities(id: task.id, [original], editedFrom: [original]) == nil)
        #expect(events.values.isEmpty)

        var edited = original
        edited.text = "Edit Swift files"
        #expect(await store.setRequiredCapabilities(id: task.id, [edited], editedFrom: [original]) == nil)
        let stored = try #require(await store.task(id: task.id)?.requiredCapabilities.first)
        #expect(stored.id == original.id)
        #expect(stored.addedBy == .smith)
        #expect(stored.text == "Edit Swift files")
        #expect(events.values == [.requiredCapabilitiesChanged(taskID: task.id)])
    }

    @Test("an item added while the editor was open survives the editor's save; a deleted one stays deleted")
    func concurrentAdditionSurvives() async throws {
        let store = TaskStore()
        let kept = RequiredCapability(text: "Edit files", addedBy: .smith, origin: .asWritten)
        let removed = RequiredCapability(text: "Browse the web", addedBy: .smith, origin: .asWritten)
        let task = await store.addTask(title: "T", description: "d", requiredCapabilities: [kept, removed])
        let opened = try #require(await store.task(id: task.id)?.requiredCapabilities)

        guard case .added(let meanwhile) = await store.addRequiredCapability(
            id: task.id, text: "Read mail", addedBy: .smith, reason: "worker blocked"
        ) else {
            Issue.record("addition failed")
            return
        }
        #expect(await store.setRequiredCapabilities(id: task.id, [kept], editedFrom: opened) == nil)
        #expect(await store.task(id: task.id)?.requiredCapabilities.map(\.id) == [kept.id, meanwhile.id])
    }

    // MARK: - Persistence

    @Test("capabilities round-trip, and a task written before the field existed decodes with none")
    func codable() throws {
        var task = AgentTask(title: "T", description: "d")
        task.requiredCapabilities = [
            RequiredCapability(text: "Edit files", addedBy: .smith, origin: .asWritten),
            RequiredCapability(text: "Read mail", addedBy: .smith, origin: .addedLater, reason: "blocked")
        ]
        let data = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(AgentTask.self, from: data)
        #expect(decoded.requiredCapabilities == task.requiredCapabilities)

        let bare = try JSONEncoder().encode(AgentTask(title: "T", description: "d"))
        #expect(String(decoding: bare, as: UTF8.self).contains("requiredCapabilities") == false)
        #expect(try JSONDecoder().decode(AgentTask.self, from: bare).requiredCapabilities.isEmpty)
    }

    @Test("an origin this build doesn't know decodes as a later addition, not a failed task")
    func unknownOrigin() throws {
        let json = #"{"id":"\#(UUID().uuidString)","text":"x","addedBy":"smith","addedAt":0,"origin":"fromTheFuture"}"#
        let decoded = try JSONDecoder().decode(RequiredCapability.self, from: Data(json.utf8))
        #expect(decoded.origin == .addedLater)
    }

    // MARK: - Rendering

    @Test("a later addition renders with who, when and why; an original item renders bare")
    func rendering() {
        var task = AgentTask(title: "T", description: "Do it.")
        #expect(task.renderedRequiredCapabilities() == nil)
        #expect(task.renderedDescriptionForSecurityReview() == "Do it.")

        task.requiredCapabilities = [
            RequiredCapability(text: "Edit files", addedBy: .smith, origin: .asWritten),
            RequiredCapability(text: "Read mail", addedBy: .smith, addedAt: Date(timeIntervalSince1970: 0), origin: .addedLater, reason: "blocked")
        ]
        let rendered = task.renderedRequiredCapabilities()
        #expect(rendered == "- Edit files\n- Read mail [added later by Smith, 1970-01-01T00:00:00Z: blocked]")
        #expect(task.renderedDescriptionForSecurityReview() == "Do it.\n\n## Required capabilities\n\(rendered ?? "")")
    }

    // MARK: - Tools

    @Test("create_task stores required_capabilities as written, deduplicated")
    func createTaskStoresThem() async throws {
        let store = TaskStore()
        let context = TestToolContext.make(agentRole: .smith, taskStore: store)
        let result = try await CreateTaskTool().execute(
            arguments: [
                "title": .string("Build"),
                "description": .string("Build the app."),
                "required_capabilities": .array([.string("Compile the Xcode project"), .string("compile the  xcode project"), .string("Edit files"), .string("  ")])
            ],
            context: context
        )
        #expect(result.succeeded, "\(result.output)")
        let task = try #require(await store.allTasks().first)
        #expect(task.requiredCapabilities.map(\.text) == ["Compile the Xcode project", "Edit files"])
        #expect(task.requiredCapabilities.allSatisfy { $0.origin == .asWritten && $0.addedBy == .smith })
    }

    @Test("create_task refuses a template capability with an undefined placeholder, creating nothing")
    func createTaskTemplatePlaceholder() async throws {
        let store = TaskStore()
        let context = TestToolContext.make(agentRole: .smith, taskStore: store)
        let result = try await CreateTaskTool().execute(
            arguments: [
                "title": .string("Build {{app_name}}"),
                "description": .string("Build {{app_name}}."),
                "is_template": .bool(true),
                "template_inputs": .array([.dictionary(["name": .string("app_name"), "description": .string("App"), "required": .bool(true)])]),
                "required_capabilities": .array([.string("Compile {{app_nmae}}")])
            ],
            context: context
        )
        #expect(!result.succeeded)
        #expect(result.output.contains("required capability 1"))
        #expect(await store.allTasks().isEmpty)
        #expect(await store.allLibraryTemplates().isEmpty)
    }

    @Test("add_required_capability is Smith's, needs a reason, and records the addition")
    func addTool() async throws {
        let tool = AddRequiredCapabilityTool()
        #expect(tool.isAvailable(in: ToolAvailabilityContext(agentRole: .smith)))
        #expect(!tool.isAvailable(in: ToolAvailabilityContext(agentRole: .brown)))
        #expect(SmithBehavior.tools().contains { $0.name == tool.name })
        #expect(!BrownBehavior.toolNames.contains(tool.name))

        let store = TaskStore()
        let task = await store.addTask(title: "T", description: "d")
        let context = TestToolContext.make(agentRole: .smith, taskStore: store)

        let noReason = try await tool.execute(
            arguments: ["task_id": .string(task.id.uuidString), "capability": .string("Read mail"), "reason": .string(" ")],
            context: context
        )
        #expect(!noReason.succeeded)
        #expect(await store.task(id: task.id)?.requiredCapabilities.isEmpty == true)

        let added = try await tool.execute(
            arguments: ["task_id": .string(task.id.uuidString), "capability": .string("Read mail"), "reason": .string("worker blocked")],
            context: context
        )
        #expect(added.succeeded, "\(added.output)")
        #expect(await store.task(id: task.id)?.requiredCapabilities.map(\.renderedLine).first?.hasPrefix("Read mail [added later by Smith") == true)
    }

    @Test("get_task_details shows the required capabilities")
    func getTaskDetails() async throws {
        let store = TaskStore()
        let task = await store.addTask(
            title: "T", description: "d",
            requiredCapabilities: [RequiredCapability(text: "Edit files", addedBy: .smith, origin: .asWritten)]
        )
        let context = TestToolContext.make(agentRole: .brown, taskStore: store)
        let result = try await GetTaskDetailsTool().execute(
            arguments: ["task_ids": .array([.string(task.id.uuidString)])], context: context
        )
        #expect(result.output.contains("Required capabilities:\n- Edit files"))
    }

    @Test("the worker briefing has a Required capabilities section")
    func briefing() async throws {
        let runtime = makeRuntime()
        let task = await runtime.taskStore.addTask(
            title: "T", description: "d",
            requiredCapabilities: [RequiredCapability(text: "Edit files", addedBy: .smith, origin: .asWritten)]
        )
        let briefing = await runtime.composeBrownTaskBriefing(for: task)
        #expect(briefing.contains("## Required capabilities"))
        #expect(briefing.contains("- Edit files"))
    }

    // MARK: - Helpers

    private final class EventCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [TaskStoreEvent] = []
        var values: [TaskStoreEvent] { lock.withLock { events } }
        func append(_ event: TaskStoreEvent) { lock.withLock { events.append(event) } }
    }

    private func makeRuntime() -> OrchestrationRuntime {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-smith-capability-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let config = ModelConfiguration(name: "test", providerID: "test", modelID: "test-model", maxOutputTokens: 1024, maxContextTokens: 100_000)
        return OrchestrationRuntime(
            providers: [
                .smith: MockLLMProvider(responses: [LLMResponse(text: "Standing by.")]),
                .securityAgent: MockLLMProvider(responses: [LLMResponse(text: "SAFE")])
            ],
            configurations: [.smith: config, .securityAgent: config],
            providerAPITypes: [:],
            agentTuning: [:],
            semanticSearchEngine: Self.sharedEngine,
            usageStore: UsageStore(persistence: PersistenceManager(testingRoot: tmpRoot)),
            autoAdvanceEnabled: false,
            autoRunInterruptedTasks: false,
            memoryStore: nil
        )
    }
}
