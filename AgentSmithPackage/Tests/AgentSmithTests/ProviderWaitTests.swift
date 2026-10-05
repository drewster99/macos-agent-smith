import Foundation
import Testing
import SemanticSearch
@testable import AgentSmithKit

/// Retry sleeps are a visible, wakeable state.
///
/// On 2026-10-04 a Codex weekly usage limit (`resets_in_seconds` ≈ 4.8 days) put every agent of a
/// session to sleep. The UI showed Smith "Idle", one worker "Thinking" for 700+ minutes and the
/// Security Agent "Evaluating" for 600+, the Security Agent's own wait was never mentioned in the
/// transcript, and the only rescue — another model — could not reach a live agent. Pinned here:
///
/// 1. `ProviderWaitBoard` publishes a wait for exactly the length of the sleep, ends it once, and
///    wakes by role.
/// 2. `LLMRetryPolicy.waitReason` is typed from the failure, never its prose.
/// 3. `ModelSwitchHistory` makes a conversation portable to another model.
/// 4. Every holder — agent, Security Agent review, validator, summarizer — publishes its waits and
///    retries on the new model when woken, and the runtime wires its board into the holders it
///    builds and wakes them from `setProviders`.
@Suite("Provider waits", .serialized)
struct ProviderWaitTests {

    private static let sharedEngine = SemanticSearchEngine()

    private static func wait(
        role: AgentRole = .brown,
        resumesIn seconds: TimeInterval = 3600,
        purpose: ProviderWaitPurpose = .agentTurn
    ) -> ProviderWait {
        ProviderWait(
            holder: ProviderWaitHolder(role: role, purpose: purpose),
            reason: .rateLimited,
            providerID: "p",
            modelID: "m",
            streakStartedAt: Date(),
            resumesAt: Date().addingTimeInterval(seconds),
            attempt: 1
        )
    }

    private static func usageLimit429(resetsIn seconds: Int) -> LLMProviderError {
        let resetsAt = Int(Date().timeIntervalSince1970) + seconds
        let body = #"{"error":{"type":"usage_limit_reached","message":"The usage limit has been reached","plan_type":"prolite","resets_at":"# + "\(resetsAt)" + #","limit_window_minutes":10080,"resets_in_seconds":"# + "\(seconds)" + "}}"
        return .httpError(statusCode: 429, body: body, url: nil, retryAfter: nil)
    }

    private static func waitUntil(_ condition: @Sendable () async -> Bool, seconds: TimeInterval = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    // MARK: - Board

    @Test("a wait is published for the sleep and removed when it elapses")
    func publishedForTheSleep() async {
        let board = ProviderWaitBoard()
        let recorder = SnapshotRecorder()
        board.setOnChange { recorder.record($0) }
        let wait = Self.wait(resumesIn: 0.1)
        let outcome = await board.sleep(for: 0.1, wait)
        #expect(outcome == .elapsed)
        #expect(board.waits.isEmpty)
        #expect(recorder.snapshots.contains { $0.map(\.id) == [wait.id] }, "the wait was never published")
        #expect(recorder.snapshots.last?.isEmpty == true)
    }

    @Test("a wake ends only the sleeps of that role, early")
    func wakeIsPerRole() async {
        let board = ProviderWaitBoard()
        async let brown = board.sleep(for: 3600, Self.wait(role: .brown))
        async let security = board.sleep(for: 0.5, Self.wait(role: .securityAgent))
        #expect(await Self.waitUntil { board.waits.count == 2 })
        #expect(board.wakeForModelChange(of: .brown) == 1)
        #expect(await brown == .wokenForModelChange)
        #expect(await security == .elapsed, "a wake for another role ended this sleep")
        #expect(board.wakeForModelChange(of: .brown) == 0, "a finished sleep was woken twice")
    }

    @Test("cancelling the sleeping task ends the sleep and unpublishes it")
    func cancellation() async {
        let board = ProviderWaitBoard()
        let sleeper = Task { await board.sleep(for: 3600, Self.wait()) }
        #expect(await Self.waitUntil { board.waits.count == 1 })
        sleeper.cancel()
        #expect(await sleeper.value == .cancelled)
        #expect(board.waits.isEmpty)
    }

    @Test("a task cancelled before it sleeps does not sleep")
    func cancelledBeforeSleeping() async {
        let board = ProviderWaitBoard()
        let sleeper = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await board.sleep(for: 3600, Self.wait())
        }
        #expect(await sleeper.value == .cancelled)
        #expect(board.waits.isEmpty)
    }

