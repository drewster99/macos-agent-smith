import Foundation
import Testing
@testable import AgentSmithKit

/// The agent-facing surface of the validation system: Brown's `manage_steps`, Smith's
/// `set_acceptance_criteria` / `list_validators`, and `create_task`'s criteria/steps
/// seeding.

@Suite("Validation agent surface")
struct ValidationAgentSurfaceTests {

    /// A TempDir-backed registry with the shipped default seeded, exposed the way
    /// production wires it (a fresh load per call).
    private func makeSeededRegistryLoader() -> @Sendable () async -> EvaluatorRegistry? {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-smith-surface-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        // Built-ins (incl. default) come from the app itself now; the
        // directory only needs to exist for user-authored additions.
        return { EvaluatorRegistry.load(from: directory) }
    }

    // MARK: - manage_steps

    @Test("manage_steps: add, set_status, and the tombstone rules")
    func manageStepsLifecycle() async throws {
        let taskStore = TaskStore()
        let agentID = UUID()
        let task = await taskStore.addTask(title: "t", description: "d")
        await taskStore.assignAgent(taskID: task.id, agentID: agentID)
        let context = TestToolContext.make(agentID: agentID, agentRole: .brown, taskStore: taskStore)
        let tool = ManageStepsTool()

        let added = try await tool.execute(
            arguments: ["action": .string("add"), "texts": .array([.string("first"), .string("second")])],
            context: context
        )
        #expect(added.succeeded)
        var steps = await taskStore.task(id: task.id)?.steps ?? []
        #expect(steps.count == 2)
        #expect(steps.allSatisfy { $0.origin == .worker })

        // Completing needs no note; skipping without a note is refused.
        let firstID = steps[0].id.uuidString
        let completed = try await tool.execute(
            arguments: ["action": .string("set_status"), "step_id": .string(firstID), "status": .string("completed")],
            context: context
        )
        #expect(completed.succeeded)

        let skippedNoNote = try await tool.execute(
            arguments: ["action": .string("set_status"), "step_id": .string(steps[1].id.uuidString), "status": .string("skipped")],
            context: context
        )
        #expect(!skippedNoNote.succeeded)

        // Removal with a note tombstones: hidden from the active list, immutable after.
        let removed = try await tool.execute(
            arguments: ["action": .string("set_status"), "step_id": .string(steps[1].id.uuidString), "status": .string("removed"), "note": .string("superseded by first")],
            context: context
        )
        #expect(removed.succeeded)
        #expect(removed.output.contains("removed step(s) remain on the record"))

        let editRemoved = try await tool.execute(
            arguments: ["action": .string("update"), "step_id": .string(steps[1].id.uuidString), "text": .string("rewrite history")],
            context: context
        )
        #expect(!editRemoved.succeeded)

        steps = await taskStore.task(id: task.id)?.steps ?? []
        #expect(steps.count == 2, "the tombstone stays on the record")
        #expect(steps[1].status == .removed)
        #expect(steps[1].note == "superseded by first")
    }

    @Test("manage_steps is Brown-only")
    func manageStepsAvailability() {
        let tool = ManageStepsTool()
        #expect(tool.isAvailable(in: ToolAvailabilityContext(agentRole: .brown)))
        #expect(!tool.isAvailable(in: ToolAvailabilityContext(agentRole: .smith)))
    }

    // MARK: - set_acceptance_criteria

    @Test("set_acceptance_criteria replaces the list, preserves identity for unchanged text")
    func setCriteriaPreservesUnchangedIdentity() async throws {
        let taskStore = TaskStore()
        let channel = MessageChannel()
        let task = await taskStore.addTask(title: "t", description: "d")
        let original = AcceptanceCriterion(text: "stays the same", origin: .user)
        await taskStore.setAcceptanceCriteria(id: task.id, criteria: [original])

        let context = TestToolContext.make(
            agentRole: .smith,
            channel: channel,
            taskStore: taskStore,
            loadEvaluatorRegistry: makeSeededRegistryLoader()
        )
        let result = try await SetAcceptanceCriteriaTool().execute(
            arguments: [
                "task_id": .string(task.id.uuidString),
                "criteria": .array([
                    .dictionary(["text": .string("stays the same")]),
                    .dictionary(["text": .string("brand new"), "waivable": .bool(true), "validator_name": .string("default")])
                ])
            ],
            context: context
        )
        #expect(result.succeeded)

        let criteria = await taskStore.task(id: task.id)?.acceptanceCriteria ?? []
        #expect(criteria.count == 2)
        #expect(criteria[0].id == original.id, "unchanged text keeps the criterion's identity (and its sticky accept)")
        #expect(criteria[0].origin == .user)
        #expect(criteria[1].origin == .smith)
        #expect(criteria[1].waivable)
        #expect(criteria[1].validator == .registry("default"))

        let posted = await channel.allMessages()
        #expect(posted.contains { if case .string("criteria_updated") = $0.metadata?["messageKind"] { return true }; return false })
    }

