import Foundation
import Testing
import SemanticSearch
@testable import AgentSmithKit

/// Validation economics (#17): a re-judgment is told why the same criterion was rejected last time,
/// a criterion rejected identically round after round is reported as deadlocked (advisory only),
/// and the acceptance progress shows settled, rejected and never-judged apart.
@Suite("Validation economics", .serialized)
struct ValidationEconomicsTests {

    // MARK: - Previous-rejection seed

    private static func rejection(of criterion: AcceptanceCriterion, _ text: String, at seconds: TimeInterval, prompt: String? = nil) -> CriterionRejection {
        CriterionRejection(
            criterionID: criterion.id,
            name: criterion.name,
            recordedAt: Date(timeIntervalSinceReferenceDate: seconds),
            validationPrompt: prompt ?? criterion.validationPrompt,
            inputEnumeratorPrompt: criterion.inputEnumeratorPrompt,
            rejectionText: text
        )
    }

    @Test("No rejection of this question means no seed")
    func noHistoryNoSeed() {
        let criterion = AcceptanceCriterion(name: "Tests pass", origin: .user)
        #expect(TaskValidationCoordinatorSeam.seed([], criterion) == nil)
        let other = AcceptanceCriterion(name: "Other", origin: .user)
        #expect(TaskValidationCoordinatorSeam.seed([Self.rejection(of: other, "nope", at: 1)], criterion) == nil)
    }

    @Test("The seed carries the latest same-question rejection and how many there were")
    func seedIsLatestSameQuestion() throws {
        let criterion = AcceptanceCriterion(name: "Tests pass", origin: .user)
        let history = [
            Self.rejection(of: criterion, "first reason", at: 1),
            Self.rejection(of: criterion, "under old instructions", at: 2, prompt: "an older question"),
            Self.rejection(of: criterion, "latest reason", at: 3)
        ]
        let seed = try #require(TaskValidationCoordinatorSeam.seed(history, criterion))
        #expect(seed.contains("latest reason"))
        #expect(!seed.contains("first reason"))
        #expect(!seed.contains("under old instructions"), "a rejection of a different question is not about this one")
        #expect(seed.hasPrefix("Rejected 2 times before."))
    }

    @Test("A long rejection is cut to the seed limit, not dropped")
    func seedIsCapped() throws {
        let criterion = AcceptanceCriterion(name: "Tests pass", origin: .user)
        let long = String(repeating: "x", count: OrchestrationRuntime.maxPreviousRejectionSeedChars * 2)
        let seed = try #require(TaskValidationCoordinatorSeam.seed([Self.rejection(of: criterion, long, at: 1)], criterion))
        #expect(seed.count < OrchestrationRuntime.maxPreviousRejectionSeedChars + 100)
        #expect(seed.contains("[truncated"))
    }

    @Test("The prompt explains previousRejection only when one is sent, and says to judge the current evidence")
    func promptMentionsSeedOnlyWhenSent() {
        let criterion = AcceptanceCriterion(name: "Tests pass", origin: .user)
        let definition = EvaluatorDefaults.defaultDefinition
        let without = OrchestrationRuntime.composeValidatorSystemPrompt(definition: definition, criterion: criterion, hasItem: false)
        let with = OrchestrationRuntime.composeValidatorSystemPrompt(definition: definition, criterion: criterion, hasItem: false, hasPreviousRejection: true)
        #expect(!without.contains("previousRejection"))
        #expect(with.contains("`previousRejection`"))
        #expect(with.contains("CURRENT evidence"))
    }

    // MARK: - Runtime

