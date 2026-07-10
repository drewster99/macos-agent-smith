import Foundation
import Testing
import SemanticSearch
@testable import AgentSmithKit

/// The `.validating` state machine end-to-end against mock providers: acceptance
/// completes tasks, rejection punch-lists return to the worker, errors and round
/// exhaustion escalate, and criterion-less tasks get the materialized default.

@Suite("Task validation coordinator", .serialized)
struct TaskValidationCoordinatorTests {

    /// Runtime whose summarizer mock (the default-acceptance model slot) answers each
    /// validation call with the next `verdictScript` entry, repeating the last when
    /// exhausted. Smith/Brown/Security mocks are present so worker respawn paths work.
    private func makeRuntime(verdictScript: [String]) -> (OrchestrationRuntime, URL) {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-smith-validation-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let evaluatorsDirectory = tmpRoot.appendingPathComponent("evaluators", isDirectory: true)

        let testConfiguration = ModelConfiguration(name: "test", providerID: "test", modelID: "test-model")
        let runtime = OrchestrationRuntime(
            providers: [
                .smith: MockLLMProvider(responses: [LLMResponse(text: "Standing by.")]),
                .brown: MockLLMProvider(responses: [LLMResponse(text: "Working.")]),
                .securityAgent: MockLLMProvider(responses: [LLMResponse(text: "SAFE")]),
                .summarizer: MockLLMProvider(responses: verdictScript.map { LLMResponse(text: $0) })
            ],
            configurations: [
                .smith: testConfiguration,
                .brown: testConfiguration,
                .securityAgent: testConfiguration,
                .summarizer: testConfiguration
            ],
            providerAPITypes: [:],
            agentTuning: [:],
            semanticSearchEngine: SemanticSearchEngine(),
            usageStore: UsageStore(persistence: PersistenceManager(testingRoot: tmpRoot)),
            autoAdvanceEnabled: false,
            autoRunInterruptedTasks: false,
            memoryStore: nil
        )
        return (runtime, evaluatorsDirectory)
    }

    /// Creates a task in `.validating` with a submitted result, as `task_complete`
    /// leaves it, ready for `startTaskValidation`.
    private func makeSubmittedTask(
        on runtime: OrchestrationRuntime,
        criteria: [AcceptanceCriterion] = []
    ) async -> AgentTask {
        let store = await runtime.taskStore
        let task = await store.addTask(title: "Validated task", description: "Do the thing properly.")
        if !criteria.isEmpty {
            await store.setAcceptanceCriteria(id: task.id, criteria: criteria)
        }
        await store.setResult(id: task.id, result: "The thing was done.", commentary: nil, attachments: [])
        await store.updateStatus(id: task.id, status: .validating)
        return await store.task(id: task.id) ?? task
    }

