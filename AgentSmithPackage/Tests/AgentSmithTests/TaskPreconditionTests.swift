import Foundation
import Testing
import SemanticSearch
@testable import AgentSmithKit

/// First-class task preconditions (#18): typed, checked before every worker start, reportable by the
/// worker only for a declared one, and ending in a BLOCKED outcome that is never a validation result.
@Suite("Task preconditions", .serialized)
struct TaskPreconditionTests {

    // MARK: - Model

    @Test("A task without preconditions decodes as before and doesn't write the keys")
    func legacyCoding() throws {
        let task = AgentTask(title: "t", description: "d")
        let data = try JSONEncoder().encode(task)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("preconditions"))
        #expect(!json.contains("preconditionFailure"))
        let decoded = try JSONDecoder().decode(AgentTask.self, from: data)
        #expect(decoded.preconditions.isEmpty && decoded.preconditionFailure == nil)
    }

    @Test("Every kind round-trips; a kind this build doesn't know decodes as unknown and fails closed")
    func kindCoding() async throws {
        let kinds: [TaskPrecondition.Kind] = [
            .workerModelSupports(.vision), .fileExists(path: "/tmp/x"),
            .commandAvailable(name: "ffmpeg"), .workerAttested(statement: "the fixture is loaded")
        ]
        for kind in kinds {
            let precondition = TaskPrecondition(kind: kind, origin: .smith)
            let decoded = try JSONDecoder().decode(TaskPrecondition.self, from: try JSONEncoder().encode(precondition))
            #expect(decoded == precondition)
        }
        let future = Data(#"{"type":"networkReachable","host":"example.com"}"#.utf8)
        let decoded = try JSONDecoder().decode(TaskPrecondition.Kind.self, from: future)
        guard case .unknown(let type, _) = decoded else { Issue.record("expected unknown, got \(decoded)"); return }
        #expect(type == "networkReachable")
        #expect(await PreconditionEvaluator.unmetDetail(decoded, in: Self.environment()) != nil, "an unknown kind is never passed")
        // Written back whole, so this build can't corrupt what a newer one wrote.
        let reencoded = try JSONDecoder().decode([String: String].self, from: try JSONEncoder().encode(decoded))
        #expect(reencoded == ["type": "networkReachable", "host": "example.com"])
        let futureCapability = Data(#"{"type":"workerModelSupports","capability":"audio"}"#.utf8)
        let capabilityDecoded = try JSONDecoder().decode(TaskPrecondition.Kind.self, from: futureCapability)
        let capabilityReencoded = try JSONDecoder().decode([String: String].self, from: try JSONEncoder().encode(capabilityDecoded))
        #expect(capabilityReencoded == ["type": "workerModelSupports", "capability": "audio"])
    }

    @Test("Authoring refuses a relative path, a multi-word command, and an empty statement")
    func authoringRules() {
        #expect(TaskPrecondition.authoringProblem(in: .fileExists(path: "relative/file")) != nil)
        #expect(TaskPrecondition.authoringProblem(in: .fileExists(path: "~/file")) == nil)
        #expect(TaskPrecondition.authoringProblem(in: .fileExists(path: "/abs/file")) == nil)
        #expect(TaskPrecondition.authoringProblem(in: .commandAvailable(name: "rm -rf /")) != nil)
        #expect(TaskPrecondition.authoringProblem(in: .commandAvailable(name: "/usr/bin/git")) != nil)
        #expect(TaskPrecondition.authoringProblem(in: .commandAvailable(name: "git")) == nil)
        #expect(TaskPrecondition.authoringProblem(in: .workerAttested(statement: "  ")) != nil)
    }

    // MARK: - Status matrix

    @Test("A start-check block may come from any state a worker is spawned from; a worker's report only from running")
    func causeMatrix() {
        for from: AgentTask.Status in [.starting, .pending, .paused, .interrupted, .running, .awaitingHelp, .validating, .awaitingReview] {
            #expect(TaskTransitionCause.preconditionUnmet(.startCheck).permits(from: from, to: .failed))
        }
        #expect(!TaskTransitionCause.preconditionUnmet(.startCheck).permits(from: .completed, to: .failed))
        #expect(!TaskTransitionCause.preconditionUnmet(.startCheck).permits(from: .scheduled, to: .failed))
        #expect(TaskTransitionCause.preconditionUnmet(.worker).permits(from: .running, to: .failed))
        #expect(!TaskTransitionCause.preconditionUnmet(.worker).permits(from: .validating, to: .failed))
        #expect(!TaskTransitionCause.preconditionUnmet(.startCheck).permits(from: .running, to: .completed))
    }

    @Test("A block is written with its record; the status writer refuses one without it; leaving .failed clears it")
    func blockWriteAndClear() async throws {
        let store = TaskStore()
        let precondition = TaskPrecondition(kind: .fileExists(path: "/nope"), origin: .smith)
        var task = await store.addTask(title: "t", description: "d")
        await store.restore([{ task.preconditions = [precondition]; return task }()])
        task = try #require(await store.task(id: task.id))

        #expect(await store.updateStatus(id: task.id, to: .failed, ifCurrentlyIn: [.pending], cause: .preconditionUnmet(.startCheck)) == false,
                "a block without its record is refused")

        let failure = PreconditionFailureRecord(precondition: precondition, detail: "nothing exists at /nope", checkedBy: .startCheck)
        let ticket = try #require(await store.blockOnPrecondition(id: task.id, failure: failure, ifCurrentlyIn: [.pending]))
        await store.releaseEffects(ticket)
        let blocked = try #require(await store.task(id: task.id))
        #expect(blocked.status == .failed)
        #expect(blocked.preconditionFailure == failure)
        #expect(blocked.outcome == .blocked(reason: failure.reason))
        #expect(blocked.validation == nil, "nothing was judged")

        #expect(await store.resetFailedTask(id: task.id))
        #expect(await store.task(id: task.id)?.preconditionFailure == nil, "a retry checks afresh")
    }

    // MARK: - Evaluator

    private static func environment(
        vision: Bool? = true, pdf: Bool? = true,
        existing: Set<String> = [], commands: [String: PreconditionEnvironment.CommandLookup] = [:]
    ) -> PreconditionEnvironment {
        PreconditionEnvironment(
            workerModelSupports: { capability in capability == .vision ? vision : pdf },
            pathExists: { existing.contains($0) },
            lookUpCommand: { commands[$0] ?? .notFound }
        )
    }

    @Test("The evaluator returns the first unmet start-checked precondition, skips worker-checked ones, and fails closed")
    func evaluator() async {
        let attested = TaskPrecondition(kind: .workerAttested(statement: "s"), origin: .smith)
        let file = TaskPrecondition(kind: .fileExists(path: "/here"), origin: .smith)
        let command = TaskPrecondition(kind: .commandAvailable(name: "ffmpeg"), origin: .smith)
        let vision = TaskPrecondition(kind: .workerModelSupports(.vision), origin: .user)

        let allMet = Self.environment(existing: ["/here"], commands: ["ffmpeg": .found(path: "/opt/homebrew/bin/ffmpeg")])
        #expect(await PreconditionEvaluator.firstUnmet([attested, file, command, vision], in: allMet) == nil)

        let noCommand = Self.environment(existing: ["/here"])
        #expect(await PreconditionEvaluator.firstUnmet([attested, file, command], in: noCommand)?.preconditionID == command.id)

        let lookupFailed = Self.environment(existing: ["/here"], commands: ["ffmpeg": .failed("timed out")])
        #expect(await PreconditionEvaluator.firstUnmet([command], in: lookupFailed) != nil, "a lookup that couldn't finish is unmet")

        #expect(await PreconditionEvaluator.firstUnmet([vision], in: Self.environment(vision: false))?.preconditionID == vision.id)
        #expect(await PreconditionEvaluator.firstUnmet([vision], in: Self.environment(vision: nil)) != nil, "no worker model is unmet")
    }

    @Test("The login-shell lookup finds a real command and passes the name as data, never as script")
    func loginShellLookup() async {
        // `.found`, not merely "not .notFound": a timeout or a shell failure must fail this test.
        guard case .found(let path) = await PreconditionEnvironment.lookUpInLoginShell("ls") else {
            Issue.record("ls was not found through the login shell")
            return
        }
        #expect(path.hasSuffix("/ls"))
        #expect(await PreconditionEnvironment.lookUpInLoginShell("definitely-not-a-command-\(UUID().uuidString.prefix(8))") == .notFound)
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("precondition-injection-\(UUID().uuidString)")
        _ = await PreconditionEnvironment.lookUpInLoginShell("x; touch \(marker.path)")
        #expect(!FileManager.default.fileExists(atPath: marker.path), "the name must never be executed")
    }

    // MARK: - Runtime

    private func makeRuntime() throws -> OrchestrationRuntime {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-smith-precondition-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let configuration = ModelConfiguration(name: "test", providerID: "test", modelID: "test-model")
        return OrchestrationRuntime(
            providers: [
                .smith: MockLLMProvider(responses: [LLMResponse(text: "Standing by.")]),
                .securityAgent: MockLLMProvider(responses: [LLMResponse(text: "SAFE")]),
                .brown: StillThinkingLLMProvider()
            ],
            configurations: [.smith: configuration, .securityAgent: configuration, .brown: configuration],
            providerAPITypes: [:],
            agentTuning: [:],
            semanticSearchEngine: SemanticSearchEngine(),
            usageStore: UsageStore(persistence: PersistenceManager(testingRoot: tmpRoot)),
            autoAdvanceEnabled: false,
            autoRunInterruptedTasks: false,
            memoryStore: nil
        )
    }

    private func startedRuntime() async throws -> (OrchestrationRuntime, TaskStore) {
        let runtime = try makeRuntime()
        await runtime.setOrchestrationSettings(OrchestrationSettings.builtIn.applying(
            OrchestrationSettingsOverride(autoRunNextTask: false, scopeToolSetOnTaskStart: false)))
        await runtime.start()
        return (runtime, await runtime.taskStore)
    }

    @Test("An unmet precondition blocks the start: no worker, no validation, a warning row, Smith told it is BLOCKED")
    func startGateBlocks() async throws {
        let (runtime, store) = try await startedRuntime()
        let missing = "/nonexistent-\(UUID().uuidString)"
        let task = await store.addTask(title: "Fix the file", description: "d",
                                       preconditions: [TaskPrecondition(kind: .fileExists(path: missing), origin: .smith)])

        await runtime.restartForNewTask(taskID: task.id, origin: .explicitUser)
        await runtime.waitForPendingRestarts()

        let blocked = try #require(await store.task(id: task.id))
        #expect(blocked.status == .failed)
        #expect(blocked.preconditionFailure?.checkedBy == .startCheck)
        #expect(await runtime.liveWorkerID(taskID: task.id) == nil, "nothing is spawned for a blocked task")
        #expect(await runtime.channel.allMessages().contains { $0.kind == .taskBlocked })
        #expect(SmithTaskBriefing.note(
            for: TaskStatusTransition(taskID: task.id, statusRevision: 0, from: .starting, to: .failed, at: Date(), cause: .preconditionUnmet(.startCheck)),
            task: blocked)?.contains("BLOCKED") == true)

        await runtime.stopAll()
    }

    @Test("Vision support the catalog doesn't state is unknown, and blocks: the gate fails closed")
    func unknownVisionBlocks() async throws {
        let (runtime, store) = try await startedRuntime()
        let task = await store.addTask(title: "Read the screenshots", description: "d",
                                       preconditions: [TaskPrecondition(kind: .workerModelSupports(.vision), origin: .smith)])
        await runtime.restartForNewTask(taskID: task.id, origin: .explicitUser)
        await runtime.waitForPendingRestarts()
        let blocked = try #require(await store.task(id: task.id))
        #expect(blocked.status == .failed && blocked.preconditionFailure != nil)
        #expect(await runtime.liveWorkerID(taskID: task.id) == nil)
        await runtime.stopAll()
    }

    @Test("A start-time block applies only if nothing moved the task during the check, and only for a still-declared precondition")
    func blockIsRevisionAndDeclarationGuarded() async throws {
        let store = TaskStore()
        let gate = TaskPrecondition(kind: .fileExists(path: "/nope"), origin: .smith)
        let task = await store.addTask(title: "t", description: "d", preconditions: [gate])
        let failure = PreconditionFailureRecord(precondition: gate, detail: "missing", checkedBy: .startCheck)
        let snapshot = try #require(await store.task(id: task.id))

        // Paused during the check: the revision moved, so the late failure is dropped.
        #expect(await store.driveStatus(id: task.id, to: .paused))
        #expect(await store.blockOnPrecondition(id: task.id, failure: failure, ifCurrentlyIn: [.pending, .paused],
                                                ifStatusRevision: snapshot.statusRevision) == nil)
        #expect(await store.task(id: task.id)?.status == .paused)

        // The precondition was edited away meanwhile: nothing to block on.
        let other = TaskPrecondition(kind: .fileExists(path: "/elsewhere"), origin: .smith)
        let fresh = await store.addTask(title: "u", description: "d", preconditions: [other])
        #expect(await store.blockOnPrecondition(id: fresh.id, failure: failure, ifCurrentlyIn: [.pending]) == nil)
        #expect(await store.task(id: fresh.id)?.status == .pending)
    }

    @Test("A met precondition lets the task start")
    func startGatePasses() async throws {
        let (runtime, store) = try await startedRuntime()
        let task = await store.addTask(title: "Read the tmp dir", description: "d",
                                       preconditions: [TaskPrecondition(kind: .fileExists(path: NSTemporaryDirectory()), origin: .smith)])
        await runtime.restartForNewTask(taskID: task.id, origin: .explicitUser)
        await runtime.waitForPendingRestarts()
        #expect(await store.task(id: task.id)?.status == .running)
        await runtime.stopAll()
    }

    @Test("The worker can report only a declared precondition, only while running; a mechanical one that holds is refused")
    func workerReportRules() async throws {
        let (runtime, store) = try await startedRuntime()
        let attested = TaskPrecondition(kind: .workerAttested(statement: "the staging DB has the fixture"), origin: .smith)
        let holds = TaskPrecondition(kind: .fileExists(path: NSTemporaryDirectory()), origin: .smith)
        let task = await store.addTask(title: "Migrate", description: "d", preconditions: [attested, holds])
        await runtime.restartForNewTask(taskID: task.id, origin: .explicitUser)
        await runtime.waitForPendingRestarts()
        let workerID = try #require(await runtime.liveWorkerID(taskID: task.id))

        let undeclared = await runtime.handlePreconditionReport(from: workerID, preconditionID: UUID(), evidence: "it's hard")
        guard case .refused = undeclared else { Issue.record("an undeclared precondition must be refused"); return }
        let stillHolds = await runtime.handlePreconditionReport(from: workerID, preconditionID: holds.id, evidence: "looked missing")
        guard case .refused = stillHolds else { Issue.record("a precondition that holds must be refused"); return }
        #expect(await store.task(id: task.id)?.status == .running)

        let accepted = await runtime.handlePreconditionReport(from: workerID, preconditionID: attested.id, evidence: "SELECT count(*) returned 0")
        guard case .blocked = accepted else { Issue.record("a declared, false precondition blocks: \(accepted)"); return }
        let blocked = try #require(await store.task(id: task.id))
        #expect(blocked.status == .failed && blocked.preconditionFailure?.checkedBy == .worker)
        #expect(blocked.preconditionFailure?.detail == "SELECT count(*) returned 0")
        #expect(blocked.validation == nil, "no validation round was spent")

        await runtime.stopAll()
    }

    @Test("set_preconditions is gated like the contract and won't touch a user's precondition or the blocking one")
    func setPreconditionsRules() async throws {
        let store = TaskStore()
        let users = TaskPrecondition(kind: .commandAvailable(name: "git"), origin: .user)
        var task = await store.addTask(title: "t", description: "d", preconditions: [users])

        // Smith may add alongside the user's, but not drop or change it.
        let added = TaskPrecondition(kind: .fileExists(path: "/x"), origin: .smith)
        #expect(await store.setPreconditions(id: task.id, [users, added], by: .smith) == nil)
        #expect(await store.setPreconditions(id: task.id, [added], by: .smith) != nil)
        var changed = users
        changed.kind = .commandAvailable(name: "hg")
        #expect(await store.setPreconditions(id: task.id, [changed, added], by: .smith) != nil)
        #expect(await store.setPreconditions(id: task.id, [added], by: .user) == nil, "the user may remove their own")

        // Not while a worker runs.
        await store.driveStatus(id: task.id, to: .running)
        #expect(await store.setPreconditions(id: task.id, [], by: .smith) != nil)

        // Each precondition once.
        let other = await store.addTask(title: "v", description: "d")
        let one = TaskPrecondition(kind: .commandAvailable(name: "git"), origin: .smith)
        #expect(await store.setPreconditions(id: other.id, [one, one], by: .smith) != nil)

        // Relative paths are refused at authoring.
        task = await store.addTask(title: "u", description: "d")
        #expect(await store.setPreconditions(id: task.id, [TaskPrecondition(kind: .fileExists(path: "rel"), origin: .smith)], by: .smith) != nil)
    }

    @Test("Smith may correct the precondition a task is blocked on, when Smith set it")
    func smithCorrectsItsBlockingPrecondition() async throws {
        let store = TaskStore()
        let wrong = TaskPrecondition(kind: .fileExists(path: "/wrong/path"), origin: .smith)
        let task = await store.addTask(title: "t", description: "d", preconditions: [wrong])
        let ticket = try #require(await store.blockOnPrecondition(
            id: task.id, failure: PreconditionFailureRecord(precondition: wrong, detail: "missing", checkedBy: .startCheck), ifCurrentlyIn: [.pending]))
        await store.releaseEffects(ticket)
        let fixed = TaskPrecondition(id: wrong.id, kind: .fileExists(path: "/right/path"), origin: .smith)
        #expect(await store.setPreconditions(id: task.id, [fixed], by: .smith) == nil)
    }

    @Test("A precondition unmet when a validator's rejections go back blocks the task instead of re-queuing it")
    func blocksOnRejectionRespawn() async throws {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-smith-precondition-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let configuration = ModelConfiguration(name: "test", providerID: "test", modelID: "test-model")
        let runtime = OrchestrationRuntime(
            providers: [
                .smith: MockLLMProvider(responses: [LLMResponse(text: "Standing by.")]),
                .securityAgent: MockLLMProvider(responses: [LLMResponse(text: "SAFE")]),
                .brown: StillThinkingLLMProvider(),
                .validator: MockLLMProvider(responses: [LLMResponse(text: "REJECT: not done")])
            ],
            configurations: [.smith: configuration, .securityAgent: configuration, .brown: configuration, .validator: configuration],
            providerAPITypes: [:],
            agentTuning: [:],
            semanticSearchEngine: SemanticSearchEngine(),
            usageStore: UsageStore(persistence: PersistenceManager(testingRoot: tmpRoot)),
            autoAdvanceEnabled: false,
            autoRunInterruptedTasks: false,
            memoryStore: nil
        )
        await runtime.setOrchestrationSettings(OrchestrationSettings.builtIn.applying(
            OrchestrationSettingsOverride(autoRunNextTask: false, scopeToolSetOnTaskStart: false)))
        await runtime.start()
        let store = await runtime.taskStore
        let missing = "/nonexistent-\(UUID().uuidString)"
        let task = await store.addTask(title: "t", description: "d",
                                       preconditions: [TaskPrecondition(kind: .fileExists(path: missing), origin: .smith)])
        await store.setAcceptanceCriteria(id: task.id, criteria: [AcceptanceCriterion(name: "done", origin: .user)])
        await store.setResult(id: task.id, result: "r", commentary: nil, attachments: [])
        await store.setApprovedTools(id: task.id, approvedTools: ["bash"])
        await store.driveStatus(id: task.id, to: .validating)
        await runtime.startTaskValidation(taskID: task.id)

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, await store.task(id: task.id)?.status == .validating {
            try await Task.sleep(for: .milliseconds(30))
        }
        let after = try #require(await store.task(id: task.id))
        #expect(after.status == .failed)
        #expect(after.preconditionFailure != nil, "blocked, not re-queued as if no slot were free")
        let blockedRow = await runtime.channel.allMessages().first { $0.kind == .taskBlocked }
        #expect(blockedRow?.recipientID == OrchestrationRuntime.userID, "addressed to the user, so no worker is woken by it")

        await runtime.stopAll()
    }

    @Test("A template's preconditions are filled in for each run")
    func templateRunsFillInPreconditions() async throws {
        let store = TaskStore()
        let template = await store.addTask(title: "Process {{file}}", description: "d", isTemplate: true,
                                           templateInputDefinitions: [TemplateInputDefinition(name: "file", description: "f", required: true)])
        #expect(await store.setPreconditions(id: template.id, [TaskPrecondition(kind: .fileExists(path: "/data/{{file}}"), origin: .smith)], by: .smith) == nil)
        guard case .success(let run) = await store.instantiateTemplate(templateID: template.id, inputValues: ["file": "a.csv"]) else {
            Issue.record("instantiation failed")
            return
        }
        #expect(run.preconditions.map(\.kind) == [.fileExists(path: "/data/a.csv")])
    }
}