    @Test("set_acceptance_criteria works on a FAILED task (recovery) but not a COMPLETED one")
    func setCriteriaAllowedOnFailedBlockedOnCompleted() async throws {
        let taskStore = TaskStore()
        let context = TestToolContext.make(
            agentRole: .smith,
            taskStore: taskStore,
            loadEvaluatorRegistry: makeSeededRegistryLoader()
        )
        let tool = SetAcceptanceCriteriaTool()

        // Failed task: editing criteria is the recovery path (run_task then resets it), so allowed.
        let failed = await taskStore.addTask(title: "f", description: "d")
        await taskStore.updateStatus(id: failed.id, status: .failed)
        let onFailed = try await tool.execute(
            arguments: ["task_id": .string(failed.id.uuidString),
                        "criteria": .array([.dictionary(["text": .string("fixed criterion")])])],
            context: context
        )
        #expect(onFailed.succeeded, "a failed task's criteria must be editable so it can be corrected and re-run")

        // Completed task: result was accepted and delivered — closed to criteria edits.
        let completed = await taskStore.addTask(title: "c", description: "d")
        await taskStore.setResult(id: completed.id, result: "done", commentary: nil)
        await taskStore.updateStatus(id: completed.id, status: .completed)
        let onCompleted = try await tool.execute(
            arguments: ["task_id": .string(completed.id.uuidString),
                        "criteria": .array([.dictionary(["text": .string("too late")])])],
            context: context
        )
        #expect(!onCompleted.succeeded)
        #expect(onCompleted.output.contains("completed"))
    }

    @Test("set_acceptance_criteria rejects an unknown validator name, listing what exists")
    func setCriteriaRejectsUnknownValidator() async throws {
        let taskStore = TaskStore()
        let task = await taskStore.addTask(title: "t", description: "d")
        let context = TestToolContext.make(
            agentRole: .smith,
            taskStore: taskStore,
            loadEvaluatorRegistry: makeSeededRegistryLoader()
        )
        let result = try await SetAcceptanceCriteriaTool().execute(
            arguments: [
                "task_id": .string(task.id.uuidString),
                "criteria": .array([.dictionary(["text": .string("c"), "validator_name": .string("nope")])])
            ],
            context: context
        )
        #expect(!result.succeeded)
        #expect(result.output.contains("default"), "the failure must teach the available names")
        let criteria = await taskStore.task(id: task.id)?.acceptanceCriteria ?? []
        #expect(criteria.isEmpty, "a failed call must not half-apply")
    }

    @Test("set_acceptance_criteria refuses completed tasks")
    func setCriteriaRefusesCompleted() async throws {
        let taskStore = TaskStore()
        let task = await taskStore.addTask(title: "t", description: "d")
        await taskStore.updateStatus(id: task.id, status: .completed)
        let context = TestToolContext.make(agentRole: .smith, taskStore: taskStore)
        let result = try await SetAcceptanceCriteriaTool().execute(
            arguments: [
                "task_id": .string(task.id.uuidString),
                "criteria": .array([.dictionary(["text": .string("c")])])
            ],
            context: context
        )
        #expect(!result.succeeded)
    }

    // MARK: - list_validators

    @Test("list_validators surfaces the registry; unconfigured is a visible failure")
    func listValidators() async throws {
        let seeded = TestToolContext.make(agentRole: .smith, loadEvaluatorRegistry: makeSeededRegistryLoader())
        let listed = try await ListValidatorsTool().execute(arguments: [:], context: seeded)
        #expect(listed.succeeded)
        #expect(listed.output.contains("default"))

        let unconfigured = TestToolContext.make(agentRole: .smith)
        let failed = try await ListValidatorsTool().execute(arguments: [:], context: unconfigured)
        #expect(!failed.succeeded)
    }

    // MARK: - Custom validator authoring

    @Test("define_validator persists both kinds with the system-supplied contract; built-in names and silent overwrites are refused")
    func defineValidatorAuthoring() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-smith-authoring-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Mirror the runtime's save closure over a TempDir registry.
        let save: @Sendable (EvaluatorDefinition, Bool) async -> String? = { definition, overwrite in
            if EvaluatorDefaults.builtInNames.contains(definition.name) { return "'\(definition.name)' is a built-in definition name" }
            let target = directory.appendingPathComponent("\(definition.name).json")
            if FileManager.default.fileExists(atPath: target.path) && !overwrite { return "already exists" }
            let encoder = JSONEncoder()
            guard let data = try? encoder.encode(definition) else { return "encode failed" }
            try? data.write(to: target, options: .atomic)
            return nil
        }
        let context = TestToolContext.make(agentRole: .smith, saveEvaluatorDefinition: save)
        let tool = DefineValidatorTool()

