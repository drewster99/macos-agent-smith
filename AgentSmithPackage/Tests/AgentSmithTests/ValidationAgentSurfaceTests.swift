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
        EvaluatorDefaults.seed(into: directory)
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
                    .dictionary(["text": .string("brand new"), "waivable": .bool(true), "validator": .string("default-acceptance")])
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
        #expect(criteria[1].validator == .registry("default-acceptance"))

        let posted = await channel.allMessages()
        #expect(posted.contains { if case .string("criteria_updated") = $0.metadata?["messageKind"] { return true }; return false })
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
                "criteria": .array([.dictionary(["text": .string("c"), "validator": .string("nope")])])
            ],
            context: context
        )
        #expect(!result.succeeded)
        #expect(result.output.contains("default-acceptance"), "the failure must teach the available names")
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
        #expect(listed.output.contains("default-acceptance"))

        let unconfigured = TestToolContext.make(agentRole: .smith)
        let failed = try await ListValidatorsTool().execute(arguments: [:], context: unconfigured)
        #expect(!failed.succeeded)
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
