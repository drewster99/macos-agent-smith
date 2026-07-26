import Foundation
import Testing
import SemanticSearch
@testable import AgentSmithKit

/// The `.validating` state machine end-to-end against mock providers: acceptance
/// completes tasks, rejection punch-lists return to the worker, errors and round
/// exhaustion escalate, and criterion-less tasks get the materialized default.

@Suite("Task validation coordinator", .serialized)
struct TaskValidationCoordinatorTests {

    /// Runtime whose VALIDATOR mock answers each validation call with the next
    /// `verdictScript` entry, repeating the last when exhausted. Smith/Brown/Security mocks are
    /// present so worker respawn paths work. The validator slot must be populated: it has no
    /// fallback to another role's model, and an empty slot parks the task instead of judging it
    /// (`validationBlocksWithoutAValidatorModel` covers that path deliberately).
    private func makeRuntime(verdictScript: [String], includeValidator: Bool = true) -> OrchestrationRuntime {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-smith-validation-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)

        let testConfiguration = ModelConfiguration(name: "test", providerID: "test", modelID: "test-model")
        var providers: [AgentRole: any LLMProvider] = [
            .smith: MockLLMProvider(responses: [LLMResponse(text: "Standing by.")]),
            .brown: MockLLMProvider(responses: [LLMResponse(text: "Working.")]),
            .securityAgent: MockLLMProvider(responses: [LLMResponse(text: "SAFE")]),
            .summarizer: MockLLMProvider(responses: [LLMResponse(text: "Summarized.")])
        ]
        var configurations: [AgentRole: ModelConfiguration] = [
            .smith: testConfiguration,
            .brown: testConfiguration,
            .securityAgent: testConfiguration,
            .summarizer: testConfiguration
        ]
        if includeValidator {
            providers[.validator] = MockLLMProvider(responses: verdictScript.map { LLMResponse(text: $0) })
            configurations[.validator] = testConfiguration
        }
        let runtime = OrchestrationRuntime(
            providers: providers,
            configurations: configurations,
            providerAPITypes: [:],
            agentTuning: [:],
            semanticSearchEngine: SemanticSearchEngine(),
            usageStore: UsageStore(persistence: PersistenceManager(testingRoot: tmpRoot)),
            autoAdvanceEnabled: false,
            autoRunInterruptedTasks: false,
            memoryStore: nil
        )
        return runtime
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
        // A real task reaches `.validating` only after pre-flight scoping, so its scoped set
        // (approvedTools) is always populated — the validator reads it as the worker's toolset.
        await store.setApprovedTools(id: task.id, approvedTools: ["bash", "file_read", "file_write", "grep", "glob", "manage_steps", "task_complete"])
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

    // MARK: - User resolution of a validator-error escalation (replaces review_work)

    /// A task parked in `.awaitingReview` with one rejected (unsettled) criterion + a result —
    /// the shape a validator-error escalation leaves behind, ready for the user's row actions.
    private func makeEscalatedTask(on runtime: OrchestrationRuntime) async -> (AgentTask, AcceptanceCriterion) {
        let store = await runtime.taskStore
        let task = await store.addTask(title: "Escalated task", description: "d")
        let criterion = AcceptanceCriterion(name: "the validator got this wrong", origin: .user)
        await store.setAcceptanceCriteria(id: task.id, criteria: [criterion])
        await store.setResult(id: task.id, result: "correct work", commentary: nil, attachments: [])
        _ = await store.beginValidationRound(id: task.id)
        await store.recordCriterionVerdicts(id: task.id, records: [
            CriterionVerdictRecord(criterionID: criterion.id, verdict: .rejected(reason: "wrongly rejected"), validatorName: "default", validatorHash: "x", round: 1)
        ], judgedAgainst: [criterion])
        await store.updateStatus(id: task.id, status: .awaitingReview)
        return (await store.task(id: task.id) ?? task, criterion)
    }