    private func waitForStatusChange(
        on runtime: OrchestrationRuntime,
        taskID: UUID,
        away from: AgentTask.Status,
        timeoutSeconds: Double = 15
    ) async -> AgentTask.Status? {
        let store = await runtime.taskStore
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let status = await store.task(id: taskID)?.status, status != from {
                return status
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return await store.task(id: taskID)?.status
    }

    @Test("All criteria accepted → task completes; the implicit criterion is materialized and its definition pinned")
    func acceptanceCompletesCriterionlessTask() async {
        let (runtime, directory) = makeRuntime(verdictScript: ["ACCEPT"])
        await runtime.setEvaluatorConfiguration(directory: directory)
        let task = await makeSubmittedTask(on: runtime)

        await runtime.startTaskValidation(taskID: task.id)
        let status = await waitForStatusChange(on: runtime, taskID: task.id, away: .validating)
        #expect(status == .completed)

        let final = await runtime.taskStore.task(id: task.id)
        #expect(final?.acceptanceCriteria.count == 1, "the implicit default criterion must be materialized")
        #expect(final?.acceptanceCriteria.first?.origin == .system)
        #expect(final?.validation?.verdictRecords.count == 1)
        #expect(final?.validation?.pinnedDefinitions["default-acceptance"] != nil, "the definition body must be pinned to the task")

        // The debugging transcript persists with the verdict: the rendered input the
        // validator saw and its raw output.
        let debugRecord = final?.validation?.verdictRecords.first
        #expect(debugRecord?.renderedInput?.contains("The thing was done.") == true, "the rendered input embeds the submitted result")
        #expect(debugRecord?.responseLog?.contains("ACCEPT") == true, "the raw validator output is preserved")
    }

    @Test("A rejection returns the task to the worker; resubmission re-validates only the unsettled criterion")
    func rejectionRoundTripsThroughWorker() async {
        // Round 1 judges A and B concurrently against a shared mock, so WHICH gets the
        // REJECT is racy — all assertions are order-agnostic. Round 2 re-judges only
        // the rejected one and accepts it.
        let (runtime, directory) = makeRuntime(verdictScript: [
            "ACCEPT",
            "REJECT: the log file was never written",
            "ACCEPT"
        ])
        await runtime.setEvaluatorConfiguration(directory: directory)
        await runtime.setToolSecurity(preflightScoping: false, perCallCheck: false, globalPolicy: [:])
        await runtime.start()
        let criteria = [
            AcceptanceCriterion(text: "A: code compiles", origin: .user),
            AcceptanceCriterion(text: "B: log file written", origin: .user)
        ]
        let task = await makeSubmittedTask(on: runtime, criteria: criteria)

        await runtime.startTaskValidation(taskID: task.id)
        let afterRound1 = await waitForStatusChange(on: runtime, taskID: task.id, away: .validating)
        #expect(afterRound1 == .running, "a rejection must return the task to the worker, not escalate")

        let midTask = await runtime.taskStore.task(id: task.id)
        #expect(midTask?.validation?.settledCriterionIDs().count == 1, "the accepted criterion is sticky")
        #expect(midTask?.result == nil, "the result is cleared for resubmission")

        // The worker "fixes and resubmits".
        await runtime.taskStore.setResult(id: task.id, result: "Now with the log file.", commentary: nil, attachments: [])
        await runtime.taskStore.updateStatus(id: task.id, status: .validating)
        await runtime.startTaskValidation(taskID: task.id)
        let afterRound2 = await waitForStatusChange(on: runtime, taskID: task.id, away: .validating)
        #expect(afterRound2 == .completed)

        // Exactly 3 verdicts total proves the settled criterion was NOT re-judged.
        let final = await runtime.taskStore.task(id: task.id)
        #expect(final?.validation?.verdictRecords.count == 3)

        await runtime.stopAll()
    }

    @Test("Persistent validator errors escalate to awaitingReview, never fake a verdict")
    func errorsEscalate() async {
        // Unparseable responses exhaust the runner's parse retries → ERROR, retried once
        // by the coordinator, then escalation.
        let (runtime, directory) = makeRuntime(verdictScript: ["I cannot decide, sorry!"])
        await runtime.setEvaluatorConfiguration(directory: directory)
        let task = await makeSubmittedTask(on: runtime)

        await runtime.startTaskValidation(taskID: task.id)
        let status = await waitForStatusChange(on: runtime, taskID: task.id, away: .validating)
        #expect(status == .awaitingReview, "errors park for manual review — they are never rejections")
    }

    @Test("A WAIVE against a non-waivable criterion escalates as an error")
    func waiveOnNonWaivableEscalates() async {
        let (runtime, directory) = makeRuntime(verdictScript: ["WAIVE: does not apply here"])
        await runtime.setEvaluatorConfiguration(directory: directory)
        let criteria = [AcceptanceCriterion(text: "must always hold", waivable: false, origin: .user)]
        let task = await makeSubmittedTask(on: runtime, criteria: criteria)

        await runtime.startTaskValidation(taskID: task.id)
        let status = await waitForStatusChange(on: runtime, taskID: task.id, away: .validating)
        #expect(status == .awaitingReview)
    }

    @Test("A waivable criterion accepts a WAIVE and settles")
    func waivableWaives() async {
        let (runtime, directory) = makeRuntime(verdictScript: ["WAIVE: this task has no UI to screenshot"])
        await runtime.setEvaluatorConfiguration(directory: directory)
        let criteria = [AcceptanceCriterion(text: "screenshots attached", waivable: true, origin: .smith)]
        let task = await makeSubmittedTask(on: runtime, criteria: criteria)

        await runtime.startTaskValidation(taskID: task.id)
        let status = await waitForStatusChange(on: runtime, taskID: task.id, away: .validating)
        #expect(status == .completed)
    }

    @Test("Unconfigured validation escalates visibly instead of passing silently")
    func unconfiguredEscalates() async {
        let (runtime, _) = makeRuntime(verdictScript: ["ACCEPT"])
        // Deliberately NOT calling setEvaluatorConfiguration.
        let task = await makeSubmittedTask(on: runtime)

        await runtime.startTaskValidation(taskID: task.id)
        let status = await waitForStatusChange(on: runtime, taskID: task.id, away: .validating)
        #expect(status == .awaitingReview)
    }

    @Test("Round exhaustion escalates; a reset round budget lets a post-escalation resubmission validate again")
    func roundExhaustionEscalatesAndResetRestoresValidation() async {
        // One criterion rejected three straight rounds → escalation. After the budget
        // reset (review_work's reject path), a resubmission must get judged again
        // rather than insta-escalating on the stale counter.
        let (runtime, directory) = makeRuntime(verdictScript: [
            "REJECT: round 1 miss",
            "REJECT: round 2 miss",
            "REJECT: round 3 miss",
            "ACCEPT"
        ])
        await runtime.setEvaluatorConfiguration(directory: directory)
        await runtime.setToolSecurity(preflightScoping: false, perCallCheck: false, globalPolicy: [:])
        await runtime.start()
        let criteria = [AcceptanceCriterion(text: "the fix actually works", origin: .user)]
        let task = await makeSubmittedTask(on: runtime, criteria: criteria)
        let store = await runtime.taskStore

        await runtime.startTaskValidation(taskID: task.id)
        var status = await waitForStatusChange(on: runtime, taskID: task.id, away: .validating)
        #expect(status == .running, "round 1 rejection returns to the worker")

        for expectedOutcome in [AgentTask.Status.running, .awaitingReview] {
            await store.setResult(id: task.id, result: "another attempt", commentary: nil, attachments: [])
            await store.updateStatus(id: task.id, status: .validating)
            await runtime.startTaskValidation(taskID: task.id)
            status = await waitForStatusChange(on: runtime, taskID: task.id, away: .validating)
            #expect(status == expectedOutcome)
        }

        // The escalation must ALSO tell the worker to stand down — otherwise it never
        // learns the last round's outcome and flails (re-reasoning, request_help loops).
        let messages = await runtime.channel.allMessages()
        #expect(messages.contains { message in
            if case .string("validation_wait_notice") = message.metadata?["messageKind"] {
                return message.recipientID != nil
            }
            return false
        }, "the worker gets a private stand-down notice on escalation")