    @Test("waits are ordered soonest resumption first")
    func ordering() async {
        let board = ProviderWaitBoard()
        let later = Self.wait(resumesIn: 7200)
        let sooner = Self.wait(resumesIn: 60)
        async let first = board.sleep(for: 3600, later)
        async let second = board.sleep(for: 3600, sooner)
        #expect(await Self.waitUntil { board.waits.count == 2 })
        #expect(board.waits.map(\.id) == [sooner.id, later.id])
        board.wakeForModelChange(of: .brown)
        _ = await (first, second)
    }

    // MARK: - Reason

    @Test("wait reasons are read from the typed failure")
    func waitReasons() {
        #expect(LLMRetryPolicy.waitReason(for: Self.usageLimit429(resetsIn: 411_320)) == .usageLimitReached)
        #expect(LLMRetryPolicy.waitReason(for: LLMProviderError.httpError(statusCode: 429, body: "{}", url: nil, retryAfter: nil)) == .rateLimited)
        #expect(LLMRetryPolicy.waitReason(for: LLMProviderError.httpError(statusCode: 503, body: "", url: nil, retryAfter: 30)) == .serverRequestedDelay)
        #expect(LLMRetryPolicy.waitReason(for: LLMProviderError.httpError(statusCode: 502, body: "", url: nil, retryAfter: nil)) == .serverError)
        #expect(LLMRetryPolicy.waitReason(for: URLError(.timedOut)) == .networkError)
        #expect(LLMRetryPolicy.waitReason(for: LLMProviderError.malformedResponse(detail: "x")) == .transientError)
    }

    @Test("announcement: stated waits on the first attempt, blips only once they persist")
    func announcementThreshold() {
        func wait(_ reason: ProviderWaitReason, attempt: Int) -> ProviderWait {
            ProviderWait(holder: ProviderWaitHolder(role: .securityAgent, purpose: .toolScoping), reason: reason,
                         providerID: nil, modelID: nil, streakStartedAt: Date(), resumesAt: Date(), attempt: attempt)
        }
        #expect(wait(.usageLimitReached, attempt: 1).warrantsAnnouncement)
        #expect(!wait(.usageLimitReached, attempt: 2).warrantsAnnouncement)
        #expect(!wait(.serverError, attempt: 1).warrantsAnnouncement)
        #expect(wait(.serverError, attempt: 5).warrantsAnnouncement)
    }

    // MARK: - History portability

    @Test("a switch across API families drops continuation and remaps tool-call ids consistently")
    func historyAcrossFamilies() {
        let continuation = ProviderContinuation(
            anthropicThinkingBlocks: [AnthropicThinkingBlock(thinking: "t", signature: "s")],
            codexReasoningItems: nil
        )
        var assistant = LLMMessage.assistant(from: LLMResponse(
            text: "checking",
            toolCalls: [LLMToolCall(id: "call_I6qZkxz57E4TroyICp9Zd1y9", name: "bash", arguments: "{}")]
        ))
        assistant.continuation = continuation
        let history: [LLMMessage] = [
            .system("s"),
            .user("u"),
            assistant,
            .toolResult("done", callID: "call_I6qZkxz57E4TroyICp9Zd1y9")
        ]
        let adapted = ModelSwitchHistory.adapt(history, for: .init(
            previousAPIType: .codexChatGPT, apiType: .anthropic, supportsVision: true, supportsDocuments: true))

        #expect(adapted.allSatisfy { $0.continuation == nil })
        guard case .mixed(_, let calls) = adapted[2].content,
              case .toolResult(let resultID, _) = adapted[3].content else {
            Issue.record("unexpected content shapes: \(adapted.map(\.content))")
            return
        }
        #expect(calls.first?.id == resultID, "a call and its result no longer pair")
        #expect(resultID == "c00000001")
        #expect(resultID.count == 9 && resultID.allSatisfy { $0.isLetter || $0.isNumber })
    }

    @Test("a switch within one API family keeps Anthropic thinking and the ids")
    func historyWithinFamily() {
        var assistant = LLMMessage.assistant(from: LLMResponse(
            text: nil,
            toolCalls: [LLMToolCall(id: "toolu_01", name: "bash", arguments: "{}")]
        ))
        assistant.continuation = ProviderContinuation(
            anthropicThinkingBlocks: [AnthropicThinkingBlock(thinking: "t", signature: "s")],
            codexReasoningItems: [CodexReasoningItem(id: "r", encryptedContent: "e", summary: [])]
        )
        let adapted = ModelSwitchHistory.adapt([assistant], for: .init(
            previousAPIType: .anthropic, apiType: .anthropic, supportsVision: true, supportsDocuments: true))
        #expect(adapted[0].continuation?.anthropicThinkingBlocks?.count == 1)
        #expect(adapted[0].continuation?.codexReasoningItems == nil)
        guard case .toolCalls(let calls) = adapted[0].content else {
            Issue.record("unexpected content shape")
            return
        }
        #expect(calls.first?.id == "toolu_01")
    }

