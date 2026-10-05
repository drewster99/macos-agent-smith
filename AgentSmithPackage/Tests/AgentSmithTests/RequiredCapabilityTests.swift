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
        #expect(await store.editRequiredCapabilities(id: task.id, [.add(text: "Edit files", reason: nil)], by: .user) != nil)
        #expect(await store.task(id: task.id)?.requiredCapabilities.isEmpty == true)
    }

    @Test("the lock is one rule: completed and validating lock, archived/deleted lock, everything else edits")
    func lockReasonTable() {
        for status in AgentTask.Status.allCases {
            let task = AgentTask(title: "T", description: "d", status: status)
            switch status {
            case .completed: #expect(task.requiredCapabilitiesLockReason == .completed)
            case .validating: #expect(task.requiredCapabilitiesLockReason == .validating)
            case .pending, .starting, .running, .failed, .paused, .awaitingReview, .awaitingHelp, .interrupted, .scheduled:
                #expect(task.requiredCapabilitiesLockReason == nil, "\(status) should be editable")
            }
            let archived = AgentTask(title: "T", description: "d", status: status, disposition: .archived)
            #expect(archived.requiredCapabilitiesLockReason == .notInActiveList)
            #expect(!archived.isDefinitionEditable)
        }
    }

    @Test("a validating task's refusal tells Smith how the lock ends")
    func validatingRefusalNamesTheWayOut() {
        let refusal = RequiredCapabilitiesLockReason.validating.refusal(taskTitle: "T")
        #expect(refusal.contains("after validation ends"))
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

    @Test("a reword keeps identity and provenance, is recorded, and emits a change only when something changed")
    func rewordKeepsProvenance() async throws {
        let store = TaskStore()
        let original = RequiredCapability(text: "Edit files", addedBy: .smith, origin: .asWritten)
        let task = await store.addTask(title: "T", description: "d", requiredCapabilities: [original])
        let events = EventCollector()
        await store.setEventObserver { events.append($0) }

        #expect(await store.editRequiredCapabilities(id: task.id, [.reword(id: original.id, text: " Edit files ")], by: .user) == nil)
        #expect(events.values.isEmpty)

        #expect(await store.editRequiredCapabilities(id: task.id, [.reword(id: original.id, text: "Edit Swift files")], by: .user) == nil)
        let stored = try #require(await store.task(id: task.id))
        let item = try #require(stored.requiredCapabilities.first)
        #expect(item.id == original.id)
        #expect(item.addedBy == .smith)
        #expect(item.origin == .asWritten)
        #expect(item.text == "Edit Swift files")
        #expect(stored.updates.last?.message == "Required capability reworded by the user: \"Edit files\" → \"Edit Swift files\"")
        #expect(events.values == [.requiredCapabilitiesChanged(taskID: task.id)])
    }

    @Test("an edit batch is atomic: a refused reword leaves the earlier removal unapplied")
    func batchIsAtomic() async throws {
        let store = TaskStore()
        let first = RequiredCapability(text: "Edit files", addedBy: .smith, origin: .asWritten)
        let second = RequiredCapability(text: "Browse the web", addedBy: .smith, origin: .asWritten)
        let third = RequiredCapability(text: "Read mail", addedBy: .smith, origin: .asWritten)
        let task = await store.addTask(title: "T", description: "d", requiredCapabilities: [first, second, third])

        let refusal = await store.editRequiredCapabilities(
            id: task.id,
            [.remove(id: first.id), .reword(id: second.id, text: "read MAIL")],
            by: .user
        )
        #expect(refusal?.contains("already listed") == true)
        #expect(await store.task(id: task.id)?.requiredCapabilities == [first, second, third])
    }

    @Test("a user addition through the editor is a later addition by the user")
    func editorAdditionIsLater() async throws {
        let store = TaskStore()
        let task = await store.addTask(title: "T", description: "d")
        #expect(await store.editRequiredCapabilities(id: task.id, [.add(text: "Read mail", reason: nil)], by: .user) == nil)
        let item = try #require(await store.task(id: task.id)?.requiredCapabilities.first)
        #expect(item.origin == .addedLater)
        #expect(item.addedBy == .user)
        #expect(item.reason == nil)
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
        let edits = RequiredCapabilityEdit.edits(from: opened, to: [RequiredCapabilityDraft(existingID: kept.id, text: kept.text)])
        #expect(edits == [.remove(id: removed.id)])
        #expect(await store.editRequiredCapabilities(id: task.id, edits, by: .user) == nil)
        #expect(await store.task(id: task.id)?.requiredCapabilities.map(\.id) == [kept.id, meanwhile.id])
        #expect(await store.task(id: task.id)?.updates.last?.message == "Required capability removed by the user: Browse the web")
    }

    @Test("a reword of an item removed meanwhile is refused; a removal of one is a no-op")
    func editsAgainstVanishedItems() async throws {
        let store = TaskStore()
        let item = RequiredCapability(text: "Edit files", addedBy: .smith, origin: .asWritten)
        let task = await store.addTask(title: "T", description: "d", requiredCapabilities: [item])
        #expect(await store.editRequiredCapabilities(id: task.id, [.remove(id: item.id)], by: .user) == nil)
        #expect(await store.editRequiredCapabilities(id: task.id, [.remove(id: item.id)], by: .user) == nil)
        #expect(await store.editRequiredCapabilities(id: task.id, [.reword(id: item.id, text: "Edit Swift files")], by: .user)?.contains("removed while you were editing") == true)
    }

    // MARK: - The editor's diff

    @Test("the editor's diff: removals first, then rewords, then additions; blanks are no items")
    func editsDiff() {
        let a = RequiredCapability(text: "Edit files", addedBy: .smith, origin: .asWritten)
        let b = RequiredCapability(text: "Browse the web", addedBy: .smith, origin: .asWritten)
        let c = RequiredCapability(text: "Read mail", addedBy: .smith, origin: .asWritten)
        let drafts = [
            RequiredCapabilityDraft(existingID: a.id, text: " Edit files "),       // unchanged (trim)
            RequiredCapabilityDraft(existingID: b.id, text: "Browse docs"),        // reword
            RequiredCapabilityDraft(existingID: c.id, text: "   "),                // cleared → removal
            RequiredCapabilityDraft(existingID: nil, text: "Send mail"),           // addition
            RequiredCapabilityDraft(existingID: nil, text: "")                     // blank new row → nothing
        ]
        #expect(RequiredCapabilityEdit.edits(from: [a, b, c], to: drafts) == [
            .remove(id: c.id),
            .reword(id: b.id, text: "Browse docs"),
            .add(text: "Send mail", reason: nil)
        ])
        #expect(RequiredCapabilityEdit.edits(from: [a], to: [RequiredCapabilityDraft(existingID: a.id, text: a.text)]).isEmpty)
    }

    @Test("items as written are trimmed, blanks dropped, duplicates dropped keeping the first spelling")
    func makeAsWritten() {
        let items = RequiredCapability.makeAsWritten(["  Edit files ", "", "edit  FILES", "Read mail"], addedBy: .worker)
        #expect(items.map(\.text) == ["Edit files", "Read mail"])
        #expect(items.allSatisfy { $0.origin == .asWritten && $0.addedBy == .worker })
    }

    @Test("an instance item that renders blank (only an omitted optional input) is dropped")
    func blankInstanceItemDropped() async throws {
        let store = TaskStore()
        let template = await store.addTask(
            title: "Build", description: "Build it.",
            isTemplate: true,
            templateInputDefinitions: [TemplateInputDefinition(name: "extra", description: "Extra need", required: false)],
            requiredCapabilities: [
                RequiredCapability(text: "Compile the project", addedBy: .smith, origin: .asWritten),
                RequiredCapability(text: "{{extra}}", addedBy: .smith, origin: .asWritten)
            ]
        )
        guard case .success(let instance) = await store.instantiateTemplate(templateID: template.id, inputValues: [:]) else {
            Issue.record("instantiation failed")
            return
        }
        #expect(instance.requiredCapabilities.map(\.text) == ["Compile the project"])
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

    @Test("a child task's review text says a worker wrote it and names the user's originating task")
    func workerAuthoredReviewText() {
        let task = AgentTask(title: "Child", description: "Fetch the page.")
        let originating = TaskIntentProvenance.OriginatingTask(id: UUID(), title: "Summarize docs", description: "Summarize the local docs.")
        let withOrigin = task.renderedDescriptionForSecurityReview(provenance: .workerAuthored(originatingTask: originating))
        #expect(withOrigin.hasPrefix("Fetch the page."))
        #expect(withOrigin.contains(AgentTask.workerAuthoredHeading))
        #expect(withOrigin.contains("- title: Summarize docs"))
        let orphan = task.renderedDescriptionForSecurityReview(provenance: .workerAuthored(originatingTask: nil))
        #expect(orphan.contains("no longer exists"))
        #expect(task.renderedDescriptionForSecurityReview(provenance: .requester) == "Fetch the page.")
    }

    @Test("provenance walks the coordinator chain to the first task a worker did not write")
    func intentProvenanceWalk() async throws {
        let store = TaskStore()
        let root = await store.addTask(title: "Root", description: "The user's request.")
        #expect(await store.intentProvenance(of: root) == .requester)
        func makeChild(of coordinator: UUID, _ title: String) async throws -> AgentTask {
            guard case .created(let created) = await store.addChildTask(
                coordinatorTaskID: coordinator, limit: 10, title: title, description: "d",
                descriptionAttachments: [], acceptanceCriteria: [], steps: [], requiredCapabilities: [],
                relevantContext: .none
            ) else { throw ProvenanceTestError.notCreated }
            return created
        }
        let child = try await makeChild(of: root.id, "Child")
        let grandchild = try await makeChild(of: child.id, "Grandchild")
        let expected = TaskIntentProvenance.workerAuthored(originatingTask: .init(id: root.id, title: "Root", description: "The user's request."))
        #expect(await store.intentProvenance(of: child) == expected)
        #expect(await store.intentProvenance(of: grandchild) == expected)

        _ = await store.driveStatus(id: root.id, to: .completed)
        #expect(await store.permanentlyDelete(id: root.id))
        #expect(await store.intentProvenance(of: grandchild) == .workerAuthored(originatingTask: nil))
    }

    private enum ProvenanceTestError: Error { case notCreated }

    @Test("a later addition renders with who, when and why; an original item renders bare")
    func rendering() {
        var task = AgentTask(title: "T", description: "Do it.")
        #expect(task.renderedRequiredCapabilities() == nil)
        #expect(task.renderedDescriptionForSecurityReview(provenance: .requester) == "Do it.")

        task.requiredCapabilities = [
            RequiredCapability(text: "Edit files", addedBy: .smith, origin: .asWritten),
            RequiredCapability(text: "Read mail", addedBy: .smith, addedAt: Date(timeIntervalSince1970: 0), origin: .addedLater, reason: "blocked")
        ]
        let rendered = task.renderedRequiredCapabilities()
        #expect(rendered == "- Edit files\n- Read mail [added later by Smith, 1970-01-01T00:00:00Z: blocked]")
        #expect(task.renderedDescriptionForSecurityReview(provenance: .requester) == "Do it.\n\n## Required capabilities\n\(rendered ?? "")")
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

    @Test("create_task refuses a malformed list instead of dropping part of it, creating nothing")
    func createTaskRefusesMalformedList() async throws {
        let store = TaskStore()
        let context = TestToolContext.make(agentRole: .smith, taskStore: store)
        for arguments: [String: AnyCodable] in [
            ["required_capabilities": .string("Compile, sign")],
            ["required_capabilities": .array([.string("Compile"), .int(2)])],
            ["steps": .array([.dictionary(["text": .string("Build")])])],
            ["attachment_ids": .string("not-an-array")]
        ] {
            var full = arguments
            full["title"] = .string("Build")
            full["description"] = .string("Build the app.")
            let result = try await CreateTaskTool().execute(arguments: full, context: context)
            #expect(!result.succeeded, "\(arguments) was accepted")
        }
        #expect(await store.allTasks().isEmpty)
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