        // Smith review_work-rejects: fresh round budget, worker fixes, resubmits.
        await store.resetValidationRound(id: task.id)
        await store.setResult(id: task.id, result: "the real fix", commentary: nil, attachments: [])
        await store.updateStatus(id: task.id, status: .validating)
        await runtime.startTaskValidation(taskID: task.id)
        status = await waitForStatusChange(on: runtime, taskID: task.id, away: .validating)
        #expect(status == .completed, "after a reset, validation judges again instead of insta-escalating")

        await runtime.stopAll()
    }

    // MARK: - Built-in registry model + legacy migration

    @Test("Built-ins load from the app (always current); files shadowing them are visible failures")
    func builtInsAlwaysCurrent() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-smith-builtin-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        // Empty (even nonexistent) directory → built-ins present.
        let registry = EvaluatorRegistry.load(from: directory)
        #expect(registry.definition(named: "default-acceptance")?.contentHash == EvaluatorDefaults.defaultAcceptanceDefinition.contentHash)

        // A user file under a built-in name never shadows — it fails visibly.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let shadowing = Self.defaultVariant(systemPrompt: "trying to shadow the built-in")
        let encoder = JSONEncoder()
        try encoder.encode(shadowing).write(to: directory.appendingPathComponent("default-acceptance.json"), options: .atomic)
        let reloaded = EvaluatorRegistry.load(from: directory)
        #expect(reloaded.definition(named: "default-acceptance")?.contentHash == EvaluatorDefaults.defaultAcceptanceDefinition.contentHash, "the built-in wins")
        #expect(reloaded.failures.contains { $0.problem.contains("built-in") }, "the shadow attempt is a visible failure")
    }

    @Test("Legacy migration deletes pristine seeded copies and preserves user edits as -custom")
    func legacySeededMigration() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-smith-migration-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacyFile = directory.appendingPathComponent("default-acceptance.json")
        let encoder = JSONEncoder()

        // A pristine legacy shipped copy is deleted — the built-in supplies it now.
        let pristine = Self.defaultVariant(systemPrompt: "old shipped prompt")
        try encoder.encode(pristine).write(to: legacyFile, options: .atomic)
        EvaluatorDefaults.migrateLegacySeededBuiltIns(in: directory, legacyHashes: [pristine.contentHash])
        #expect(!FileManager.default.fileExists(atPath: legacyFile.path))

        // A user-EDITED copy is renamed to -custom (nothing the user wrote is lost).
        let edited = Self.defaultVariant(systemPrompt: "the user's customized prompt")
        try encoder.encode(edited).write(to: legacyFile, options: .atomic)
        EvaluatorDefaults.migrateLegacySeededBuiltIns(in: directory, legacyHashes: [])
        #expect(!FileManager.default.fileExists(atPath: legacyFile.path), "the shadowing name is vacated")

        let registry = EvaluatorRegistry.load(from: directory)
        let custom = registry.definition(named: "default-acceptance-custom")
        #expect(custom?.systemPrompt == "the user's customized prompt", "the edit survives under the -custom name")
        #expect(registry.definition(named: "default-acceptance")?.contentHash == EvaluatorDefaults.defaultAcceptanceDefinition.contentHash)
        #expect(registry.failures.isEmpty)
    }

    /// The shipped default with only the system prompt swapped (fields are immutable).
    private static func defaultVariant(systemPrompt: String) -> EvaluatorDefinition {
        let base = EvaluatorDefaults.defaultAcceptanceDefinition
        return EvaluatorDefinition(
            name: base.name,
            description: base.description,
            kind: base.kind,
            systemPrompt: systemPrompt,
            inputTemplate: base.inputTemplate,
            requiredSlots: base.requiredSlots,
            outputGrammar: base.outputGrammar,
            modelSlot: base.modelSlot,
            toolNames: base.toolNames,
            maxTurns: base.maxTurns,
            timeoutSeconds: base.timeoutSeconds,
            maxOutputTokens: base.maxOutputTokens
        )
    }

    @Test("The default validator tells the validator what tools the worker had")
    func validatorSeesWorkerTools() async {
        let (runtime, directory) = makeRuntime(verdictScript: ["ACCEPT"])
        await runtime.setEvaluatorConfiguration(directory: directory)
        let task = await makeSubmittedTask(on: runtime)

        await runtime.startTaskValidation(taskID: task.id)
        let status = await waitForStatusChange(on: runtime, taskID: task.id, away: .validating)
        #expect(status == .completed)

        let record = await runtime.taskStore.task(id: task.id)?.validation?.verdictRecords.first
        #expect(record?.renderedInput?.contains("Worker's tools") == true)
        #expect(record?.renderedInput?.contains("bash") == true, "the worker toolset (incl. bash) is in the validator's input")
    }

    // MARK: - Dynamic (prepare/map) criteria

    /// Installs a minimal prepare-kind definition into the test registry.
    private func installPrepareDefinition(named name: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let definition = EvaluatorDefinition(
            name: name,
            description: "Emits the items to judge for a dynamic criterion (test double).",
            kind: .prepare,
            systemPrompt: "Emit a JSON array of items for the criterion.",
            inputTemplate: "Criterion: {{criterion}}",
            requiredSlots: ["criterion"],
            outputGrammar: .jsonArray,
            modelSlot: .summarizer,
            toolNames: [],
            maxTurns: 3,
            timeoutSeconds: 60,
            maxOutputTokens: 1000
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(definition).write(to: directory.appendingPathComponent("\(name).json"), options: .atomic)
    }

    @Test("A dynamic criterion maps prepare items through the per-item validator; all pass → completed")
    func dynamicCriterionAllItemsPass() async throws {
        let (runtime, directory) = makeRuntime(verdictScript: [
            #"["alpha", "beta"]"#,
            "ACCEPT",
            "ACCEPT"
        ])
        try installPrepareDefinition(named: "list-items", in: directory)
        await runtime.setEvaluatorConfiguration(directory: directory)
        let criteria = [AcceptanceCriterion(text: "every item is valid", origin: .user, prepare: "list-items")]
        let task = await makeSubmittedTask(on: runtime, criteria: criteria)

        await runtime.startTaskValidation(taskID: task.id)
        let status = await waitForStatusChange(on: runtime, taskID: task.id, away: .validating)
        #expect(status == .completed)

        let final = await runtime.taskStore.task(id: task.id)
        #expect(final?.validation?.verdictRecords.count == 1, "one record summarizes the whole map")
        #expect(final?.validation?.pinnedDefinitions["list-items"] != nil, "the prepare body pins like a validator")
    }

    @Test("A dynamic criterion with an empty prepare result auto-accepts")
    func dynamicCriterionEmptyItemsAccepts() async throws {
        let (runtime, directory) = makeRuntime(verdictScript: ["[]"])
        try installPrepareDefinition(named: "list-items", in: directory)
        await runtime.setEvaluatorConfiguration(directory: directory)
        let criteria = [AcceptanceCriterion(text: "every item is valid", origin: .user, prepare: "list-items")]
        let task = await makeSubmittedTask(on: runtime, criteria: criteria)

        await runtime.startTaskValidation(taskID: task.id)
        let status = await waitForStatusChange(on: runtime, taskID: task.id, away: .validating)
        #expect(status == .completed, "nothing applies → the dynamic analogue of a waive")
    }

    @Test("A rejected item returns the task to the worker with the per-item reason")
    func dynamicCriterionItemRejectionPunchLists() async throws {
        let (runtime, directory) = makeRuntime(verdictScript: [
            #"["alpha", "beta"]"#,
            "ACCEPT",
            "REJECT: beta is missing its header"
        ])
        try installPrepareDefinition(named: "list-items", in: directory)
        await runtime.setEvaluatorConfiguration(directory: directory)
        await runtime.setToolSecurity(preflightScoping: false, perCallCheck: false, globalPolicy: [:])
        await runtime.start()
        let criteria = [AcceptanceCriterion(text: "every item is valid", origin: .user, prepare: "list-items")]
        let task = await makeSubmittedTask(on: runtime, criteria: criteria)

        await runtime.startTaskValidation(taskID: task.id)
        let status = await waitForStatusChange(on: runtime, taskID: task.id, away: .validating)
        #expect(status == .running, "an item rejection is a criterion rejection — punch list to the worker")

        let ledger = await runtime.taskStore.task(id: task.id)?.validation
        let record = ledger?.verdictRecords.last
        if case .rejected(let reason) = record?.verdict {
            #expect(reason.contains("beta is missing its header"))
            #expect(reason.contains("1 of 2"))
        } else {
            Issue.record("expected a rejected verdict, got \(String(describing: record?.verdict))")
        }

        // The dynamic debug log covers the prepare exchange AND each item's exchange.
        #expect(record?.responseLog?.contains("## prepare: list-items") == true)
        #expect(record?.responseLog?.contains("## item 2: beta") == true)

        await runtime.stopAll()
    }

    @Test("A dynamic criterion naming a missing prepare function escalates")
    func dynamicCriterionMissingPrepareEscalates() async throws {
        let (runtime, directory) = makeRuntime(verdictScript: ["ACCEPT"])
        await runtime.setEvaluatorConfiguration(directory: directory)
        let criteria = [AcceptanceCriterion(text: "c", origin: .user, prepare: "does-not-exist")]
        let task = await makeSubmittedTask(on: runtime, criteria: criteria)

        await runtime.startTaskValidation(taskID: task.id)
        let status = await waitForStatusChange(on: runtime, taskID: task.id, away: .validating)
        #expect(status == .awaitingReview)
    }

    @Test("A criterion naming a missing registry validator escalates")
    func missingValidatorEscalates() async {
        let (runtime, directory) = makeRuntime(verdictScript: ["ACCEPT"])
        await runtime.setEvaluatorConfiguration(directory: directory)
        let criteria = [AcceptanceCriterion(text: "c", origin: .user, validator: .registry("does-not-exist"))]
        let task = await makeSubmittedTask(on: runtime, criteria: criteria)

        await runtime.startTaskValidation(taskID: task.id)
        let status = await waitForStatusChange(on: runtime, taskID: task.id, away: .validating)
        #expect(status == .awaitingReview)
    }
}
