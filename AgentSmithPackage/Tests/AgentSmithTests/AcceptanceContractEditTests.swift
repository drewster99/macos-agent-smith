import Foundation
import Testing
@testable import AgentSmithKit

/// The acceptance contract's single writer (`TaskStore.editAcceptanceContract`): criteria and the
/// user sign-off gate land together or not at all, the gate reaches library templates and their
/// instances, and every real gate change is logged with its author.
@Suite("Acceptance contract edits")
struct AcceptanceContractEditTests {

    private func gate(_ on: Bool, by author: TaskAuthorship = .smith) -> UserAcceptanceGateChange {
        UserAcceptanceGateChange(requiresUserAcceptance: on, author: author)
    }

    /// A task with one criterion that has been judged (ACCEPT) — so it carries validation evidence.
    private func validatedTask(_ store: TaskStore) async throws -> (AgentTask, AcceptanceCriterion) {
        let task = await store.addTask(title: "t", description: "d")
        let criterion = AcceptanceCriterion(name: "works", validationPrompt: "it works", origin: .user)
        #expect(await store.setAcceptanceCriteria(id: task.id, criteria: [criterion]) == nil)
        let token = try #require(await store.beginValidationRound(id: task.id))
        _ = await store.recordCriterionVerdicts(id: task.id, records: [
            CriterionVerdictRecord(criterionID: criterion.id, verdict: .accepted, validatorName: "default", validatorHash: "h", round: token.round)
        ], judgedAgainst: [criterion], judgedInRound: token)
        return (try #require(await store.task(id: task.id)), criterion)
    }

    // MARK: - Atomicity

    @Test("A refused replace writes nothing — not even the gate it rode with")
    func refusedReplaceWritesNothing() async throws {
        let store = TaskStore()
        let (task, _) = try await validatedTask(store)
        let replacement = [AcceptanceCriterion(name: "different", validationPrompt: "p", origin: .smith)]
        let problem = await store.editAcceptanceContract(id: task.id, AcceptanceContractEdit(criteria: .replace(replacement), userAcceptanceGate: gate(true)))
        #expect(problem != nil)
        let after = try #require(await store.task(id: task.id))
        #expect(!after.requiresUserAcceptance)
        #expect(after.acceptanceCriteria == task.acceptanceCriteria)
        #expect(after.validation?.contractVersion == task.validation?.contractVersion)
    }

    @Test("A refused action batch writes nothing — not even the gate it rode with")
    func refusedActionsWriteNothing() async throws {
        let store = TaskStore()
        let (task, _) = try await validatedTask(store)
        let edit = AcceptanceContractEdit(criteria: .apply([.delete(criterionID: UUID())]), userAcceptanceGate: gate(true))
        #expect(await store.editAcceptanceContract(id: task.id, edit) != nil)
        #expect(await store.task(id: task.id)?.requiresUserAcceptance == false)
    }

    @Test("A template placeholder problem refuses the whole edit")
    func templatePlaceholderRefusesWholeEdit() async throws {
        let store = TaskStore()
        let template = await store.addTask(title: "Template", description: "d", isTemplate: true,
                                           templateInputDefinitions: [TemplateInputDefinition(name: "app_name", description: "the app", required: true)])
        let bad = AcceptanceCriterion(name: "uses {{undefined_input}}", validationPrompt: "check {{undefined_input}}", origin: .smith)
        #expect(await store.editAcceptanceContract(id: template.id, AcceptanceContractEdit(criteria: .replace([bad]), userAcceptanceGate: gate(true))) != nil)
        #expect(await store.taskOrLibraryTemplate(id: template.id)?.requiresUserAcceptance == false)
    }

    @Test("A gate-only edit leaves the validation ledger and contract version alone")
    func gateOnlyEditLeavesLedgerAlone() async throws {
        let store = TaskStore()
        let (task, criterion) = try await validatedTask(store)
        #expect(await store.editAcceptanceContract(id: task.id, AcceptanceContractEdit(userAcceptanceGate: gate(true))) == nil)
        let after = try #require(await store.task(id: task.id))
        #expect(after.requiresUserAcceptance)
        #expect(after.validation?.contractVersion == task.validation?.contractVersion)
        #expect(after.validation?.round == task.validation?.round)
        #expect(after.validation?.settledCriterionIDs(in: after.acceptanceCriteria) == [criterion.id])
    }

    @Test("A combined edit lands both parts")
    func combinedEditLandsBoth() async throws {
        let store = TaskStore()
        let (task, criterion) = try await validatedTask(store)
        let edit = AcceptanceContractEdit(
            criteria: .apply([.update(criterionID: criterion.id, name: "works", validationPrompt: "it really works", inputEnumeratorPrompt: nil, waivable: false)]),
            userAcceptanceGate: gate(true))
        #expect(await store.editAcceptanceContract(id: task.id, edit) == nil)
        let after = try #require(await store.task(id: task.id))
        #expect(after.requiresUserAcceptance)
        #expect(after.acceptanceCriteria.first?.validationPrompt == "it really works")
        #expect(after.validation?.contractVersion == (task.validation?.contractVersion ?? 0) + 1)
    }

    @Test("An empty edit, a running task, and the worker are all refused")
    func refusals() async throws {
        let store = TaskStore()
        let task = await store.addTask(title: "t", description: "d")
        #expect(await store.editAcceptanceContract(id: task.id, AcceptanceContractEdit()) != nil)
        #expect(await store.setRequiresUserAcceptance(id: task.id, value: true, by: .worker) != nil,
                "the judged worker never holds the pen on its own acceptance contract")
        await store.setResult(id: task.id, result: "r", commentary: nil, attachments: [])
        #expect(await store.driveStatus(id: task.id, to: .validating))
        let problem = await store.setRequiresUserAcceptance(id: task.id, value: true, by: .smith)
        #expect(problem?.contains("acceptance contract") == true)
        #expect(await store.task(id: task.id)?.requiresUserAcceptance == false)
    }

