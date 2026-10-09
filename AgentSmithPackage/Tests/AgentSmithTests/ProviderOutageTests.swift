import Foundation
import Testing
import SemanticSearch
import SwiftLLMKit
@testable import AgentSmithKit

/// A worker model that can't be used (out of credits, a rejected key, a model outside the plan, a
/// usage limit that outlasted every retry) is an account problem, not the task's. Decided 2026-10-06
/// (user): the task is put ON HOLD (interrupted), not failed; no task starts on that model until it
/// is fixed; held tasks restart when the worker's model changes or the user presses Play. Before
/// this, auto-advance failed five tasks in a row on a model outside the account's plan.
@Suite("Provider outages")
struct ProviderOutageTests {

    private static let sharedEngine = SemanticSearchEngine()

    // MARK: - Classification

    @Test("account and model failures are recognized by status; a request's own failures are not")
    func classification() {
        func kind(_ status: Int) -> ProviderUnavailableKind? {
            ProviderUnavailableKind.of(LLMProviderError.httpError(statusCode: status, body: "{}"))
        }
        #expect(kind(401) == .unauthorized)
        #expect(kind(402) == .paymentRequired)
        #expect(kind(403) == .forbidden)
        #expect(kind(404) == .modelNotFound)
        for status in [400, 408, 413, 422, 429, 500, 503] {
            #expect(kind(status) == nil, "HTTP \(status) is not an account or model problem")
        }
        #expect(ProviderUnavailableKind.of(URLError(.timedOut)) == nil)
    }

    /// OpenRouter answers 404 both when a request needs what the model can't do and when the model
    /// has no provider left; only the message tells them apart, so both are treated as the model.
    @Test("an OpenRouter 404 trips the breaker like any 404")
    func openRouter404() {
        let body = #"{"error":{"message":"No endpoints found that support image input","code":404}}"#
        #expect(ProviderUnavailableKind.of(LLMProviderError.httpError(statusCode: 404, body: body)) == .modelNotFound)
    }

    /// OpenRouter answers 403 when moderation flags the input: a refusal of that conversation, not
    /// of the account. Read from its typed error fields, never its message.
    @Test("an OpenRouter moderation 403 is not an account problem; a plain 403 is")
    func moderationForbidden() {
        func kind(_ body: String) -> ProviderUnavailableKind? {
            ProviderUnavailableKind.of(LLMProviderError.httpError(statusCode: 403, body: body))
        }
        let moderation = #"{"error":{"code":403,"message":"Your chosen model requires moderation and your input was flagged","metadata":{"reasons":["violence"],"flagged_input":"…"}}}"#
        #expect(kind(moderation) == nil)
        #expect(kind(#"{"error":{"message":"forbidden"}}"#) == .forbidden)
        #expect(kind("not json") == .forbidden)
    }

    /// The Codex backend's typed limits: depleted credits and the spend cap are account problems; a
    /// usage window that resets on its own is a wait, not an outage.
    @Test("Codex limits map by their typed fields")
    func codexLimits() {
        func kind(_ body: String) -> ProviderUnavailableKind? {
            ProviderUnavailableKind.of(LLMProviderError.httpError(statusCode: 429, body: body))
        }
        #expect(kind(#"{"error":{"rate_limit_reached_type":"workspace_owner_credits_depleted"}}"#) == .creditsDepleted(userCanResolve: true))
        #expect(kind(#"{"error":{"rate_limit_reached_type":"workspace_member_credits_depleted"}}"#) == .creditsDepleted(userCanResolve: false))
        #expect(kind(#"{"error":{"spend_control_reached":true}}"#) == .spendLimitReached)
        #expect(kind(#"{"error":{"type":"usage_limit_reached","resets_in_seconds":60}}"#) == nil)
        #expect(kind(#"{"error":{"type":"rate_limit_exceeded"}}"#) == nil)
    }