    @Test("User accept records a 'user override' verdict, logs it, and completes the task")
    func userAcceptRecordsOverride() async throws {
        let runtime = makeRuntime(verdictScript: [])
        let (task, criterion) = await makeEscalatedTask(on: runtime)
        await runtime.acceptEscalatedTask(taskID: task.id)
        let final = await runtime.taskStore.task(id: task.id)
        #expect(final?.status == .completed)
        #expect(final?.validation?.settledCriterionIDs() == [criterion.id], "the override settles the criterion")
        #expect(final?.validation?.verdictRecords.last?.validatorName == "user override")
        #expect(final?.updates.contains { $0.message.contains("overriding acceptance validation") } == true)
    }

    @Test("User re-validate takes the task out of awaitingReview back into judging")
    func userRevalidateLeavesAwaitingReview() async throws {
        let runtime = makeRuntime(verdictScript: ["ACCEPT"])
        let (task, _) = await makeEscalatedTask(on: runtime)
        await runtime.revalidateEscalatedTask(taskID: task.id)
        let settled = await waitForStatusChange(on: runtime, taskID: task.id, away: .awaitingReview)
        #expect(settled != .awaitingReview, "re-validation must move it back into the judging pipeline")
    }

    @Test("User fail marks the escalated task failed")
    func userFailMarksFailed() async throws {
        let runtime = makeRuntime(verdictScript: [])
        let (task, _) = await makeEscalatedTask(on: runtime)
        await runtime.failEscalatedTask(taskID: task.id)
        #expect(await runtime.taskStore.task(id: task.id)?.status == .failed)
    }

    @Test("All criteria accepted → task completes; the implicit default criterion is materialized")
    func acceptanceCompletesCriterionlessTask() async {
        let runtime = makeRuntime(verdictScript: ["ACCEPT"])
        let task = await makeSubmittedTask(on: runtime)

        await runtime.startTaskValidation(taskID: task.id)
        let status = await waitForStatusChange(on: runtime, taskID: task.id, away: .validating)
        #expect(status == .completed)

        let final = await runtime.taskStore.task(id: task.id)
        #expect(final?.acceptanceCriteria.count == 1, "the implicit default criterion must be materialized")
        #expect(final?.acceptanceCriteria.first?.origin == .system)
        #expect(final?.validation?.verdictRecords.count == 1)
        #expect(final?.validation?.verdictRecords.first?.validatorName == "default", "the shipped default judged it")

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
        let runtime = makeRuntime(verdictScript: [
            "ACCEPT",
            "REJECT: the log file was never written",
            "ACCEPT"
        ])
        await runtime.setToolSecurity(preflightScoping: false, perCallCheck: false, globalPolicy: [:])
        await runtime.start()
        let criteria = [
            AcceptanceCriterion(name: "A: code compiles", origin: .user),
            AcceptanceCriterion(name: "B: log file written", origin: .user)
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
        let runtime = makeRuntime(verdictScript: ["I cannot decide, sorry!"])
        let task = await makeSubmittedTask(on: runtime)

        await runtime.startTaskValidation(taskID: task.id)
        let status = await waitForStatusChange(on: runtime, taskID: task.id, away: .validating)
        #expect(status == .awaitingReview, "errors park for manual review — they are never rejections")
    }

    @Test("A WAIVE against a non-waivable criterion escalates as an error")
    func waiveOnNonWaivableEscalates() async {
        let runtime = makeRuntime(verdictScript: ["WAIVE: does not apply here"])
        let criteria = [AcceptanceCriterion(name: "must always hold", waivable: false, origin: .user)]
        let task = await makeSubmittedTask(on: runtime, criteria: criteria)

        await runtime.startTaskValidation(taskID: task.id)
        let status = await waitForStatusChange(on: runtime, taskID: task.id, away: .validating)
        #expect(status == .awaitingReview)
    }

    @Test("A waivable criterion accepts a WAIVE and settles")
    func waivableWaives() async {
        let runtime = makeRuntime(verdictScript: ["WAIVE: this task has no UI to screenshot"])
        let criteria = [AcceptanceCriterion(name: "screenshots attached", waivable: true, origin: .smith)]
        let task = await makeSubmittedTask(on: runtime, criteria: criteria)

        await runtime.startTaskValidation(taskID: task.id)
        let status = await waitForStatusChange(on: runtime, taskID: task.id, away: .validating)
        #expect(status == .completed)
    }

    @Test("Three no-progress rejection rounds FAIL the task (never Smith); a counter reset restores validation for a retry")
    func stalledValidationFailsAndResetRestoresValidation() async {
        // One criterion rejected three straight rounds with nothing newly settled →
        // the task FAILS. After the counter reset (run_task's failed-task auto-reset /
        // review_work's reject path), a resubmission must get judged again rather than
        // insta-failing on the stale stall counter.
        let runtime = makeRuntime(verdictScript: [
            "REJECT: round 1 miss",
            "REJECT: round 2 miss",
            "REJECT: round 3 miss",
            "ACCEPT"
        ])
        await runtime.setToolSecurity(preflightScoping: false, perCallCheck: false, globalPolicy: [:])
        // Drive the non-convergence path with a budget of 3 rather than scripting a full shipped
        // budget's worth of identical rejection rounds. What's under test is the stall RULE —
        // consecutive rounds with nothing newly settled — not the specific number.
        await runtime.setMaxConsecutiveValidationRoundsWithoutProgress(3)
        await runtime.start()
        let criteria = [AcceptanceCriterion(name: "the fix actually works", origin: .user)]
        let task = await makeSubmittedTask(on: runtime, criteria: criteria)
        let store = await runtime.taskStore

        await runtime.startTaskValidation(taskID: task.id)
        var status = await waitForStatusChange(on: runtime, taskID: task.id, away: .validating)
        #expect(status == .running, "round 1 rejection returns to the worker")

        for expectedOutcome in [AgentTask.Status.running, .failed] {
            await store.setResult(id: task.id, result: "another attempt", commentary: nil, attachments: [])
            await store.updateStatus(id: task.id, status: .validating)
            await runtime.startTaskValidation(taskID: task.id)
            status = await waitForStatusChange(on: runtime, taskID: task.id, away: .validating)
            #expect(status == expectedOutcome)
        }

        let messages = await runtime.channel.allMessages()
        #expect(messages.contains { message in
            if case .string("validation_failed") = message.metadata?["messageKind"] { return true }
            return false
        }, "the failure is announced in the channel")