        // A prepare function: enumeration prompt + JSON-array grammar appended by the system.
        let prepareResult = try await tool.execute(arguments: [
            "name": .string("swift-files-enumerator"),
            "kind": .string("prepare"),
            "description": .string("Lists every Swift file the task touched."),
            "system_prompt": .string("Enumerate every .swift file referenced by the task's result or steps.")
        ], context: context)
        #expect(prepareResult.succeeded)

        // A validator: judgment prompt + verdict grammar; the system supplies the contract.
        let validatorResult = try await tool.execute(arguments: [
            "name": .string("file-header-check"),
            "kind": .string("validator"),
            "description": .string("Checks one Swift file has a documentation header."),
            "system_prompt": .string("Verify the file named in the item has a documentation comment as its first non-import line.")
        ], context: context)
        #expect(validatorResult.succeeded)

        let registry = EvaluatorRegistry.load(from: directory)
        let prepare = registry.definition(named: "swift-files-enumerator")
        #expect(prepare?.kind == .prepare)
        #expect(prepare?.outputGrammar == .jsonArray, "prepare gets the JSON-array contract automatically")
        let validator = registry.definition(named: "file-header-check")
        #expect(validator?.kind == .validator)
        #expect(validator?.toolNames == EvaluatorDefaults.validatorEvidenceToolNames, "capability is capped to the evidence quartet")
        #expect(validator?.systemPrompt == "Verify the file named in the item has a documentation comment as its first non-import line.", "the authored prompt is stored raw; the response contract is applied at judge time")
        #expect(registry.failures.isEmpty)