    @Test("media the new model cannot take is removed, with a note left in its place")
    func mediaRemoval() {
        let image = LLMImageContent(data: Data([1, 2, 3]), mimeType: "image/png")
        let history: [LLMMessage] = [.user("look at this", images: [image], documents: [])]
        let adapted = ModelSwitchHistory.adapt(history, for: .init(
            previousAPIType: .anthropic, apiType: .openAICompatible, supportsVision: false, supportsDocuments: false))
        #expect(adapted[0].images == nil)
        #expect(adapted[0].content.textValue?.contains("1 image(s) removed") == true)
        #expect(adapted[0].content.textValue?.hasPrefix("look at this") == true)

        let kept = ModelSwitchHistory.adapt(history, for: .init(
            previousAPIType: .anthropic, apiType: .openAICompatible, supportsVision: true, supportsDocuments: false))
        #expect(kept[0].images?.count == 1)
    }

    // MARK: - Holders

    @Test("a Security Agent review publishes its wait for the held worker and restarts on a new model")
    func securityReviewWait() async throws {
        let board = ProviderWaitBoard()
        let exhausted = ScriptedProvider([.fail(Self.usageLimit429(resetsIn: 411_320))])
        let channel = MessageChannel()
        let evaluator = SecurityEvaluator(
            provider: exhausted,
            systemPrompt: "test",
            channel: channel,
            abort: { _, _ in },
            hasToolSucceeded: { _ in false },
            hasToolFailed: { _ in false },
            providerWaitBoard: board
        )
        let workerID = UUID()
        let review = Task {
            await evaluator.evaluate(
                toolName: "bash", toolParams: "{\"command\":\"ls\"}", toolDescription: "Run a shell command",
                toolParameterDefs: "", taskTitle: "t", taskID: UUID().uuidString, taskDescription: "d",
                siblingCalls: nil, agentRoleName: "Brown", callerRole: .brown, toolGroupDescription: nil,
                evaluatingForAgentID: workerID
            )
        }
        #expect(await Self.waitUntil { !board.waits.isEmpty })
        let wait = try #require(board.waits.first)
        #expect(wait.reason == .usageLimitReached)
        #expect(wait.holder.role == .securityAgent)
        #expect(wait.holder.purpose.heldAgentID == workerID)
        #expect(wait.resumesAt.timeIntervalSinceNow > 400_000)
        let announced = await channel.allMessages().contains { $0.content.contains("usage limit reached") }
        #expect(announced, "a multi-day Security Agent wait was not announced in the transcript")

        let replacement = MockLLMProvider(responses: [LLMResponse(text: "SAFE: read-only listing")])
        await evaluator.applyModel(SecurityEvaluatorModel(
            provider: replacement, configuration: nil, providerType: "test", supportsVision: false, supportsDocuments: false))
        #expect(board.wakeForModelChange(of: .securityAgent) == 1)
        let disposition = await review.value
        #expect(disposition.approved, "the woken review did not complete on the new model: \(disposition)")
        #expect(replacement.callCount == 1)
    }

    @Test("a validator's provider wait does not count against its timeout, and a model change interrupts it")
    func validatorWait() async {
        // Waiting 1.5 s on a definition whose timeout is 1 s: the run must still succeed.
        let slowStart = ScriptedProvider([
            .fail(.httpError(statusCode: 503, body: "", url: nil, retryAfter: 1.5)),
            .respond(LLMResponse(text: "ACCEPT"))
        ])
        let definition = EvaluatorDefinition(
            name: "v", description: "v", kind: .validator, systemPrompt: "judge",
            outputGrammar: .verdictLine(allowed: [.init(token: "ACCEPT", requiresReason: false)]),
            toolNames: [], maxTurns: 4, timeoutSeconds: 1
        )
        let board = ProviderWaitBoard()
        let context = ProviderWaitContext(
            board: board,
            holder: ProviderWaitHolder(role: .validator, purpose: .criterionValidation),
            providerID: "p", modelID: "m"
        )
        let run = await EvaluationRunner.runMessages(
            definition: definition, systemPrompt: "judge", userMessage: "{}", provider: slowStart,
            tools: [], toolContext: TestToolContext.make(), providerWait: context
        )
        #expect(run.outcome == .verdict(token: "ACCEPT", reason: nil), "the provider wait was charged to the timeout")
        #expect(run.interruption == nil)

        let exhausted = ScriptedProvider([.fail(Self.usageLimit429(resetsIn: 411_320))])
        let interrupted = Task {
            await EvaluationRunner.runMessages(
                definition: definition, systemPrompt: "judge", userMessage: "{}", provider: exhausted,
                tools: [], toolContext: TestToolContext.make(), providerWait: context
            )
        }
        #expect(await Self.waitUntil { !board.waits.isEmpty })
        board.wakeForModelChange(of: .validator)
        #expect(await interrupted.value.interruption == .modelChanged)
    }