        // run_task's auto-reset gives the retry fresh counters; the resubmission judges again.
        #expect(await store.resetFailedTask(id: task.id))
        await store.setResult(id: task.id, result: "the real fix", commentary: nil, attachments: [])
        await store.updateStatus(id: task.id, status: .validating)
        await runtime.startTaskValidation(taskID: task.id)
        status = await waitForStatusChange(on: runtime, taskID: task.id, away: .validating)
        #expect(status == .completed, "after a reset, validation judges again instead of insta-failing")

        await runtime.stopAll()
    }
    @Test("The default validator tells the validator what tools the worker had")
    func validatorSeesWorkerTools() async {
        let runtime = makeRuntime(verdictScript: ["ACCEPT"])
        let task = await makeSubmittedTask(on: runtime)

        await runtime.startTaskValidation(taskID: task.id)
        let status = await waitForStatusChange(on: runtime, taskID: task.id, away: .validating)
        #expect(status == .completed)

        let record = await runtime.taskStore.task(id: task.id)?.validation?.verdictRecords.first
        #expect(record?.renderedInput?.contains("workerTools") == true, "the JSON payload carries the worker-tools field")
        #expect(record?.renderedInput?.contains("bash") == true, "the worker's scoped toolset (incl. bash) is in the validator's input")
    }

    @Test("A missing worker scope errors and escalates — never a fabricated toolset")
    func validatorErrorsWhenWorkerScopeMissing() async {
        let runtime = makeRuntime(verdictScript: ["ACCEPT"])
        let task = await makeSubmittedTask(on: runtime)
        // Simulate the should-never-happen invariant violation: a task reaching validation with no
        // scoped set. The validator must NOT invent one (which historically injected `bash` and
        // ordered impossible fixes); it must error so the task escalates for manual review.
        await runtime.taskStore.setApprovedTools(id: task.id, approvedTools: [])

        await runtime.startTaskValidation(taskID: task.id)
        let status = await waitForStatusChange(on: runtime, taskID: task.id, away: .validating)
        #expect(status == .awaitingReview, "a missing scope is machine-can't-judge → escalates, not accepts")

        let record = await runtime.taskStore.task(id: task.id)?.validation?.verdictRecords.first
        if case .error(let message) = record?.verdict {
            #expect(message.contains("approvedTools"), "the error names the missing scoped set")
        } else {
            Issue.record("expected an .error verdict, got \(String(describing: record?.verdict))")
        }
    }

    @Test("Validator input keeps rubric and result apart: criterion in the system prompt, result in a JSON field, with the verdict-format firewall")
    func validatorInputSeparatesRubricFromResult() {
        let criterion = AcceptanceCriterion(
            name: "Result format",
            validationPrompt: #"Result must be in the format "Result: <result>" and begin with "Result:""#,
            origin: .user
        )
        let system = OrchestrationRuntime.composeValidatorSystemPrompt(
            definition: EvaluatorDefaults.defaultDefinition,
            criterion: criterion,
            hasItem: false
        )
        #expect(system.contains("## Validation instructions"))
        #expect(system.contains(criterion.validationPrompt))
        #expect(!system.contains("Result format"), "the display name is not an LLM instruction")
        // The firewall that fixes the bug: ACCEPT/REJECT/WAIVE is the validator's format,
        // never a requirement on the worker's result.
        #expect(system.contains("is how YOU respond"))
        #expect(system.contains("NEVER reject merely because"))
        #expect(system.contains("resultsToEvaluate"))

        // A result full of JSON-hostile characters — quotes, braces, newlines, and a
        // verdict-like first line — survives intact inside its field and cannot leak into
        // structure or be mistaken for the rubric.
        let nastyResult = "ACCEPT\nResult: {\"x\": \"POSSIBLE SUCCESS\"}\n## Discussion"
        let payload = OrchestrationRuntime.validatorPayloadJSON([
            "resultsToEvaluate": nastyResult,
            "taskTitle": "t"
        ])
        let parsed = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: String]
        #expect(parsed?["resultsToEvaluate"] == nastyResult, "the exact result round-trips through its JSON field")
    }

    // MARK: - Dynamic (prepare/map) criteria

    @Test("A dynamic criterion maps prepare items through the per-item validator; all pass → completed")
    func dynamicCriterionAllItemsPass() async throws {
        let runtime = makeRuntime(verdictScript: [
            #"["alpha", "beta"]"#,
            "ACCEPT",
            "ACCEPT"
        ])
        let criteria = [AcceptanceCriterion(
            name: "Every item is valid",
            validationPrompt: "Check the supplied item has its required header.",
            inputEnumeratorPrompt: "Return the items to validate as a JSON array of strings.",
            origin: .user
        )]
        let task = await makeSubmittedTask(on: runtime, criteria: criteria)

        await runtime.startTaskValidation(taskID: task.id)
        let status = await waitForStatusChange(on: runtime, taskID: task.id, away: .validating)
        #expect(status == .completed)

        let final = await runtime.taskStore.task(id: task.id)
        #expect(final?.validation?.verdictRecords.count == 1, "one record summarizes the whole map")
        #expect(final?.acceptanceCriteria.first?.inputEnumeratorPrompt != nil, "the task itself owns the enumerator prompt")
    }

    @Test("A dynamic criterion with an empty prepare result waives (when waivable) → completes")
    func dynamicCriterionEmptyItemsAccepts() async throws {
        let runtime = makeRuntime(verdictScript: ["[]"])
        // Empty enumeration is honored as a pass only when the criterion is WAIVABLE — a misfiring
        // or hallucinated-empty prepare on a NON-waivable criterion escalates instead of silently
        // passing an unexamined requirement (see judgeDynamicCriterion's empty-items gate).
        let criteria = [AcceptanceCriterion(
            name: "every item is valid",
            inputEnumeratorPrompt: "Return the items to validate as a JSON array of strings.",
            waivable: true,
            origin: .user
        )]
        let task = await makeSubmittedTask(on: runtime, criteria: criteria)

        await runtime.startTaskValidation(taskID: task.id)
        let status = await waitForStatusChange(on: runtime, taskID: task.id, away: .validating)
        #expect(status == .completed, "nothing applies on a waivable criterion → the dynamic analogue of a waive")
    }

    @Test("A rejected item returns the task to the worker with the per-item reason")
    func dynamicCriterionItemRejectionPunchLists() async throws {
        let runtime = makeRuntime(verdictScript: [
            #"["alpha", "beta"]"#,
            "ACCEPT",
            "REJECT: beta is missing its header"
        ])
        await runtime.setToolSecurity(preflightScoping: false, perCallCheck: false, globalPolicy: [:])
        await runtime.start()
        let criteria = [AcceptanceCriterion(
            name: "every item is valid",
            inputEnumeratorPrompt: "Return the items to validate as a JSON array of strings.",
            origin: .user
        )]
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
        #expect(record?.responseLog?.contains("input-enumerator") == true)
        #expect(record?.responseLog?.contains("## item 2: beta") == true)

        await runtime.stopAll()
    }

    @Test("With no validator model the task parks unresolvably, and assigning one releases it")
    func validationBlocksWithoutAValidatorModel() async throws {
        // No validator slot at all: there is no fallback, so validation must not proceed.
        let runtime = makeRuntime(verdictScript: ["ACCEPT"], includeValidator: false)
        let task = await makeSubmittedTask(on: runtime)

        await runtime.startTaskValidation(taskID: task.id)
        let blocked = await waitForStatusChange(on: runtime, taskID: task.id, away: .validating)
        #expect(blocked == .awaitingReview)

        let parked = await runtime.taskStore.task(id: task.id)
        #expect(parked?.validationBlockedReason != nil, "the park must be marked, not look like an ordinary review")
        #expect(parked?.result == "The thing was done.", "the submission is untouched — it was never judged")
        #expect(parked?.validation?.verdictRecords.isEmpty != false, "nothing may be recorded as judged")

        // Not the user's to resolve either: the escalation row actions gate on a non-blocked park,
        // so accepting a config-blocked task is a no-op.
        await runtime.acceptEscalatedTask(taskID: task.id)
        #expect(await runtime.taskStore.task(id: task.id)?.status == .awaitingReview, "a config-blocked park is not user-resolvable — accept changes nothing")

        // Assigning a validator model is the only thing that unsticks it.
        await runtime.setProviders(
            providers: [.validator: MockLLMProvider(responses: [LLMResponse(text: "ACCEPT")])],
            configurations: [.validator: ModelConfiguration(name: "test", providerID: "test", modelID: "test-model")],
            apiTypes: [:]
        )
        let released = await waitForStatusChange(on: runtime, taskID: task.id, away: .awaitingReview)
        #expect(released == .completed, "the parked task resumes validating on its own once configured")
        #expect(await runtime.taskStore.task(id: task.id)?.validationBlockedReason == nil)
    }

    @Test("A Smith-authored prompt criterion is judged by a task-scoped custom validator, end to end")
    func customPromptCriterionJudgesEndToEnd() async throws {
        let runtime = makeRuntime(verdictScript: ["ACCEPT"])
        let criteria = [AcceptanceCriterion(
            name: "the summary is in French",
            validationPrompt: "Verify the submitted result is written in French.",
            origin: .smith
        )]
        let task = await makeSubmittedTask(on: runtime, criteria: criteria)

        await runtime.startTaskValidation(taskID: task.id)
        let status = await waitForStatusChange(on: runtime, taskID: task.id, away: .validating)
        #expect(status == .completed)

        let record = await runtime.taskStore.task(id: task.id)?.validation?.verdictRecords.first
        // A custom validator is named for its criterion (not the shipped "default").
        #expect(record?.validatorName.hasPrefix("criterion-") == true)
        #expect(record?.validatorName.hasSuffix("-validator") == true)
        #expect(record?.validatorName != "default")
        #expect(record?.renderedInput?.contains("The thing was done.") == true, "the custom validator saw the standard slots")
    }
}