    /// A runtime whose validator answers each call with the next script entry (repeating the last),
    /// returned alongside it so a test can read what the validator was sent.
    private func makeRuntime(verdictScript: [String]) throws -> (OrchestrationRuntime, MockLLMProvider) {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-smith-validation-economics-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let configuration = ModelConfiguration(name: "test", providerID: "test", modelID: "test-model")
        let validator = MockLLMProvider(responses: verdictScript.map { LLMResponse(text: $0) })
        let runtime = OrchestrationRuntime(
            providers: [
                .smith: MockLLMProvider(responses: [LLMResponse(text: "Standing by.")]),
                .brown: StillThinkingLLMProvider(),
                .securityAgent: MockLLMProvider(responses: [LLMResponse(text: "SAFE")]),
                .summarizer: MockLLMProvider(responses: [LLMResponse(text: "Summarized.")]),
                .validator: validator
            ],
            configurations: [.smith: configuration, .brown: configuration, .securityAgent: configuration,
                             .summarizer: configuration, .validator: configuration],
            providerAPITypes: [:],
            agentTuning: [:],
            semanticSearchEngine: SemanticSearchEngine(),
            usageStore: UsageStore(persistence: PersistenceManager(testingRoot: tmpRoot)),
            autoAdvanceEnabled: false,
            autoRunInterruptedTasks: false,
            memoryStore: nil
        )
        return (runtime, validator)
    }

    private func submit(_ taskID: UUID, result: String, on runtime: OrchestrationRuntime) async {
        let store = await runtime.taskStore
        await store.setResult(id: taskID, result: result, commentary: nil, attachments: [])
        await store.setApprovedTools(id: taskID, approvedTools: ["bash", "file_read", "task_complete"])
        await store.driveStatus(id: taskID, to: .validating)
        await runtime.startTaskValidation(taskID: taskID)
    }