    @Test("the summarizer retries on the model it is switched to while waiting")
    func summarizerWait() async {
        let board = ProviderWaitBoard()
        let exhausted = ScriptedProvider([.fail(Self.usageLimit429(resetsIn: 411_320))])
        let summarizer = TaskSummarizer(
            provider: exhausted,
            memoryStore: MemoryStore(engine: Self.sharedEngine),
            channel: MessageChannel(),
            contextWindowSize: 100_000,
            maxOutputTokens: 1_000
        )
        await summarizer.setProviderWaitBoard(board)
        let extraction = Task {
            await summarizer.extractWebContent(content: "The answer is 42.", prompt: "What is the answer?", taskID: nil, taskTitle: nil)
        }
        #expect(await Self.waitUntil { board.waits.first?.holder.purpose == .webContentExtraction })

        let replacement = MockLLMProvider(responses: [LLMResponse(text: "42")])
        await summarizer.applyModel(
            provider: replacement,
            configuration: ModelConfiguration(name: "r", providerID: "r", modelID: "r", maxOutputTokens: 1_000, maxContextTokens: 100_000),
            providerType: "test"
        )
        board.wakeForModelChange(of: .summarizer)
        #expect(await extraction.value == "42")
    }

    // MARK: - Runtime

    @Test("the runtime publishes a live agent's wait and setProviders wakes it onto the new model")
    func runtimeWakesOnModelChange() async throws {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-smith-provider-wait-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        let config = ModelConfiguration(name: "a", providerID: "codex", modelID: "exhausted", maxOutputTokens: 1_024, maxContextTokens: 100_000)
        let runtime = OrchestrationRuntime(
            providers: [
                .smith: ScriptedProvider([.fail(Self.usageLimit429(resetsIn: 411_320))]),
                .securityAgent: MockLLMProvider(responses: [LLMResponse(text: "SAFE")])
            ],
            configurations: [.smith: config, .securityAgent: config],
            providerAPITypes: [.smith: .codexChatGPT, .securityAgent: .codexChatGPT],
            agentTuning: [.smith: AgentTuningConfig(pollInterval: 0.2, messageDebounceInterval: 0)],
            semanticSearchEngine: Self.sharedEngine,
            usageStore: UsageStore(persistence: PersistenceManager(testingRoot: tmpRoot)),
            autoAdvanceEnabled: false,
            autoRunInterruptedTasks: false,
            memoryStore: nil
        )
        let recorder = SnapshotRecorder()
        runtime.setOnProviderWaitsChanged { recorder.record($0) }
        await runtime.start()
        defer { Task { await runtime.stopAll() } }
        await runtime.sendUserMessage("hello")

        #expect(await Self.waitUntil({ runtime.providerWaitBoard.waits.contains { $0.holder.role == .smith } }, seconds: 5))
        let wait = try #require(runtime.providerWaitBoard.waits.first { $0.holder.role == .smith })
        #expect(wait.reason == .usageLimitReached)
        #expect(wait.modelID == "exhausted")
        #expect(recorder.snapshots.contains { !$0.isEmpty }, "the app-side observer never heard about the wait")

        let replacement = MockLLMProvider(responses: [LLMResponse(text: "Hello.")])
        await runtime.setProviders(
            providers: [.smith: replacement],
            configurations: [.smith: ModelConfiguration(name: "b", providerID: "anthropic", modelID: "fresh", maxOutputTokens: 1_024, maxContextTokens: 100_000)],
            apiTypes: [.smith: .anthropic]
        )
        #expect(await Self.waitUntil { replacement.callCount > 0 }, "Smith slept on after its model changed")
        #expect(runtime.providerWaitBoard.waits.allSatisfy { $0.holder.role != .smith })
    }
}

/// Collects board snapshots from its synchronous observer.
private final class SnapshotRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [[ProviderWait]] = []
    func record(_ snapshot: [ProviderWait]) { lock.withLock { collected.append(snapshot) } }
    var snapshots: [[ProviderWait]] { lock.withLock { collected } }
}