    @Test("only a 429 that outlasted every retry is attributed to the model")
    func retryExhaustionClassification() {
        func kind(_ status: Int) -> ProviderUnavailableKind? {
            ProviderUnavailableKind.afterRetriesExhausted(on: LLMProviderError.httpError(statusCode: status, body: "{}"))
        }
        #expect(kind(429) == .rateLimitExhausted)
        #expect(kind(503) == nil, "a server fault says nothing about the account")
        #expect(kind(500) == nil)
        #expect(kind(408) == nil)
        #expect(ProviderUnavailableKind.afterRetriesExhausted(on: URLError(.timedOut)) == nil)
        #expect(ProviderUnavailableKind.of(LLMProviderError.httpError(statusCode: 429, body: "{}")) == nil,
                "a single 429 is transient")
    }

    /// Depleted credits are a balance someone may top up at any time, so that outage is re-checked
    /// on a slow cadence and lifts on its own (ROADMAP, settled 2026-09-16; #16). Every other
    /// account problem waits for a person.
    @Test("only depleted credits are re-checked, on the hour; a member is told to ask an owner")
    func creditsRecheckPolicy() {
        #expect(ProviderUnavailableKind.creditsDepleted(userCanResolve: true).recheckInterval == ProviderUnavailableKind.creditsRecheckInterval)
        #expect(ProviderUnavailableKind.creditsRecheckInterval == 3600)
        for kind: ProviderUnavailableKind in [.paymentRequired, .spendLimitReached, .unauthorized, .forbidden, .modelNotFound, .rateLimitExhausted] {
            #expect(kind.recheckInterval == nil, "\(kind) needs a person, not a re-check")
        }
        #expect(ProviderUnavailableKind.creditsDepleted(userCanResolve: false).retryCondition.contains("workspace owner"))
    }

    // MARK: - Runtime

    @Test("an unusable worker model holds its task, holds back other starts, and a model change restarts them")
    func holdAndRelease() async throws {
        try await withRuntime(brownProvider: PaymentRequiredProvider(), capacity: 2) { runtime, store in
            let first = await store.addTask(title: "First", description: "d")
            let second = await store.addTask(title: "Second", description: "d")
            await runtime.restartForNewTask(taskID: first.id, origin: .explicitUser)
            try await settle(runtime, stopLines: 1)

            #expect(await store.task(id: first.id)?.status == .interrupted, "the task was not put on hold")
            #expect(await store.task(id: first.id)?.updates.contains { $0.message.hasPrefix("On hold:") } == true)
            let outage = try #require(await runtime.workerProviderOutage())
            #expect(outage.kind == .paymentRequired)
            #expect(await outageAdvisories(runtime).count == 1, "the user must be told once")
            let stopLine = await runtime.channel.allMessages().first { $0.kind == .agentLifecycle && $0.content.contains("on hold") }
            #expect(stopLine?.severity == .warning)

            // Breaker: another start on the same model waits instead of failing too — told once,
            // however often it is retried.
            await runtime.restartForNewTask(taskID: second.id, origin: .smithTool)
            await runtime.restartForNewTask(taskID: second.id, origin: .smithTool)
            await runtime.waitForPendingRestarts()
            #expect(await store.task(id: second.id)?.status == .pending, "a task started on an unusable model")
            let notStarting = await runtime.channel.allMessages().filter { $0.content.hasPrefix("Not starting \"Second\"") }
            #expect(notStarting.count == 1)

            await switchWorkerToWorkingModel(runtime)
            #expect(await runtime.workerProviderOutage() == nil)
            let resumed = try await waitUntil {
                let firstStarted = await store.task(id: first.id)?.status == .running
                let secondStarted = await store.task(id: second.id)?.status == .running
                return firstStarted && secondStarted
            }
            #expect(resumed, "the held tasks did not restart after the worker's model changed")
        }
    }

    /// Deterministic: the first call fails at once (tripping the breaker); the retry of the first
    /// task and the user's started task then fail TOGETHER, so neither can trip the breaker before
    /// the other has been tried.
    @Test("the user's Play retries the model for every held task; if it still can't be used, all are held again")
    func userRetryStillBroken() async throws {
        let provider = RetryRefusingProvider(arrivals: CallArrivals(), refuseTogetherAfter: 3)
        try await withRuntime(brownProvider: provider, capacity: 2) { runtime, store in
            let first = await store.addTask(title: "First", description: "d")
            let second = await store.addTask(title: "Second", description: "d")
            await runtime.restartForNewTask(taskID: first.id, origin: .explicitUser)
            try await settle(runtime, stopLines: 1)

            await runtime.restartForNewTask(taskID: second.id, origin: .explicitUser)
            try await settle(runtime, stopLines: 3)

            #expect(await provider.arrivals.count == 3, "the held task was not retried with the user's")
            #expect(await store.task(id: first.id)?.status == .interrupted)
            #expect(await store.task(id: second.id)?.status == .interrupted)
            let firstHolds = await store.task(id: first.id)?.updates.filter { $0.message.hasPrefix("On hold:") }.count
            #expect(firstHolds == 2, "the first task was held once, retried, and held again")
            #expect(await runtime.workerProviderOutage() != nil, "the outage was not tripped again")
            #expect(await outageAdvisories(runtime).count == 2, "one notice per outage")
        }
    }

    @Test("several workers failing on the same model tell the user once")
    func oneAdvisoryPerOutage() async throws {
        // Both workers' calls fail together. If the first failed before the second Play reached the
        // start gate, that Play would (rightly) retry the model and earn its own notice.
        let provider = RetryRefusingProvider(arrivals: CallArrivals(), refuseTogetherAfter: 2, refusesFirstAtOnce: false)
        try await withRuntime(brownProvider: provider, capacity: 2) { runtime, store in
            let first = await store.addTask(title: "First", description: "d")
            let second = await store.addTask(title: "Second", description: "d")
            await runtime.restartForNewTask(taskID: first.id, origin: .explicitUser)
            await runtime.restartForNewTask(taskID: second.id, origin: .explicitUser)
            try await settle(runtime, stopLines: 2)
            #expect(await store.task(id: first.id)?.status == .interrupted)
            #expect(await store.task(id: second.id)?.status == .interrupted)
            #expect(await outageAdvisories(runtime).count == 1, "one outage, one notice")
        }
    }

    /// A call that started on the old model can fail after the user switched to a working one; its
    /// report must not trip the breaker against the NEW model, and the task restarts once the old
    /// worker is gone.
    @Test("a failure reported for a model the worker no longer uses restarts the task and trips nothing")
    func staleModelReport() async throws {
        try await withRuntime(brownProvider: StillThinkingLLMProvider(), capacity: 1) { runtime, store in
            let taskID = await store.addTask(title: "Task", description: "d").id
            await runtime.restartForNewTask(taskID: taskID, origin: .explicitUser)
            let taskStarted = try await waitUntil { await store.task(id: taskID)?.status == .running }
            #expect(taskStarted)
            let worker = try #require(await runtime.liveWorkerID(taskID: taskID))

            let handling = await runtime.handleProviderUnavailable(
                ProviderOutage(role: .brown, providerID: "test", modelID: "an-old-model", kind: .paymentRequired, detail: "402"),
                agentID: worker
            )
            #expect(handling == .taskRestarting)
            #expect(await runtime.workerProviderOutage() == nil, "a stale report tripped the breaker")
            #expect(await outageAdvisories(runtime).isEmpty)
            #expect(await store.task(id: taskID)?.assigneeIDs.contains(worker) == false,
                    "the dying worker still holds the task")

            // The old worker stops (as it does after reporting); its slot frees and the task restarts.
            #expect(await runtime.terminateAgent(id: worker))
            let restarted = try await waitUntil { await Self.runs(taskID, onAWorkerOtherThan: worker, in: runtime) }
            #expect(restarted, "the task was not restarted on the current model")
        }
    }

    @Test("a non-worker's unusable model is reported each time and trips no breaker")
    func nonWorkerRoleHasNoBreaker() async throws {
        try await withRuntime(brownProvider: StillThinkingLLMProvider(), capacity: 1) { runtime, _ in
            let smithID = try #require(await runtime.agentIDForRole(.smith))
            let outage = ProviderOutage(role: .smith, providerID: "test", modelID: "test-model", kind: .unauthorized, detail: "401")
            #expect(await runtime.handleProviderUnavailable(outage, agentID: smithID) == .noTaskHeld)
            #expect(await runtime.handleProviderUnavailable(outage, agentID: smithID) == .noTaskHeld)
            #expect(await runtime.workerProviderOutage() == nil)
            #expect(await outageAdvisories(runtime).count == 2, "each stop is reported")
        }
    }

    @Test("a worker whose task isn't running trips the breaker without holding anything")
    func reportWithoutRunningTask() async throws {
        try await withRuntime(brownProvider: StillThinkingLLMProvider(), capacity: 1) { runtime, _ in
            let outage = ProviderOutage(role: .brown, providerID: "test", modelID: "test-model", kind: .paymentRequired, detail: "402")
            #expect(await runtime.handleProviderUnavailable(outage, agentID: UUID()) == .noTaskHeld)
            #expect(await runtime.workerProviderOutage() == outage)
        }
    }

    @Test("retuning the same model does not release the outage")
    func retuneKeepsOutage() async throws {
        try await withRuntime(brownProvider: PaymentRequiredProvider(), capacity: 1) { runtime, store in
            let taskID = await store.addTask(title: "Task", description: "d").id
            await runtime.restartForNewTask(taskID: taskID, origin: .explicitUser)
            try await settle(runtime, stopLines: 1)
            var retuned = ModelConfiguration(name: "test", providerID: "test", modelID: "test-model")
            retuned.temperature = 0.2
            await runtime.setProviders(
                providers: [.brown: PaymentRequiredProvider()],
                configurations: [.brown: retuned],
                apiTypes: [.brown: .openAICompatible]
            )
            #expect(await runtime.workerProviderOutage() != nil, "a retune is not a fix")
            #expect(await store.task(id: taskID)?.status == .interrupted)
        }
    }

    /// Released tasks beyond the free slots must still start — a never-started (pending) one
    /// included — once a slot frees, whatever the auto-run settings.
    @Test("a release with more waiting tasks than slots starts the rest as slots free")
    func releaseUnderCapacity() async throws {
        try await withRuntime(brownProvider: PaymentRequiredProvider(), capacity: 1) { runtime, store in
            let first = await store.addTask(title: "First", description: "d")
            let second = await store.addTask(title: "Second", description: "d")
            await runtime.restartForNewTask(taskID: first.id, origin: .explicitUser)
            try await settle(runtime, stopLines: 1)
            await runtime.restartForNewTask(taskID: second.id, origin: .smithTool)
            await runtime.waitForPendingRestarts()
            #expect(await store.task(id: second.id)?.status == .pending)

            await switchWorkerToWorkingModel(runtime)
            let oneRunning = try await waitUntil {
                let a = await store.task(id: first.id)?.status == .running
                let b = await store.task(id: second.id)?.status == .running
                return a != b
            }
            #expect(oneRunning, "exactly one of the two should run at capacity 1")
            let runningID = await store.task(id: first.id)?.status == .running ? first.id : second.id
            let waitingID = runningID == first.id ? second.id : first.id

            await runtime.terminateTaskAgents(taskID: runningID)
            #expect(await store.driveStatus(id: runningID, to: .completed))
            let otherTaskStarted = try await waitUntil { await store.task(id: waitingID)?.status == .running }
            #expect(otherTaskStarted, "the other released task never started when the slot freed")
        }
    }

    /// A scheduled run that fires during the outage stays on its durable queue. At the release it
    /// starts — and so do the held tasks: a scheduled start ends a drain pass, so without the
    /// repeated drain they would sit idle beside free slots.
    @Test("a release fills every free slot, scheduled runs and held tasks alike")
    func releaseWithScheduledRun() async throws {
        try await withRuntime(brownProvider: PaymentRequiredProvider(), capacity: 3) { runtime, store in
            let held = await store.addTask(title: "Held", description: "d")
            let waiting = await store.addTask(title: "Waiting", description: "d")
            let scheduled = await store.addTask(title: "Scheduled", description: "d")
            await runtime.restartForNewTask(taskID: held.id, origin: .explicitUser)
            try await settle(runtime, stopLines: 1)
            await runtime.restartForNewTask(taskID: waiting.id, origin: .smithTool)
            await runtime.waitForPendingRestarts()
            _ = await runtime.dispatchAutoRunWake(taskID: scheduled.id, amendment: nil)
            #expect(await store.task(id: scheduled.id)?.status == .pending, "a scheduled run started during the outage")

            await switchWorkerToWorkingModel(runtime)
            let allRunning = try await waitUntil {
                var running = 0
                for id in [held.id, waiting.id, scheduled.id] where await store.task(id: id)?.status == .running {
                    running += 1
                }
                return running == 3
            }
            #expect(allRunning, "a free slot stayed idle after the release")
        }
    }

    /// The promise "it starts on its own" holds for a task Smith asked to resume from `.paused`; a
    /// task the user paused while it waited has moved on, and stays paused.
    @Test("held starts are kept by revision: a paused task Smith resumed starts, a task the user paused does not")
    func heldStartsKeptByRevision() async throws {
        try await withRuntime(brownProvider: PaymentRequiredProvider(), capacity: 4) { runtime, store in
            let trigger = await store.addTask(title: "Trigger", description: "d")
            let resumedBySmith = await store.addTask(title: "Resumed by Smith", description: "d")
            let pausedByUser = await store.addTask(title: "Paused by the user", description: "d")
            let pausedThenResumed = await store.addTask(title: "Paused, then resumed", description: "d")
            #expect(await store.driveStatus(id: resumedBySmith.id, to: .paused))
            await runtime.restartForNewTask(taskID: trigger.id, origin: .explicitUser)
            try await settle(runtime, stopLines: 1)

            await runtime.restartForNewTask(taskID: resumedBySmith.id, origin: .smithTool)
            await runtime.restartForNewTask(taskID: pausedByUser.id, origin: .smithTool)
            await runtime.restartForNewTask(taskID: pausedThenResumed.id, origin: .smithTool)
            await runtime.waitForPendingRestarts()
            #expect(await store.driveStatus(id: pausedByUser.id, to: .paused))
            // Paused by the user, then started again: the latest request wins.
            #expect(await store.driveStatus(id: pausedThenResumed.id, to: .paused))
            await runtime.restartForNewTask(taskID: pausedThenResumed.id, origin: .smithTool)
            await runtime.waitForPendingRestarts()

            await switchWorkerToWorkingModel(runtime)
            let resumedTaskStarted = try await waitUntil { await store.task(id: resumedBySmith.id)?.status == .running }
            #expect(resumedTaskStarted, "a start Smith was promised was dropped")
            let triggerRestarted = try await waitUntil { await store.task(id: trigger.id)?.status == .running }
            #expect(triggerRestarted)
            await runtime.waitForPendingRestarts()
            #expect(await store.task(id: pausedByUser.id)?.status == .paused, "a task the user paused was started")
            let release = await runtime.channel.allMessages().first { $0.content.hasPrefix("The worker's model was changed.") }
            #expect(release?.content.contains("Starting 3 waiting task(s)") == true)
            let resumedAgain = try await waitUntil { await store.task(id: pausedThenResumed.id)?.status == .running }
            #expect(resumedAgain, "a task paused and then started again lost its start")
        }
    }

    @Test("a held task archived and restored during the outage is not started by the release")
    func archivedHeldTaskDropped() async throws {
        try await withRuntime(brownProvider: PaymentRequiredProvider(), capacity: 2) { runtime, store in
            let first = await store.addTask(title: "First", description: "d")
            let second = await store.addTask(title: "Second", description: "d")
            await runtime.restartForNewTask(taskID: first.id, origin: .explicitUser)
            try await settle(runtime, stopLines: 1)
            await runtime.restartForNewTask(taskID: second.id, origin: .smithTool)
            await runtime.waitForPendingRestarts()
            #expect(await store.archive(id: second.id))
            // Archiving drops the held start through the lifecycle event, handled asynchronously;
            // the held starts are part of what resumes on its own, so wait for it to leave them.
            let secondID = second.id
            let heldStartDropped = try await waitUntil { !(await runtime.automaticallyResumingChildTaskIDs().contains(secondID)) }
            #expect(heldStartDropped)
            #expect(await store.restoreToActive(id: second.id))

            await switchWorkerToWorkingModel(runtime)
            let firstRestarted = try await waitUntil { await store.task(id: first.id)?.status == .running }
            #expect(firstRestarted)
            await runtime.waitForPendingRestarts()
            #expect(await store.task(id: second.id)?.status == .pending, "an archived task kept its held start")
            let release = await runtime.channel.allMessages().first { $0.content.hasPrefix("The worker's model was changed.") }
            #expect(release?.content.contains("Starting 1 waiting task(s)") == true)
        }
    }

    @Test("a worker whose 429s outlast its retries holds its task and other starts, never fails it")
    func rateLimitExhaustionHolds() async throws {
        try await withRuntime(brownProvider: UsageLimitProvider(), capacity: 2) { runtime, store in
            let first = await store.addTask(title: "First", description: "d")
            let second = await store.addTask(title: "Second", description: "d")
            await runtime.restartForNewTask(taskID: first.id, origin: .explicitUser)

            // Cut the 50-attempt budget down so the exhaustion path runs in seconds.
            let workerSpawned = try await waitUntil { await runtime.liveWorkerID(taskID: first.id) != nil }
            #expect(workerSpawned)
            let workerID = try #require(await runtime.liveWorkerID(taskID: first.id))
            let worker = try #require(await runtime.liveAgent(id: workerID))
            await worker.limitRetryAttemptsForTesting(to: 2)
            try await settle(runtime, stopLines: 1, timeout: .seconds(30))

            #expect(await store.task(id: first.id)?.status == .interrupted, "the task was not put on hold")
            let outage = try #require(await runtime.workerProviderOutage())
            #expect(outage.kind == .rateLimitExhausted)
            let messages = await runtime.channel.allMessages()
            let stopLine = messages.first { $0.kind == .agentLifecycle && $0.content.contains("HTTP 429") }
            #expect(stopLine?.content.contains("its task is on hold") == true)
            #expect(stopLine?.severity == .warning)
            #expect(messages.contains { $0.content.contains("once the provider's limit resets") },
                    "the advisory names the right way to retry")

            // Another start waits on the outage instead of burning its own 50 retries.
            await runtime.restartForNewTask(taskID: second.id, origin: .smithTool)
            await runtime.waitForPendingRestarts()
            #expect(await store.task(id: second.id)?.status == .pending)
        }
    }

    // MARK: - Helpers

    /// Runs `body` on a started runtime and always stops it and removes its files, even when the
    /// body throws.
    private func withRuntime(
        brownProvider: any LLMProvider,
        capacity: Int,
        _ body: (OrchestrationRuntime, TaskStore) async throws -> Void
    ) async throws {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-smith-provider-outage-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let runtime = makeRuntime(brownProvider: brownProvider, tmpRoot: tmpRoot)
        await runtime.setOrchestrationSettings(OrchestrationSettings.builtIn.applying(OrchestrationSettingsOverride(
            autoRunNextTask: false,
            autoRunInterruptedTasks: false,
            enableTaskCompletionValidators: false,
            scopeToolSetOnTaskStart: false
        )))
        await runtime.setWorkerCapacity(capacity)
        await runtime.start()
        var failure: Error?
        do {
            try await body(runtime, await runtime.taskStore)
        } catch {
            failure = error
        }
        await runtime.stopAll()
        do {
            try FileManager.default.removeItem(at: tmpRoot)
        } catch {
            Issue.record("could not remove the test's files at \(tmpRoot.path): \(error)")
        }
        if let failure { throw failure }
    }

    /// Waits until `stopLines` workers have stopped on the outage and every worker is gone — the
    /// stop line is posted after the runtime has handled the report, so outage, advisory and task
    /// updates are all in place by then.
    private func settle(_ runtime: OrchestrationRuntime, stopLines: Int, timeout: Duration = .seconds(15)) async throws {
        let settled = try await waitUntil(timeout: timeout) {
            let lines = await runtime.channel.allMessages().filter {
                $0.kind == .agentLifecycle && $0.content.contains("its task is on hold")
            }
            let liveWorkers = await runtime.workerSlots().live
            return lines.count >= stopLines && liveWorkers == 0
        }
        #expect(settled, "\(stopLines) worker(s) did not stop on the outage")
    }

    private static func runs(_ taskID: UUID, onAWorkerOtherThan worker: UUID, in runtime: OrchestrationRuntime) async -> Bool {
        guard await runtime.taskStore.task(id: taskID)?.status == .running,
              let current = await runtime.liveWorkerID(taskID: taskID) else { return false }
        return current != worker
    }

    private func outageAdvisories(_ runtime: OrchestrationRuntime) async -> [ChannelMessage] {
        await runtime.channel.allMessages().filter { $0.kind == .advisory && $0.severity == .error }
    }

    private func switchWorkerToWorkingModel(_ runtime: OrchestrationRuntime) async {
        await runtime.setProviders(
            providers: [.brown: StillThinkingLLMProvider()],
            configurations: [.brown: ModelConfiguration(name: "test", providerID: "test", modelID: "working-model")],
            apiTypes: [.brown: .openAICompatible]
        )
    }

    private static let paymentRequired = LLMProviderError.httpError(statusCode: 402, body: #"{"error":{"message":"This model is not in the Free plan."}}"#)

    /// Refuses every call with the Codex backend's depleted-credits limit (or `refusal`) until
    /// `topUp()`, then answers. Counts calls, worker turns and re-check probes alike.
    private final class CreditsProvider: LLMProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var depleted = true
        private var calls = 0
        private var refusal: LLMProviderError
        init(refusal: LLMProviderError = LLMProviderError.httpError(statusCode: 429, body: #"{"error":{"rate_limit_reached_type":"workspace_owner_credits_depleted"}}"#)) {
            self.refusal = refusal
        }
        var callCount: Int { lock.withLock { calls } }
        func topUp() { lock.withLock { depleted = false } }
        func refuse(with error: LLMProviderError) { lock.withLock { refusal = error } }
        func send(messages: [LLMMessage], tools: [LLMToolDefinition], overrides: LLMCallOverrides) async throws -> LLMResponse {
            let refusalNow = lock.withLock { () -> LLMProviderError? in
                calls += 1
                return depleted ? refusal : nil
            }
            if let refusalNow { throw refusalNow }
            // A worker turn (tools offered) keeps working; a re-check probe (no tools) is answered.
            if tools.isEmpty { return LLMResponse(text: "OK") }
            try await Task.sleep(for: .seconds(30))
            return LLMResponse(text: "working")
        }
    }

    @Test("depleted credits hold the task, are re-checked quietly, and the task resumes on its own after a top-up")
    func creditsSelfResume() async throws {
        let provider = CreditsProvider()
        try await withRuntime(brownProvider: provider, capacity: 1) { runtime, store in
            await runtime.setWorkerOutageRecheckIntervalForTesting(0.1)
            let task = await store.addTask(title: "Needs credits", description: "d")
            await runtime.restartForNewTask(taskID: task.id, origin: .explicitUser)
            try await settle(runtime, stopLines: 1)
            #expect(await store.task(id: task.id)?.status == .interrupted)
            #expect(await runtime.workerProviderOutage()?.kind == .creditsDepleted(userCanResolve: true))

            // Several re-checks, all still refused: nothing changes and nobody is told again.
            let probed = try await waitUntil { provider.callCount >= 4 }
            #expect(probed, "the outage was not re-checked")
            #expect(await runtime.workerProviderOutage() != nil)
            #expect(await outageAdvisories(runtime).count == 1, "a still-refused re-check must not repeat the advisory")
            #expect(await store.task(id: task.id)?.updates.filter { $0.message.hasPrefix("On hold:") }.count == 1)

            provider.topUp()
            let resumed = try await waitUntil {
                let outageGone = await runtime.workerProviderOutage() == nil
                let running = await store.task(id: task.id)?.status == .running
                return outageGone && running
            }
            #expect(resumed, "the held task did not resume after the credits came back")
            #expect(await runtime.channel.allMessages().contains { $0.kind == .advisory && $0.content.contains("can be used again") })
        }
    }

    @Test("a spend cap is never re-checked")
    func spendCapNotRechecked() async throws {
        let provider = CreditsProvider(refusal: LLMProviderError.httpError(statusCode: 429, body: #"{"error":{"spend_control_reached":true}}"#))
        try await withRuntime(brownProvider: provider, capacity: 1) { runtime, store in
            await runtime.setWorkerOutageRecheckIntervalForTesting(0.1)
            let task = await store.addTask(title: "Capped", description: "d")
            await runtime.restartForNewTask(taskID: task.id, origin: .explicitUser)
            try await settle(runtime, stopLines: 1)
            #expect(await runtime.workerProviderOutage()?.kind == .spendLimitReached)
            let callsAtHold = provider.callCount
            try await Task.sleep(for: .milliseconds(600))
            #expect(provider.callCount == callsAtHold, "a spend cap was probed (\(callsAtHold) → \(provider.callCount))")
        }
    }

    @Test("Stop ends the re-check: nothing probes, or restarts work, in a stopped session")
    func stopEndsRecheck() async throws {
        let provider = CreditsProvider()
        try await withRuntime(brownProvider: provider, capacity: 1) { runtime, store in
            await runtime.setWorkerOutageRecheckIntervalForTesting(0.1)
            let task = await store.addTask(title: "Needs credits", description: "d")
            await runtime.restartForNewTask(taskID: task.id, origin: .explicitUser)
            try await settle(runtime, stopLines: 1)
            await runtime.stopAll()
            let callsAtStop = provider.callCount
            provider.topUp()
            try await Task.sleep(for: .milliseconds(600))
            #expect(provider.callCount == callsAtStop, "a stopped session was re-checked")
            #expect(await runtime.workerProviderOutage() != nil, "the outage stands until something re-checks it")

            // The next start resumes the re-check, which finds the credits back and releases it.
            await runtime.start()
            let released = try await waitUntil { await runtime.workerProviderOutage() == nil }
            #expect(released, "start() did not resume the re-check")
        }
    }

    @Test("a re-check refused for a different account reason replaces the outage, tells the held tasks, and stops if that reason isn't re-checked")
    func recheckReplacesOutage() async throws {
        let provider = CreditsProvider()
        try await withRuntime(brownProvider: provider, capacity: 1) { runtime, store in
            await runtime.setWorkerOutageRecheckIntervalForTesting(0.1)
            let task = await store.addTask(title: "Needs credits", description: "d")
            await runtime.restartForNewTask(taskID: task.id, origin: .explicitUser)
            try await settle(runtime, stopLines: 1)
            provider.refuse(with: LLMProviderError.httpError(statusCode: 404, body: "{}"))

            let replaced = try await waitUntil { await runtime.workerProviderOutage()?.kind == .modelNotFound }
            #expect(replaced, "the outage was not replaced by the new reason")
            #expect(await outageAdvisories(runtime).count == 2, "the new reason is told once")
            #expect(await store.task(id: task.id)?.updates.contains { $0.message.hasPrefix("Still on hold:") } == true)
            let callsAfterReplacement = provider.callCount
            try await Task.sleep(for: .milliseconds(600))
            #expect(provider.callCount == callsAfterReplacement, "a reason that isn't re-checked was probed again")
        }
    }

    @Test("a re-check that fails for a non-account reason keeps re-checking, and says so once")
    func recheckFailureToldOnce() async throws {
        let provider = CreditsProvider()
        try await withRuntime(brownProvider: provider, capacity: 1) { runtime, store in
            await runtime.setWorkerOutageRecheckIntervalForTesting(0.1)
            let task = await store.addTask(title: "Needs credits", description: "d")
            await runtime.restartForNewTask(taskID: task.id, origin: .explicitUser)
            try await settle(runtime, stopLines: 1)
            provider.refuse(with: LLMProviderError.httpError(statusCode: 400, body: #"{"error":"bad request"}"#))
            let callsBefore = provider.callCount

            let probedAgain = try await waitUntil { provider.callCount >= callsBefore + 3 }
            #expect(probedAgain, "a non-account failure stopped the re-check")
            #expect(await runtime.workerProviderOutage()?.kind == .creditsDepleted(userCanResolve: true), "the outage stands")
            let told = await runtime.channel.allMessages().filter { $0.kind == .advisory && $0.content.contains("keep re-checking") }
            #expect(told.count == 1, "the failure must be told exactly once, not on every re-check")
        }
    }

    /// Every call is refused with HTTP 402, as Ollama answers for a model outside the plan.
    private struct PaymentRequiredProvider: LLMProvider {
        func send(messages: [LLMMessage], tools: [LLMToolDefinition], overrides: LLMCallOverrides) async throws -> LLMResponse {
            throw ProviderOutageTests.paymentRequired
        }
    }

    /// Every call is refused with HTTP 429 and no stated delay, as Ollama answers once a free-plan
    /// usage limit is reached.
    private struct UsageLimitProvider: LLMProvider {
        func send(messages: [LLMMessage], tools: [LLMToolDefinition], overrides: LLMCallOverrides) async throws -> LLMResponse {
            throw LLMProviderError.httpError(statusCode: 429, body: #"{"error":"You reached the Free usage limit."}"#)
        }
    }

    private actor CallArrivals {
        private(set) var count = 0
        func arrive() -> Int {
            count += 1
            return count
        }
    }

    /// Refuses every call with HTTP 402. The first call is refused at once when
    /// `refusesFirstAtOnce`; every other call waits until `refuseTogetherAfter` calls have arrived,
    /// so concurrent workers fail on the same outage, in no particular order.
    private struct RetryRefusingProvider: LLMProvider {
        let arrivals: CallArrivals
        let refuseTogetherAfter: Int
        var refusesFirstAtOnce = true

        func send(messages: [LLMMessage], tools: [LLMToolDefinition], overrides: LLMCallOverrides) async throws -> LLMResponse {
            let arrival = await arrivals.arrive()
            if !(refusesFirstAtOnce && arrival == 1) {
                while await arrivals.count < refuseTogetherAfter {
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            throw ProviderOutageTests.paymentRequired
        }
    }

    private func waitUntil(timeout: Duration = .seconds(15), _ predicate: @Sendable () async -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await predicate() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return await predicate()
    }

    private func makeRuntime(brownProvider: any LLMProvider, tmpRoot: URL) -> OrchestrationRuntime {
        let config = ModelConfiguration(name: "test", providerID: "test", modelID: "test-model")
        return OrchestrationRuntime(
            providers: [
                .smith: MockLLMProvider(responses: [LLMResponse(text: "Standing by.")]),
                .securityAgent: MockLLMProvider(responses: [LLMResponse(text: "SAFE")]),
                .brown: brownProvider
            ],
            configurations: [.smith: config, .securityAgent: config, .brown: config],
            providerAPITypes: [.smith: .openAICompatible, .securityAgent: .openAICompatible, .brown: .openAICompatible],
            agentTuning: [
                .brown: AgentTuningConfig(pollInterval: 3600),
                .smith: AgentTuningConfig(pollInterval: 3600),
                .securityAgent: AgentTuningConfig(pollInterval: 3600)
            ],
            semanticSearchEngine: Self.sharedEngine,
            usageStore: UsageStore(persistence: PersistenceManager(testingRoot: tmpRoot)),
            autoAdvanceEnabled: false,
            autoRunInterruptedTasks: false,
            memoryStore: nil
        )
    }
}