    private func waitWhileValidating(_ taskID: UUID, on runtime: OrchestrationRuntime) async throws -> AgentTask.Status? {
        let store = await runtime.taskStore
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let status = await store.task(id: taskID)?.status, status != .validating { return status }
            try await Task.sleep(for: .milliseconds(30))
        }
        return await store.task(id: taskID)?.status
    }

    @Test("A re-judgment is sent the criterion's last rejection; the first judgment is not")
    func reJudgmentIsSeeded() async throws {
        let (runtime, validator) = try makeRuntime(verdictScript: ["REJECT: the log file was never written", "ACCEPT"])
        await runtime.setOrchestrationSettings(OrchestrationSettings.builtIn.applying(OrchestrationSettingsOverride(scopeToolSetOnTaskStart: false)))
        await runtime.start()
        let store = await runtime.taskStore
        let task = await store.addTask(title: "Write the log", description: "d")
        await store.setAcceptanceCriteria(id: task.id, criteria: [AcceptanceCriterion(name: "log file written", origin: .user)])

        await submit(task.id, result: "done", on: runtime)
        #expect(try await waitWhileValidating(task.id, on: runtime) == .running)
        await submit(task.id, result: "done, with the log", on: runtime)
        #expect(try await waitWhileValidating(task.id, on: runtime) == .completed)

        let payloads = validator.receivedMessages.map { $0.last?.content.textValue ?? "" }
        #expect(payloads.count == 2)
        #expect(!(payloads.first ?? "").contains("previousRejection"))
        #expect((payloads.last ?? "").contains("previousRejection"))
        #expect((payloads.last ?? "").contains("the log file was never written"))
        #expect(await store.task(id: task.id)?.validation?.verdictRecords.count == 2, "the seed is not a verdict")

        await runtime.stopAll()
    }

    @Test("A criterion rejected identically three rounds running is reported as deadlocked, once; the task carries on")
    func identicalRejectionsAreAdvised() async throws {
        let (runtime, _) = try makeRuntime(verdictScript: ["REJECT: Same   reason"])
        await runtime.setOrchestrationSettings(OrchestrationSettings.builtIn.applying(OrchestrationSettingsOverride(scopeToolSetOnTaskStart: false)))
        await runtime.setMaxConsecutiveValidationRoundsWithoutProgress(8)
        await runtime.start()
        let store = await runtime.taskStore
        let task = await store.addTask(title: "Impossible", description: "d")
        await store.setAcceptanceCriteria(id: task.id, criteria: [AcceptanceCriterion(name: "the impossible criterion", origin: .user)])

        for round in 1...4 {
            await submit(task.id, result: "attempt \(round)", on: runtime)
            #expect(try await waitWhileValidating(task.id, on: runtime) == .running, "round \(round) returns the rejection to the worker")
        }
        let deadlockNotices = await runtime.channel.allMessages().filter { $0.kind == .validationDeadlock }
        #expect(deadlockNotices.count == 1, "told once, when the streak reached the threshold")
        #expect(deadlockNotices.first?.severity == .warning)
        #expect(Self.smithAccepts(deadlockNotices.first), "Smith is told too")

        await runtime.stopAll()
    }

    private static func smithAccepts(_ message: ChannelMessage?) -> Bool {
        message.map(OrchestrationRuntime.smithAcceptsMessage) ?? false
    }

    // MARK: - Streak and tally

    private static func record(_ criterionID: UUID, _ verdict: CriterionVerdictRecord.Verdict, round: Int) -> CriterionVerdictRecord {
        CriterionVerdictRecord(criterionID: criterionID, verdict: verdict, validatorName: "v", validatorHash: "h", round: round)
    }

    @Test("The identical-rejection streak ignores case and spacing, and ends at a different reason, a non-rejection or a round gap")
    func streakRules() {
        let id = UUID()
        let streak = TaskValidationState(verdictRecords: [
            Self.record(id, .rejected(reason: "different"), round: 1),
            Self.record(id, .rejected(reason: "Missing  tests"), round: 2),
            Self.record(id, .rejected(reason: "missing tests "), round: 3),
            Self.record(id, .rejected(reason: "MISSING TESTS"), round: 4)
        ]).identicalRejectionStreak(for: id)
        #expect(streak == 3)

        #expect(TaskValidationState(verdictRecords: [
            Self.record(id, .rejected(reason: "x"), round: 1),
            Self.record(id, .accepted, round: 2)
        ]).identicalRejectionStreak(for: id) == 0, "the latest verdict is not a rejection")

        #expect(TaskValidationState(verdictRecords: [
            Self.record(id, .rejected(reason: "x"), round: 2),
            Self.record(id, .rejected(reason: "x"), round: 1)
        ]).identicalRejectionStreak(for: id) == 1, "a reset restarts rounds at 1: a gap, not a run")

        #expect(TaskValidationState(verdictRecords: [
            Self.record(id, .rejected(reason: "line 12 fails"), round: 1),
            Self.record(id, .rejected(reason: "line 13 fails"), round: 2)
        ]).identicalRejectionStreak(for: id) == 1, "digits are kept: a changed line number is change")
    }

    @Test("The tally counts settled, rejected, errored and unjudged apart, and in-flight criteria as being judged")
    func tallyCounts() {
        let a = AcceptanceCriterion(name: "a", origin: .user), b = AcceptanceCriterion(name: "b", origin: .user)
        let c = AcceptanceCriterion(name: "c", origin: .user), d = AcceptanceCriterion(name: "d", origin: .user)
        let removed = UUID()
        let ledger = TaskValidationState(verdictRecords: [
            Self.record(a.id, .accepted, round: 1),
            Self.record(b.id, .rejected(reason: "no"), round: 1),
            Self.record(c.id, .error(message: "timeout"), round: 1),
            Self.record(removed, .accepted, round: 1)
        ])
        let idle = ledger.tally(in: [a, b, c, d], inFlight: false)
        #expect(idle == {
            var expected = CriterionTally(total: 4)
            expected.settled = 1; expected.rejected = 1; expected.errored = 1; expected.unjudged = 1
            return expected
        }())
        #expect(idle.settled == ledger.settledCriterionIDs(in: [a, b, c, d]).count, "one answer to what is settled")
        #expect(idle.summaryText == "1 of 4 settled · 1 rejected · 1 error · 1 not judged")

        let inFlight = ledger.tally(in: [a, b, c, d], inFlight: true)
        #expect(inFlight.judging == 3 && inFlight.rejected == 0 && inFlight.settled == 1)

        #expect(TaskValidationState().tally(in: [a, b], inFlight: false).summaryText == "2 not yet judged")
    }
}

/// The seed builder, reached through the runtime type that declares it.
private enum TaskValidationCoordinatorSeam {
    static func seed(_ history: [CriterionRejection], _ criterion: AcceptanceCriterion) -> String? {
        OrchestrationRuntime.previousRejectionSeed(history: history, criterion: criterion)
    }
}
