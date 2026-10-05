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
        let outcome = await board.sleep(for: 0.1, wait, modelEpochAtAttempt: 0)
        #expect(outcome == .elapsed)
        #expect(board.waits.isEmpty)
        #expect(recorder.snapshots.contains { $0.map(\.id) == [wait.id] }, "the wait was never published")
        #expect(recorder.snapshots.last?.isEmpty == true)
    }

    @Test("a wake ends only the sleeps of that role, early")
    func wakeIsPerRole() async {
        let board = ProviderWaitBoard()
        async let brown = board.sleep(for: 3600, Self.wait(role: .brown), modelEpochAtAttempt: 0)
        async let security = board.sleep(for: 0.5, Self.wait(role: .securityAgent), modelEpochAtAttempt: 0)
        #expect(await Self.waitUntil { board.waits.count == 2 })
        #expect(board.wakeForModelChange(of: .brown) == 1)
        #expect(await brown == .wokenForModelChange)
        #expect(await security == .elapsed, "a wake for another role ended this sleep")
        #expect(board.wakeForModelChange(of: .brown) == 0, "a finished sleep was woken twice")
    }

    /// The switch's wake can only end sleeps that exist. A change that lands while the failing
    /// attempt is still in flight must end the sleep that attempt's failure starts — otherwise a
    /// multi-day Retry-After from the OLD provider is honored in full on a model no longer in use.
    @Test("a model change during the attempt ends the retry sleep at once")
    func changeDuringAttempt() async {
        let board = ProviderWaitBoard()
        let epochAtAttempt = board.modelEpoch(of: .brown)
        #expect(board.wakeForModelChange(of: .brown) == 0, "nothing was sleeping yet")
        let outcome = await board.sleep(for: 3600, Self.wait(role: .brown), modelEpochAtAttempt: epochAtAttempt)
        #expect(outcome == .wokenForModelChange)
        #expect(board.waits.isEmpty, "a superseded sleep was published")
        // Another role's change does not cut a sleep short.
        let securityEpoch = board.modelEpoch(of: .securityAgent)
        #expect(await board.sleep(for: 0.05, Self.wait(role: .securityAgent), modelEpochAtAttempt: securityEpoch) == .elapsed)
    }

    @Test("cancelling the sleeping task ends the sleep and unpublishes it")
    func cancellation() async {
        let board = ProviderWaitBoard()
        let sleeper = Task { await board.sleep(for: 3600, Self.wait(), modelEpochAtAttempt: 0) }
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
            return await board.sleep(for: 3600, Self.wait(), modelEpochAtAttempt: 0)
        }
        #expect(await sleeper.value == .cancelled)
        #expect(board.waits.isEmpty)
    }

    @Test("waits are ordered soonest resumption first")
    func ordering() async {
        let board = ProviderWaitBoard()
        let later = Self.wait(resumesIn: 7200)
        let sooner = Self.wait(resumesIn: 60)
        async let first = board.sleep(for: 3600, later, modelEpochAtAttempt: 0)
        async let second = board.sleep(for: 3600, sooner, modelEpochAtAttempt: 0)
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

    private static let everyInput = ModelSwitchHistory.Destination(supportsVision: true, supportsDocuments: true)

    private static func toolCallTurn(_ ids: [String], text: String? = nil) -> LLMMessage {
        .assistant(from: LLMResponse(
            text: text,
            toolCalls: ids.map { LLMToolCall(id: $0, name: "bash", arguments: "{}") }
        ))
    }

    /// The tool-call ids of an assistant turn, or nil when the message is not one.
    private static func callIDs(of message: LLMMessage) -> [String]? {
        switch message.content {
        case .toolCalls(let calls), .mixed(_, let calls): return calls.map(\.id)
        case .text, .toolResult: return nil
        }
    }

    private static func resultID(of message: LLMMessage) -> String? {
        guard case .toolResult(let toolCallID, _) = message.content else { return nil }
        return toolCallID
    }

    private static func isCanonicalToolCallID(_ id: String) -> Bool {
        id.count == 9 && id.first == "c" && id.dropFirst().allSatisfy(\.isASCII) && id.dropFirst().allSatisfy(\.isNumber)
    }

    @Test("a switch drops all continuation and pairs each result with its call")
    func historyDropsContinuation() {
        var assistant = Self.toolCallTurn(["call_I6qZkxz57E4TroyICp9Zd1y9"], text: "checking")
        assistant.continuation = ProviderContinuation(
            anthropicThinkingBlocks: [AnthropicThinkingBlock(thinking: "t", signature: "s")],
            codexReasoningItems: [CodexReasoningItem(id: "r", encryptedContent: "e", summary: [])]
        )
        let history: [LLMMessage] = [
            .system("s"),
            .user("u"),
            assistant,
            .toolResult("done", callID: "call_I6qZkxz57E4TroyICp9Zd1y9")
        ]
        let adapted = ModelSwitchHistory.adapt(history, for: Self.everyInput)

        #expect(adapted.allSatisfy { $0.continuation == nil })
        #expect(adapted[2].content.textValue == "checking")
        #expect(Self.callIDs(of: adapted[2]) == ["c00000001"])
        #expect(Self.resultID(of: adapted[3]) == "c00000001")
    }

    /// Thinking blocks are not kept even between two Anthropic models: the id rewrite edits the
    /// messages before them, which Anthropic's preserved-thinking prefix check rejects, whereas a
    /// history with no thinking blocks is always accepted.
    @Test("Anthropic thinking is dropped even between two Anthropic models; reasoning text is kept")
    func historyDropsAnthropicThinking() {
        var assistant = Self.toolCallTurn(["toolu_01"])
        assistant.continuation = ProviderContinuation(
            anthropicThinkingBlocks: [AnthropicThinkingBlock(thinking: "t", signature: "s")]
        )
        assistant.reasoning = "visible reasoning"
        let adapted = ModelSwitchHistory.adapt(
            [assistant, .toolResult("ok", callID: "toolu_01")],
            for: Self.everyInput
        )
        #expect(adapted[0].continuation == nil)
        #expect(adapted[0].reasoning == "visible reasoning")
        #expect(Self.callIDs(of: adapted[0]) == ["c00000001"])
        #expect(Self.resultID(of: adapted[1]) == "c00000001")
    }

    /// Servers that number calls per response reuse `call_0` every turn. One canonical id per
    /// distinct old id would give every turn's call the same id — Anthropic rejects duplicate
    /// `tool_use` ids with a permanent 400.
    @Test("an id reused across turns becomes a distinct id per call, each result paired with its own call")
    func historyReusedIDsAcrossTurns() {
        let history: [LLMMessage] = [
            .user("u"),
            Self.toolCallTurn(["call_0"]),
            .toolResult("first", callID: "call_0"),
            Self.toolCallTurn(["call_0"], text: "again"),
            .toolResult("second", callID: "call_0"),
            .assistant(from: LLMResponse(text: "done"))
        ]
        let adapted = ModelSwitchHistory.adapt(history, for: Self.everyInput)

        #expect(Self.callIDs(of: adapted[1]) == ["c00000001"])
        #expect(Self.resultID(of: adapted[2]) == "c00000001")
        #expect(Self.callIDs(of: adapted[3]) == ["c00000002"])
        #expect(Self.resultID(of: adapted[4]) == "c00000002")
        #expect(adapted[5].content == .text("done"))
    }

    @Test("parallel results answered out of order and duplicate ids within one turn pair by position")
    func historyParallelAndDuplicateIDs() {
        let history: [LLMMessage] = [
            Self.toolCallTurn(["a", "b"]),
            .toolResult("for b", callID: "b"),
            .toolResult("for a", callID: "a"),
            Self.toolCallTurn(["x", "x"]),
            .toolResult("first x", callID: "x"),
            .toolResult("second x", callID: "x")
        ]
        let adapted = ModelSwitchHistory.adapt(history, for: Self.everyInput)

        #expect(Self.callIDs(of: adapted[0]) == ["c00000001", "c00000002"])
        #expect(Self.resultID(of: adapted[1]) == "c00000002")
        #expect(Self.resultID(of: adapted[2]) == "c00000001")
        #expect(Self.callIDs(of: adapted[3]) == ["c00000003", "c00000004"])
        #expect(Self.resultID(of: adapted[4]) == "c00000003")
        #expect(Self.resultID(of: adapted[5]) == "c00000004")
    }

    @Test("a result with no unanswered call keeps a unique id of its own")
    func historyOrphanResults() {
        let history: [LLMMessage] = [
            .toolResult("orphan", callID: "gone"),
            Self.toolCallTurn(["a"]),
            .toolResult("answer", callID: "a"),
            .toolResult("second answer to the same call", callID: "a"),
            Self.toolCallTurn(["b"]),
            .toolResult("answers an earlier turn", callID: "a"),
            .toolResult("answer", callID: "b")
        ]
        let adapted = ModelSwitchHistory.adapt(history, for: Self.everyInput)

        #expect(Self.resultID(of: adapted[0]) == "c00000001")
        #expect(Self.callIDs(of: adapted[1]) == ["c00000002"])
        #expect(Self.resultID(of: adapted[2]) == "c00000002")
        #expect(Self.resultID(of: adapted[3]) == "c00000003")
        #expect(Self.callIDs(of: adapted[4]) == ["c00000004"])
        #expect(Self.resultID(of: adapted[5]) == "c00000005")
        #expect(Self.resultID(of: adapted[6]) == "c00000004")
    }

    @Test("a result after an intervening assistant text message still pairs with its call")
    func historyResultAfterAssistantText() {
        let history: [LLMMessage] = [
            Self.toolCallTurn(["a"]),
            .assistant(from: LLMResponse(text: "narration")),
            .toolResult("late", callID: "a")
        ]
        let adapted = ModelSwitchHistory.adapt(history, for: Self.everyInput)
        #expect(Self.callIDs(of: adapted[0]) == ["c00000001"])
        #expect(Self.resultID(of: adapted[2]) == "c00000001")
    }

    @Test("adapting is deterministic and a second switch reissues the same ids")
    func historySecondSwitchIsStable() {
        let history: [LLMMessage] = [
            .toolResult("orphan", callID: "gone"),
            Self.toolCallTurn(["call_0", "call_0"]),
            .toolResult("1", callID: "call_0"),
            .toolResult("2", callID: "call_0"),
            Self.toolCallTurn(["call_0"], text: "t"),
            .toolResult("3", callID: "call_0")
        ]
        let once = ModelSwitchHistory.adapt(history, for: Self.everyInput)
        #expect(ModelSwitchHistory.adapt(history, for: Self.everyInput) == once)
        #expect(ModelSwitchHistory.adapt(once, for: Self.everyInput) == once)

        let allIDs = once.flatMap { Self.callIDs(of: $0) ?? [] } + once.compactMap { Self.resultID(of: $0) }
        #expect(allIDs.allSatisfy(Self.isCanonicalToolCallID))
        let callIDs = once.flatMap { Self.callIDs(of: $0) ?? [] }
        #expect(Set(callIDs).count == callIDs.count, "tool-call ids must be unique")
        let resultIDs = once.compactMap { Self.resultID(of: $0) }
        #expect(Set(resultIDs).count == resultIDs.count, "tool-result ids must be unique")
    }

    @Test("media the new model cannot take is removed, with a note left in its place")
    func mediaRemoval() {
        let image = LLMImageContent(data: Data([1, 2, 3]), mimeType: "image/png")
        let document = LLMDocumentContent(data: Data([4, 5]), mimeType: "application/pdf", filename: "spec.pdf")
        let history: [LLMMessage] = [.user("look at this", images: [image], documents: [document])]

        let adapted = ModelSwitchHistory.adapt(history, for: .init(supportsVision: false, supportsDocuments: false))
        #expect(adapted[0].images == nil)
        #expect(adapted[0].documents == nil)
        #expect(adapted[0].content.textValue?.contains("1 image(s) removed") == true)
        #expect(adapted[0].content.textValue?.contains("1 document(s) removed") == true)
        #expect(adapted[0].content.textValue?.hasPrefix("look at this") == true)

        let kept = ModelSwitchHistory.adapt(history, for: .init(supportsVision: true, supportsDocuments: false))
        #expect(kept[0].images?.count == 1)
        #expect(kept[0].documents == nil)
        #expect(kept[0].content.textValue?.contains("image(s) removed") == false)
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
