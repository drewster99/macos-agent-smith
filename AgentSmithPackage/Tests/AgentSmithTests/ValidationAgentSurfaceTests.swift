import Foundation
import Testing
@testable import AgentSmithKit

/// The agent-facing surface of the validation system: Brown's `manage_steps`, Smith's
/// acceptance-criterion authoring, and `create_task`'s criteria/steps seeding.

@Suite("Validation agent surface")
struct ValidationAgentSurfaceTests {

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

        // `set_status` no longer accepts `removed` — the tool must point at `delete` instead.
        let removedViaStatus = try await tool.execute(
            arguments: ["action": .string("set_status"), "step_id": .string(steps[1].id.uuidString), "status": .string("removed"), "note": .string("superseded by first")],
            context: context
        )
        #expect(!removedViaStatus.succeeded)
        #expect(removedViaStatus.output.contains("delete"))

        // Removal with a note tombstones: hidden from the active list, immutable after.
        let removed = try await tool.execute(
            arguments: ["action": .string("delete"), "step_id": .string(steps[1].id.uuidString), "note": .string("superseded by first")],
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

    @Test("manage_steps is available to Brown and Smith, not the silent roles")
    func manageStepsAvailability() {
        let tool = ManageStepsTool()
        #expect(tool.isAvailable(in: ToolAvailabilityContext(agentRole: .brown)))
        #expect(tool.isAvailable(in: ToolAvailabilityContext(agentRole: .smith)))
        #expect(!tool.isAvailable(in: ToolAvailabilityContext(agentRole: .securityAgent)))
        #expect(!tool.isAvailable(in: ToolAvailabilityContext(agentRole: .summarizer)))
    }

    @Test("manage_steps (Smith): edits a task's plan by task_id and authors steps as Smith")
    func manageStepsSmithEditsByTaskID() async throws {
        let taskStore = TaskStore()
        let task = await taskStore.addTask(title: "template", description: "d")
        // Smith is not assigned to the task — it names it explicitly.
        let context = TestToolContext.make(agentRole: .smith, taskStore: taskStore)
        let tool = ManageStepsTool()

        let added = try await tool.execute(
            arguments: [
                "action": .string("add"),
                "task_id": .string(task.id.uuidString),
                "texts": .array([.string("clone the repo"), .string("run the build")])
            ],
            context: context
        )
        #expect(added.succeeded)

        let steps = await taskStore.task(id: task.id)?.steps ?? []
        #expect(steps.count == 2)
        #expect(steps.allSatisfy { $0.origin == .smith }, "Smith-added steps are authored by Smith, not the worker")
    }

    @Test("purge is Smith-only and absent from the worker's schema and description")
    func purgeIsOrchestratorOnly() async throws {
        let tool = ManageStepsTool()

        func actionEnum(for role: AgentRole) -> [String] {
            guard case .dictionary(let properties)? = tool.parameters(for: role)["properties"],
                  case .dictionary(let action)? = properties["action"],
                  case .array(let values)? = action["enum"] else { return [] }
            return values.compactMap { if case .string(let s) = $0 { return s }; return nil }
        }
        #expect(actionEnum(for: .smith).contains("purge"))
        #expect(!actionEnum(for: .brown).contains("purge"), "the worker must not be offered a traceless delete")
        #expect(tool.description(for: .smith).contains("purge"))
        #expect(!tool.description(for: .brown).contains("purge"))

        // Even if the worker guesses the action name, the runtime refuses it.
        let taskStore = TaskStore()
        let agentID = UUID()
        let task = await taskStore.addTask(title: "t", description: "d")
        await taskStore.assignAgent(taskID: task.id, agentID: agentID)
        await taskStore.setSteps(id: task.id, steps: [TaskStep(text: "a", origin: .smith)])
        let stepID = await taskStore.task(id: task.id)!.steps[0].id

        let brownAttempt = try await tool.execute(
            arguments: ["action": .string("purge"), "step_id": .string(stepID.uuidString)],
            context: TestToolContext.make(agentID: agentID, agentRole: .brown, taskStore: taskStore)
        )
        #expect(!brownAttempt.succeeded)
        #expect(brownAttempt.output.contains("delete"), "the refusal should point the worker at the honest verb")
        #expect(await taskStore.task(id: task.id)?.steps.count == 1)
    }

    @Test("manage_steps (Smith): purge hard-deletes on an unrun plan, and is refused once the task has history")
    func purgeGating() async throws {
        let tool = ManageStepsTool()

        // A template: always purgeable — its steps are pure authoring.
        let templateStore = TaskStore()
        let template = await templateStore.addTask(title: "tpl", description: "d", isTemplate: true)
        await templateStore.setSteps(id: template.id, steps: ["a", "b"].map { TaskStep(text: $0, origin: .smith) })
        let templateStepID = await templateStore.task(id: template.id)!.steps[0].id
        let purged = try await tool.execute(
            arguments: ["action": .string("purge"), "task_id": .string(template.id.uuidString), "step_id": .string(templateStepID.uuidString)],
            context: TestToolContext.make(agentRole: .smith, taskStore: templateStore)
        )
        #expect(purged.succeeded)
        let templateSteps = await templateStore.task(id: template.id)!.steps
        #expect(templateSteps.map(\.text) == ["b"], "purge leaves no row at all — not even a tombstone")

        // A task that has already run: refused, and the plan is untouched.
        let ranStore = TaskStore()
        let ran = await ranStore.addTask(title: "t", description: "d")
        await ranStore.setSteps(id: ran.id, steps: ["a", "b"].map { TaskStep(text: $0, origin: .smith) })
        await ranStore.updateStatus(id: ran.id, status: .running)
        await ranStore.updateStatus(id: ran.id, status: .failed)
        #expect(await ranStore.task(id: ran.id)?.startedAt != nil, "precondition: the task recorded a start")
        let ranStepID = await ranStore.task(id: ran.id)!.steps[0].id
        let refused = try await tool.execute(
            arguments: ["action": .string("purge"), "task_id": .string(ran.id.uuidString), "step_id": .string(ranStepID.uuidString)],
            context: TestToolContext.make(agentRole: .smith, taskStore: ranStore)
        )
        #expect(!refused.succeeded)
        #expect(refused.output.contains("delete"))
        #expect(await ranStore.task(id: ran.id)?.steps.count == 2)
    }

    @Test("manage_steps (Smith): requires task_id — it has no task of its own")
    func manageStepsSmithRequiresTaskID() async throws {
        let taskStore = TaskStore()
        _ = await taskStore.addTask(title: "t", description: "d")
        let context = TestToolContext.make(agentRole: .smith, taskStore: taskStore)

        let result = try await ManageStepsTool().execute(
            arguments: ["action": .string("add"), "text": .string("orphan step")],
            context: context
        )
        #expect(!result.succeeded)
        #expect(result.output.contains("task_id"))
    }

    @Test("manage_steps (Smith): refuses a task with a live worker (running)")
    func manageStepsSmithBlockedWhileRunning() async throws {
        let taskStore = TaskStore()
        let task = await taskStore.addTask(title: "t", description: "d")
        await taskStore.updateStatus(id: task.id, status: .running)
        let context = TestToolContext.make(agentRole: .smith, taskStore: taskStore)

        let result = try await ManageStepsTool().execute(
            arguments: [
                "action": .string("add"),
                "task_id": .string(task.id.uuidString),
                "text": .string("meddling with a running task")
            ],
            context: context
        )
        #expect(!result.succeeded)
        #expect((await taskStore.task(id: task.id)?.steps ?? []).isEmpty, "no step was added to the running task")
    }

    @Test("manage_steps (Smith): unknown task_id fails cleanly")
    func manageStepsSmithUnknownTask() async throws {
        let taskStore = TaskStore()
        let context = TestToolContext.make(agentRole: .smith, taskStore: taskStore)

        let result = try await ManageStepsTool().execute(
            arguments: [
                "action": .string("list"),
                "task_id": .string(UUID().uuidString)
            ],
            context: context
        )
        #expect(!result.succeeded)
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
            taskStore: taskStore
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

    @Test("set_acceptance_criteria: the two modes are mutually exclusive, and `actions` edits by id")
    func setCriteriaActionsMode() async throws {
        let taskStore = TaskStore()
        let task = await taskStore.addTask(title: "t", description: "d")
        let existing = AcceptanceCriterion(name: "keep me", validationPrompt: "judge it", origin: .smith)
        await taskStore.setAcceptanceCriteria(id: task.id, criteria: [existing])
        let context = TestToolContext.make(agentRole: .smith, taskStore: taskStore)
        let tool = SetAcceptanceCriteriaTool()

        let neither = try await tool.execute(arguments: ["task_id": .string(task.id.uuidString)], context: context)
        #expect(!neither.succeeded, "one of the two modes must be chosen")

        let both = try await tool.execute(
            arguments: [
                "task_id": .string(task.id.uuidString),
                "criteria": .array([.dictionary(["name": .string("x"), "validation_prompt": .string("p")])]),
                "actions": .array([.dictionary(["action": .string("delete"), "criterion_id": .string(existing.id.uuidString)])])
            ],
            context: context
        )
        #expect(!both.succeeded, "replace-all and per-criterion edits are not combinable")
        #expect(await taskStore.task(id: task.id)?.acceptanceCriteria.count == 1, "a refused call changes nothing")

        // update by id, plus an add, in one batch.
        let edited = try await tool.execute(
            arguments: [
                "task_id": .string(task.id.uuidString),
                "actions": .array([
                    .dictionary([
                        "action": .string("update"),
                        "criterion_id": .string(existing.id.uuidString),
                        "name": .string("renamed"),
                        "validation_prompt": .string("judge it")
                    ]),
                    .dictionary([
                        "action": .string("add"),
                        "name": .string("added"),
                        "validation_prompt": .string("judge the new one"),
                        "waivable": .bool(true)
                    ])
                ])
            ],
            context: context
        )
        #expect(edited.succeeded)
        let criteria = await taskStore.task(id: task.id)?.acceptanceCriteria ?? []
        #expect(criteria.map(\.name) == ["renamed", "added"])
        #expect(criteria[0].id == existing.id, "update targets by id, so identity survives")
        #expect(criteria[1].waivable)

        // update/delete without a criterion_id can't name anything, and must say so.
        let idless = try await tool.execute(
            arguments: [
                "task_id": .string(task.id.uuidString),
                "actions": .array([.dictionary(["action": .string("delete")])])
            ],
            context: context
        )
        #expect(!idless.succeeded)
    }

    @Test("set_acceptance_criteria is refused while a validator is consuming the contract")
    func setCriteriaGatedWhileValidating() async throws {
        let taskStore = TaskStore()
        let task = await taskStore.addTask(title: "t", description: "d")
        let existing = AcceptanceCriterion(name: "A", validationPrompt: "judge A", origin: .smith)
        await taskStore.setAcceptanceCriteria(id: task.id, criteria: [existing])
        await taskStore.setResult(id: task.id, result: "done", commentary: nil, attachments: [])
        await taskStore.updateStatus(id: task.id, status: .validating)
        let context = TestToolContext.make(agentRole: .smith, taskStore: taskStore)
        let tool = SetAcceptanceCriteriaTool()

        // Both modes are refused: changing the rules mid-judgment is the race the gate prevents.
        let replaced = try await tool.execute(
            arguments: [
                "task_id": .string(task.id.uuidString),
                "criteria": .array([.dictionary(["name": .string("A"), "validation_prompt": .string("judge A harder")])])
            ],
            context: context
        )
        #expect(!replaced.succeeded)
        let edited = try await tool.execute(
            arguments: [
                "task_id": .string(task.id.uuidString),
                "actions": .array([.dictionary([
                    "action": .string("update"),
                    "criterion_id": .string(existing.id.uuidString),
                    "name": .string("A"),
                    "validation_prompt": .string("judge A harder")
                ])])
            ],
            context: context
        )
        #expect(!edited.succeeded)
        #expect(await taskStore.task(id: task.id)?.acceptanceCriteria[0].validationPrompt == "judge A",
                "the contract a validator is judging against is untouched")

        // Back out of validation and the same edit lands — the gate is about the live validator,
        // not about the task having been judged.
        await taskStore.updateStatus(id: task.id, status: .awaitingReview)
        let afterPark = try await tool.execute(
            arguments: [
                "task_id": .string(task.id.uuidString),
                "actions": .array([.dictionary([
                    "action": .string("update"),
                    "criterion_id": .string(existing.id.uuidString),
                    "name": .string("A"),
                    "validation_prompt": .string("judge A harder")
                ])])
            ],
            context: context
        )
        #expect(afterPark.succeeded, "fixing a wrong criterion is how an escalation gets resolved")
    }

    @Test("set_acceptance_criteria works on a FAILED task (recovery) but not a COMPLETED one")
    func setCriteriaAllowedOnFailedBlockedOnCompleted() async throws {
        let taskStore = TaskStore()
        let context = TestToolContext.make(
            agentRole: .smith,
            taskStore: taskStore
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
            taskStore: taskStore
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
        let context = TestToolContext.make(agentRole: .smith, taskStore: taskStore)
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
        #expect(criterion?.usesDefaultValidator == false, "an authored prompt means a custom validator, not the default")
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
        _ = await taskStore.setTemplateInputDefinitions(id: task.id, definitions: [
            TemplateInputDefinition(name: "target_app", description: "App name or bundle ID.", required: true)
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
        #expect(result.output.contains("Template input definitions:\n- target_app [required]: App name or bundle ID."))
        #expect(result.output.contains("Missing required template inputs: target_app"))
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