    // MARK: - Parked tasks

    @Test("Turning the gate off is refused on a sign-off park, allowed on a validator-error park")
    func gateOffWhileParked() async throws {
        let store = TaskStore()
        let (signOff, _) = try await validatedTask(store)
        #expect(await store.setRequiresUserAcceptance(id: signOff.id, value: true, by: .smith) == nil)
        await store.setResult(id: signOff.id, result: "r", commentary: nil, attachments: [])
        #expect(await store.driveStatus(id: signOff.id, to: .validating))
        #expect(await store.updateStatus(id: signOff.id, to: .awaitingReview, ifCurrentlyIn: [.validating],
                                         cause: .userAcceptanceRequested(validationWasRun: true)))
        let refused = await store.setRequiresUserAcceptance(id: signOff.id, value: false, by: .smith)
        #expect(refused?.contains("respond_to_user_acceptance") == true)
        #expect(await store.task(id: signOff.id)?.requiresUserAcceptance == true)
        #expect(await store.setRequiresUserAcceptance(id: signOff.id, value: true, by: .smith) == nil, "turning it on is a no-op")

        let escalated = await store.addTask(title: "e", description: "d", requiresUserAcceptance: true)
        await store.setResult(id: escalated.id, result: "r", commentary: nil, attachments: [])
        #expect(await store.driveStatus(id: escalated.id, to: .awaitingReview), "the helper parks as a validator error")
        #expect(await store.setRequiresUserAcceptance(id: escalated.id, value: false, by: .user) == nil)
    }

    // MARK: - Creation, templates, history

    @Test("The gate can be set at creation, on a library template, and is inherited by its instances")
    func gateReachesTemplatesAndInstances() async throws {
        let created = await TaskStore().addTask(title: "t", description: "d", requiresUserAcceptance: true)
        #expect(created.requiresUserAcceptance)

        let library = TemplateLibraryStore()
        let store = TaskStore(sessionID: UUID(), templateLibrary: library)
        let template = await store.addTask(title: "Nightly", description: "d", isTemplate: true)
        #expect(await store.task(id: template.id) == nil, "a new template lives in the library")
        #expect(await store.setRequiresUserAcceptance(id: template.id, value: true, by: .smith) == nil,
                "used to fail with 'No task with id' — the setter only looked in the session store")
        #expect(await library.template(id: template.id)?.requiresUserAcceptance == true)
        guard case .success(let instance) = await store.instantiateTemplate(templateID: template.id, inputValues: [:]) else {
            Issue.record("instantiation failed")
            return
        }
        #expect(instance.requiresUserAcceptance)

        let ungatedTemplate = await store.addTask(title: "Weekly", description: "d", isTemplate: true)
        guard case .success(let ungatedInstance) = await store.instantiateTemplate(templateID: ungatedTemplate.id, inputValues: [:]) else {
            Issue.record("instantiation failed")
            return
        }
        #expect(!ungatedInstance.requiresUserAcceptance)
    }

    @Test("Every real gate change is logged with its author; a no-op logs nothing")
    func gateChangesAreLogged() async throws {
        let store = TaskStore()
        let task = await store.addTask(title: "t", description: "d")
        #expect(await store.setRequiresUserAcceptance(id: task.id, value: true, by: .smith) == nil)
        #expect(await store.setRequiresUserAcceptance(id: task.id, value: true, by: .smith) == nil)
        #expect(await store.setRequiresUserAcceptance(id: task.id, value: false, by: .user) == nil)
        let messages = try #require(await store.task(id: task.id)).updates.map(\.message)
        #expect(messages.count == 2)
        #expect(messages.first?.contains("ON by Smith") == true)
        #expect(messages.last?.contains("OFF by the user") == true)
    }

    // MARK: - Tools

    @Test("set_acceptance_criteria: a refused call leaves the gate untouched")
    func toolRefusalLeavesGate() async throws {
        let store = TaskStore()
        let task = await store.addTask(title: "t", description: "d")
        let context = TestToolContext.make(agentRole: .smith, taskStore: store)
        let both = try await SetAcceptanceCriteriaTool().execute(arguments: [
            "task_id": .string(task.id.uuidString),
            "requires_user_acceptance": .bool(true),
            "criteria": .array([.dictionary(["name": .string("a"), "validation_prompt": .string("p")])]),
            "actions": .array([.dictionary(["action": .string("add"), "name": .string("b"), "validation_prompt": .string("q")])])
        ], context: context)
        #expect(!both.succeeded)
        let malformed = try await SetAcceptanceCriteriaTool().execute(arguments: [
            "task_id": .string(task.id.uuidString),
            "requires_user_acceptance": .bool(true),
            "criteria": .array([.dictionary(["name": .string("no prompt")])])
        ], context: context)
        #expect(!malformed.succeeded)
        #expect(await store.task(id: task.id)?.requiresUserAcceptance == false)
    }

    @Test("set_acceptance_criteria: the gate rides with criteria and says so")
    func toolReportsGate() async throws {
        let store = TaskStore()
        let task = await store.addTask(title: "t", description: "d")
        let context = TestToolContext.make(agentRole: .smith, taskStore: store)
        let result = try await SetAcceptanceCriteriaTool().execute(arguments: [
            "task_id": .string(task.id.uuidString),
            "requires_user_acceptance": .bool(true),
            "criteria": .array([.dictionary(["name": .string("a"), "validation_prompt": .string("p")])])
        ], context: context)
        #expect(result.succeeded)
        #expect(result.output.contains("USER's explicit acceptance"))
        let stored = try #require(await store.task(id: task.id))
        #expect(stored.requiresUserAcceptance)
        #expect(stored.acceptanceCriteria.count == 1)
    }

    @Test("create_task sets the gate at creation; absent means off")
    func createTaskSetsGate() async throws {
        let store = TaskStore()
        let context = TestToolContext.make(agentRole: .smith, taskStore: store)
        let gated = try await CreateTaskTool().execute(arguments: [
            "title": .string("Gated"), "description": .string("d"), "requires_user_acceptance": .bool(true)
        ], context: context)
        #expect(gated.succeeded)
        #expect(gated.output.contains("sign-off"))
        let plain = try await CreateTaskTool().execute(arguments: [
            "title": .string("Plain"), "description": .string("d")
        ], context: context)
        #expect(plain.succeeded)
        let tasks = await store.allTasks()
        #expect(tasks.first { $0.title == "Gated" }?.requiresUserAcceptance == true)
        #expect(tasks.first { $0.title == "Plain" }?.requiresUserAcceptance == false)
    }

    /// A gate that can't be changed once the task starts must not be silently read as "off" from a
    /// value that isn't a bool — the task would start ungated with no way back.
    @Test("create_task refuses a non-boolean gate or template flag and creates nothing")
    func createTaskRefusesMalformedSwitches() async throws {
        let store = TaskStore()
        let context = TestToolContext.make(agentRole: .smith, taskStore: store)
        let badGate = try await CreateTaskTool().execute(arguments: [
            "title": .string("Bad gate"), "description": .string("d"), "requires_user_acceptance": .string("yes")
        ], context: context)
        #expect(!badGate.succeeded)
        let badTemplate = try await CreateTaskTool().execute(arguments: [
            "title": .string("Bad template"), "description": .string("d"), "is_template": .int(1)
        ], context: context)
        #expect(!badTemplate.succeeded)
        let quoted = try await CreateTaskTool().execute(arguments: [
            "title": .string("Quoted"), "description": .string("d"), "requires_user_acceptance": .string("true")
        ], context: context)
        #expect(quoted.succeeded)
        let tasks = await store.allTasks()
        #expect(!tasks.contains { $0.title == "Bad gate" || $0.title == "Bad template" })
        #expect(tasks.first { $0.title == "Quoted" }?.requiresUserAcceptance == true)
    }

    @Test("get_task_details shows the gate, and the park reason only while parked")
    func taskDetailsShowGate() async throws {
        let store = TaskStore()
        let task = await store.addTask(title: "t", description: "d", requiresUserAcceptance: true)
        let context = TestToolContext.make(agentRole: .smith, taskStore: store)
        let arguments: [String: AnyCodable] = ["task_ids": .array([.string(task.id.uuidString)])]
        let pending = try await GetTaskDetailsTool().execute(arguments: arguments, context: context)
        #expect(pending.output.contains("requiresUserAcceptance: true"))
        #expect(!pending.output.contains("awaitingReviewReason"))
        await store.setResult(id: task.id, result: "r", commentary: nil, attachments: [])
        #expect(await store.driveStatus(id: task.id, to: .validating))
        #expect(await store.updateStatus(id: task.id, to: .awaitingReview, ifCurrentlyIn: [.validating],
                                         cause: .userAcceptanceRequested(validationWasRun: false)))
        let parked = try await GetTaskDetailsTool().execute(arguments: arguments, context: context)
        #expect(parked.output.contains("awaitingReviewReason: userAcceptanceRequestedValidationSkipped"))
    }
}