        // Built-in names are reserved; existing names need overwrite:true.
        let builtIn = try await tool.execute(arguments: [
            "name": .string("default"), "kind": .string("validator"),
            "description": .string("x"), "system_prompt": .string("x")
        ], context: context)
        #expect(!builtIn.succeeded)
        let duplicate = try await tool.execute(arguments: [
            "name": .string("file-header-check"), "kind": .string("validator"),
            "description": .string("x"), "system_prompt": .string("changed")
        ], context: context)
        #expect(!duplicate.succeeded)
    }

    @Test("set_acceptance_criteria accepts an inline_validator and embeds it on the criterion")
    func inlineCustomValidatorOnCriterion() async throws {
        let taskStore = TaskStore()
        let task = await taskStore.addTask(title: "t", description: "d")
        let context = TestToolContext.make(agentRole: .smith, taskStore: taskStore, loadEvaluatorRegistry: makeSeededRegistryLoader())
        let result = try await SetAcceptanceCriteriaTool().execute(
            arguments: [
                "task_id": .string(task.id.uuidString),
                "criteria": .array([
                    .dictionary([
                        "text": .string("the summary is in French"),
                        "inline_validator": .dictionary([
                            "name": .string("french-check"),
                            "system_prompt": .string("Verify the submitted result is written in French.")
                        ])
                    ])
                ])
            ],
            context: context
        )
        #expect(result.succeeded)

        let criterion = await taskStore.task(id: task.id)?.acceptanceCriteria.first
        guard case .inline(let definition)? = criterion?.validator else {
            Issue.record("expected an inline validator, got \(String(describing: criterion?.validator))")
            return
        }
        #expect(definition.name == "french-check")
        #expect(definition.systemPrompt == "Verify the submitted result is written in French.", "the authored prompt is stored raw; the response contract is applied at judge time")
        #expect(definition.outputGrammar == .verdictLine(allowed: [
            .init(token: "ACCEPT", requiresReason: false),
            .init(token: "REJECT", requiresReason: true),
            .init(token: "WAIVE", requiresReason: true)
        ]), "the system supplies the verdict grammar")
        #expect(definition.toolNames == EvaluatorDefaults.validatorEvidenceToolNames)
    }

    @Test("create_task accepts criterion objects (inline validator + waivable) alongside strings")
    func createTaskObjectCriteria() async throws {
        let taskStore = TaskStore()
        let context = TestToolContext.make(agentRole: .smith, taskStore: taskStore)
        let result = try await CreateTaskTool().execute(
            arguments: [
                "title": .string("Mixed criteria task"),
                "description": .string("d"),
                "acceptance_criteria": .array([
                    .string("plain criterion"),
                    .dictionary([
                        "text": .string("fancy criterion"),
                        "waivable": .bool(true),
                        "inline_validator": .dictionary(["system_prompt": .string("Judge fancily.")])
                    ])
                ])
            ],
            context: context
        )
        #expect(result.succeeded)
        let criteria = await taskStore.allTasks().first?.acceptanceCriteria ?? []
        #expect(criteria.count == 2)
        #expect(criteria[0].validator == nil)
        #expect(criteria[1].waivable)
        if case .inline = criteria[1].validator {} else {
            Issue.record("expected inline validator on the object criterion")
        }
    }

    @Test("create_task with invalid criteria creates NO task at all")
    func createTaskInvalidCriteriaCreatesNothing() async throws {
        let taskStore = TaskStore()
        let context = TestToolContext.make(agentRole: .smith, taskStore: taskStore)
        let result = try await CreateTaskTool().execute(
            arguments: [
                "title": .string("Doomed"),
                "description": .string("d"),
                "acceptance_criteria": .array([
                    .dictionary(["text": .string("c"), "validator_name": .string("does-not-exist")])
                ])
            ],
            context: context
        )
        #expect(!result.succeeded)
        #expect(result.output.contains("NOT created"))
        #expect(await taskStore.allTasks().isEmpty, "bad criteria must not leave an orphaned task behind")
    }

    // MARK: - review_work override visibility

    @Test("Accepting an escalated task records the override: ledger settles, update logged, channel told")
    func reviewWorkAcceptRecordsOverride() async throws {
        let taskStore = TaskStore()
        let channel = MessageChannel()
        let task = await taskStore.addTask(title: "Escalated task", description: "d")
        let criterion = AcceptanceCriterion(text: "the validator got this wrong", origin: .user)
        await taskStore.setAcceptanceCriteria(id: task.id, criteria: [criterion])
        await taskStore.setResult(id: task.id, result: "correct work", commentary: nil, attachments: [])
        _ = await taskStore.beginValidationRound(id: task.id)
        await taskStore.recordCriterionVerdicts(id: task.id, records: [
            CriterionVerdictRecord(criterionID: criterion.id, verdict: .rejected(reason: "wrongly rejected"), validatorName: "default", validatorHash: "x", round: 1)
        ])
        await taskStore.updateStatus(id: task.id, status: .awaitingReview)

        let context = TestToolContext.make(agentRole: .smith, channel: channel, taskStore: taskStore)
        let result = try await ReviewWorkTool().execute(
            arguments: ["task_id": .string(task.id.uuidString), "accepted": .bool(true)],
            context: context
        )
        #expect(result.succeeded)

        let final = await taskStore.task(id: task.id)
        #expect(final?.status == .completed)
        #expect(final?.validation?.settledCriterionIDs() == [criterion.id], "the override settles the criterion on the ledger")
        let overrideRecord = final?.validation?.verdictRecords.last
        #expect(overrideRecord?.validatorName == "review_work (Smith override)")
        #expect(final?.updates.contains { $0.message.contains("overriding acceptance validation") } == true)

        let posted = await channel.allMessages()
        #expect(posted.contains { if case .string("validation_override") = $0.metadata?["messageKind"] { return true }; return false },
                "the override must be visible in the channel, never a silent completion")
    }

    // MARK: - Spawn-time validator catalog

    @Test("The validator catalog snapshot is baked into set_acceptance_criteria's description")
    func validatorCatalogBakedIntoDescription() {
        let bare = SetAcceptanceCriteriaTool()
        #expect(!bare.toolDescription.contains("Installed validators"))

        let baked = SetAcceptanceCriteriaTool(validatorCatalogSummary: "- `default`: judges the whole task")
        #expect(baked.toolDescription.contains("Installed validators"))
        #expect(baked.toolDescription.contains("default"))

        let smithTools = SmithBehavior.tools(validatorCatalogSummary: "- `x`: y")
        let tool = smithTools.first { $0.name == "set_acceptance_criteria" }
        #expect(tool?.toolDescription.contains("- `x`: y") == true)
    }

    // MARK: - create_task seeding

    @Test("create_task seeds acceptance criteria and initial steps")
    func createTaskSeedsCriteriaAndSteps() async throws {
        let taskStore = TaskStore()
        let context = TestToolContext.make(agentRole: .smith, taskStore: taskStore)
        let result = try await CreateTaskTool().execute(
            arguments: [
                "title": .string("Seeded task"),
                "description": .string("with contract and plan"),
                "acceptance_criteria": .array([.string("the report exists"), .string("   "), .string("it names three vendors")]),
                "steps": .array([.string("research vendors"), .string("write report")])
            ],
            context: context
        )
        #expect(result.succeeded)

        let task = await taskStore.allTasks().first
        #expect(task?.acceptanceCriteria.map(\.text) == ["the report exists", "it names three vendors"], "blank entries are dropped")
        #expect(task?.acceptanceCriteria.allSatisfy { $0.origin == .smith } == true)
        #expect(task?.steps.map(\.text) == ["research vendors", "write report"])
        #expect(task?.steps.allSatisfy { $0.origin == .smith } == true)
    }
}
