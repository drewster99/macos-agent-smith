import Foundation
import Testing
@testable import AgentSmithKit

/// The agent-facing surface of the validation system: Brown's `manage_steps`, Smith's
/// acceptance-criterion authoring, and `create_task`'s criteria/steps seeding.

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

    @Test("set_acceptance_criteria replaces the list, preserves identity for unchanged name")
    func setCriteriaPreservesUnchangedIdentity() async throws {
        let taskStore = TaskStore()
        let channel = MessageChannel()
        let task = await taskStore.addTask(title: "t", description: "d")
        let original = AcceptanceCriterion(name: "stays the same", origin: .user)
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
                    .dictionary(["name": .string("stays the same"), "validation_prompt": .string("stays the same")]),
                    .dictionary(["name": .string("brand new"), "validation_prompt": .string("judge the new requirement"), "waivable": .bool(true)])
                ])
            ],
            context: context
        )
        #expect(result.succeeded)

        let criteria = await taskStore.task(id: task.id)?.acceptanceCriteria ?? []
        #expect(criteria.count == 2)
        #expect(criteria[0].id == original.id, "unchanged name keeps the criterion's identity")
        #expect(criteria[0].origin == .user)
        #expect(criteria[1].origin == .smith)
        #expect(criteria[1].waivable)
        #expect(criteria[1].validationPrompt == "judge the new requirement")

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
                        "criteria": .array([.dictionary(["name": .string("fixed criterion"), "validation_prompt": .string("judge the fixed criterion")])])],
            context: context
        )
        #expect(onFailed.succeeded, "a failed task's criteria must be editable so it can be corrected and re-run")

        // Completed task: result was accepted and delivered — closed to criteria edits.
        let completed = await taskStore.addTask(title: "c", description: "d")
        await taskStore.setResult(id: completed.id, result: "done", commentary: nil)
        await taskStore.updateStatus(id: completed.id, status: .completed)
        let onCompleted = try await tool.execute(
            arguments: ["task_id": .string(completed.id.uuidString),
                        "criteria": .array([.dictionary(["name": .string("too late"), "validation_prompt": .string("judge it")])])],
            context: context
        )
        #expect(!onCompleted.succeeded)
        #expect(onCompleted.output.contains("completed"))
    }

    @Test("set_acceptance_criteria requires a validation prompt")
    func setCriteriaRequiresValidationPrompt() async throws {
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
                "criteria": .array([.dictionary(["name": .string("c")])])
            ],
            context: context
        )
        #expect(!result.succeeded)
        #expect(result.output.contains("validation_prompt"))
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
                "criteria": .array([.dictionary(["name": .string("c"), "validation_prompt": .string("judge it")])])
            ],
            context: context
        )
        #expect(!result.succeeded)
    }

    @Test("set_acceptance_criteria stores task-scoped validation and enumeration prompts")
    func taskScopedPromptsOnCriterion() async throws {
        let taskStore = TaskStore()
        let task = await taskStore.addTask(title: "t", description: "d")
        let context = TestToolContext.make(agentRole: .smith, taskStore: taskStore, loadEvaluatorRegistry: makeSeededRegistryLoader())
        let result = try await SetAcceptanceCriteriaTool().execute(
            arguments: [
                "task_id": .string(task.id.uuidString),
                "criteria": .array([
                    .dictionary([
                        "name": .string("French summary"),
                        "validation_prompt": .string("Verify the supplied item preserves the English source meaning in French."),
                        "input_enumerator_prompt": .string("Return a JSON array of strings naming every French output file.")
                    ])
                ])
            ],
            context: context
        )
        #expect(result.succeeded)

        let criterion = await taskStore.task(id: task.id)?.acceptanceCriteria.first
        #expect(criterion?.name == "French summary")
        #expect(criterion?.validationPrompt.contains("preserves") == true)
        #expect(criterion?.inputEnumeratorPrompt?.contains("JSON array") == true)
        #expect(criterion?.validator == nil)
    }

    @Test("create_task accepts the task-scoped prompt contract")
    func createTaskObjectCriteria() async throws {
        let taskStore = TaskStore()
        let context = TestToolContext.make(agentRole: .smith, taskStore: taskStore)
        let result = try await CreateTaskTool().execute(
            arguments: [
                "title": .string("Prompt criteria task"),
                "description": .string("d"),
                "acceptance_criteria": .array([
                    .dictionary([
                        "name": .string("fancy criterion"),
                        "validation_prompt": .string("Judge fancily."),
                        "input_enumerator_prompt": .string("Return [\"one\", \"two\"]."),
                        "waivable": .bool(true),
                    ])
                ])
            ],
            context: context
        )
        #expect(result.succeeded)
        let criteria = await taskStore.allTasks().first?.acceptanceCriteria ?? []
        #expect(criteria.count == 1)
        #expect(criteria[0].validationPrompt == "Judge fancily.")
        #expect(criteria[0].inputEnumeratorPrompt != nil)
        #expect(criteria[0].waivable)
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
                    .dictionary(["name": .string("c")])
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
        let criterion = AcceptanceCriterion(name: "the validator got this wrong", origin: .user)
        await taskStore.setAcceptanceCriteria(id: task.id, criteria: [criterion])
        await taskStore.setResult(id: task.id, result: "correct work", commentary: nil, attachments: [])
        _ = await taskStore.beginValidationRound(id: task.id)
        await taskStore.recordCriterionVerdicts(id: task.id, records: [
            CriterionVerdictRecord(criterionID: criterion.id, verdict: .rejected(reason: "wrongly rejected"), validatorName: "default", validatorHash: "x", round: 1)
        ], judgedAgainst: [criterion])
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

    @Test("Smith exposes task-scoped prompts and no validator registry tools")
    func smithValidatorSurface() {
        let names = Set(SmithBehavior.tools().map(\.name))
        #expect(names.contains("set_acceptance_criteria"))
        #expect(!names.contains("define_validator"))
        #expect(!names.contains("list_validators"))
    }

    @Test("get_task_details includes validation prompts and scheduling metadata, not summary")
    func getTaskDetailsRendersValidationContract() async throws {
        let taskStore = TaskStore()
        let scheduledRunAt = Date().addingTimeInterval(3_600)
        let task = await taskStore.addTask(
            title: "Scheduled template",
            description: "Run this later",
            scheduledRunAt: scheduledRunAt,
            isTemplate: true
        )
        await taskStore.setAcceptanceCriteria(id: task.id, criteria: [
            AcceptanceCriterion(
                name: "Files checked",
                validationPrompt: "Validate every provided file path.",
                inputEnumeratorPrompt: "Return a JSON array of file paths.",
                origin: .smith
            )
        ])
        await taskStore.setSummary(id: task.id, summary: "This should not be returned.")
        await taskStore.setResult(id: task.id, result: "Done", commentary: nil)

        let context = TestToolContext.make(agentRole: .smith, taskStore: taskStore)
        let result = try await GetTaskDetailsTool().execute(
            arguments: ["task_ids": .array([.string(task.id.uuidString)])],
            context: context
        )

        #expect(result.succeeded)
        #expect(result.output.contains("isTemplate: true"))
        #expect(result.output.contains("isScheduled: true"))
        #expect(result.output.contains("scheduledRunAt:"))
        #expect(result.output.contains("hasParentTemplate: false"))
        #expect(result.output.contains("Validation prompt:\nValidate every provided file path."))
        #expect(result.output.contains("Input enumerator prompt:\nReturn a JSON array of file paths."))
        #expect(!result.output.contains("Summary:"))
        #expect(!result.output.contains("This should not be returned."))
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
                "acceptance_criteria": .array([
                    .dictionary(["name": .string("Report exists"), "validation_prompt": .string("Verify the report exists.")]),
                    .dictionary(["name": .string("Three vendors"), "validation_prompt": .string("Verify the report names three vendors.")])
                ]),
                "steps": .array([.string("research vendors"), .string("write report")])
            ],
            context: context
        )
        #expect(result.succeeded)

        let task = await taskStore.allTasks().first
        #expect(task?.acceptanceCriteria.map(\.name) == ["Report exists", "Three vendors"])
        #expect(task?.acceptanceCriteria.allSatisfy { $0.origin == .smith } == true)
        #expect(task?.steps.map(\.text) == ["research vendors", "write report"])
        #expect(task?.steps.allSatisfy { $0.origin == .smith } == true)
    }
}
