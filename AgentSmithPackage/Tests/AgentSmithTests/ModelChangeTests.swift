import Foundation
import Testing
import SemanticSearch
@testable import AgentSmithKit

/// A live agent follows its role's model assignment: a RETUNE (temperature, effort, thinking,
/// token caps) and a SWITCH to a different model or provider both reach it, applied at a turn
/// boundary so no single turn spans two configurations, and the conversation is kept. Before
/// 2026-10-05 a switch never reached a live agent, so a worker stuck on an exhausted provider could
/// only be rescued by stopping it.
///
/// Pinned here:
///
/// 1. A change is staged, then applied at the loop boundary, and the next call uses the new provider.
/// 2. A switch adapts the conversation (`ModelSwitchHistory`) and is announced.
/// 3. `setProviders` delivers retunes and switches to the live Smith.
/// 4. An agent sleeping out a provider wait is woken by a switch and retries on the new model at once.
///
/// Not pinned, deliberately: that an UNCHANGED configuration skips the change. Its failure mode is
/// a performance regression rather than a wrong answer (a needless swap discards a provider's
/// per-instance prefix-cache key), and it has no observable signal from outside the actor.
@Suite("Model change")
struct ModelChangeTests {

    private static let sharedEngine = SemanticSearchEngine()

    private static func config(temperature: Double, modelID: String = "test-model") -> ModelConfiguration {
        ModelConfiguration(
            name: "test",
            providerID: "test",
            modelID: modelID,
            temperature: temperature,
            maxOutputTokens: 1024,
            maxContextTokens: 100_000
        )
    }

    private static func makeAgent(
        provider: any LLMProvider,
        llmConfig: ModelConfiguration,
        channel: MessageChannel = MessageChannel()
    ) -> AgentActor {
        let agentID = UUID()
        let context = ToolContext(
            agentID: agentID,
            agentRole: .brown,
            channel: channel,
            taskStore: TaskStore(),
            currentConfiguration: llmConfig,
            currentProviderType: ProviderAPIType.openAICompatible.rawValue,
            spawnBrown: { nil },
            terminateAgent: { _, _ in false },
            abort: { _, _ in },
            agentRoleForID: { _ in .brown },
            memoryStore: MemoryStore(engine: sharedEngine),
            setToolExecutionStatus: { _, _ in },
            hasToolSucceeded: { _ in false },
            hasToolFailed: { _ in false }
        )
        return AgentActor(
            id: agentID,
            configuration: AgentConfiguration(
                role: .brown,
                llmConfig: llmConfig,
                systemPrompt: "test-system",
                // Short so the loop reaches its next top-of-iteration boundary promptly; the
                // default five seconds outlasts a test deadline.
                pollInterval: 0.2,
                messageDebounceInterval: 0,
                supportsVision: true,
                supportsDocuments: false
            ),
            provider: provider,
            tools: [],
            toolContext: context
        )
    }

    // MARK: - AgentConfiguration

    @Test("A retune rewrites the model fields and preserves everything the model does not own")
    func retunePreservesNonModelFields() {
        var configuration = AgentConfiguration(
            role: .smith,
            llmConfig: Self.config(temperature: 0.2),
            providerAPIType: .openAICompatible,
            systemPrompt: "keep-me",
            toolNames: ["a", "b"],
            requiresToolApproval: true,
            suppressesRawTextToChannel: true,
            pollInterval: 11,
            messageDebounceInterval: 3,
            maxToolCallsPerIteration: 7,
            supportsVision: true,
            supportsDocuments: true
        )

        configuration.applyModelChange(
            llmConfig: Self.config(temperature: 0.9),
            providerAPIType: .anthropic,
            supportsVision: nil,
            supportsDocuments: nil
        )

        #expect(configuration.llmConfig.temperature == 0.9)
        #expect(configuration.providerAPIType == .anthropic)
        // Nil says nothing about a capability, which is not the same as saying false.
        #expect(configuration.supportsVision == true)
        #expect(configuration.supportsDocuments == true)
        // Everything the model does not own survives.
        #expect(configuration.role == .smith)
        #expect(configuration.systemPrompt == "keep-me")
        #expect(configuration.toolNames == ["a", "b"])
        #expect(configuration.requiresToolApproval == true)
        #expect(configuration.suppressesRawTextToChannel == true)
        #expect(configuration.pollInterval == 11)
        #expect(configuration.messageDebounceInterval == 3)
        #expect(configuration.maxToolCallsPerIteration == 7)
    }

    @Test("A resolved capability overrides the current value")
    func retuneAppliesResolvedCapabilities() {
        var configuration = AgentConfiguration(
            role: .brown,
            llmConfig: Self.config(temperature: 0.2),
            supportsVision: true,
            supportsDocuments: false
        )
        configuration.applyModelChange(
            llmConfig: Self.config(temperature: 0.2),
            providerAPIType: .openAICompatible,
            supportsVision: false,
            supportsDocuments: true
        )
        #expect(configuration.supportsVision == false)
        #expect(configuration.supportsDocuments == true)
    }

    // MARK: - AgentActor

    @Test("A retune is staged, then applied at the loop boundary, and the next call uses the new provider")
    func retuneIsStagedThenAppliedAtTheBoundary() async throws {
        let before = MockLLMProvider(responses: [LLMResponse(text: "ok")])
        let after = MockLLMProvider(responses: [LLMResponse(text: "ok")])
        let agent = Self.makeAgent(provider: before, llmConfig: Self.config(temperature: 0.2))

        await agent.scheduleModelChange(AgentActor.ModelChange(
            provider: after,
            llmConfig: Self.config(temperature: 0.9),
            providerAPIType: .openAICompatible,
            supportsVision: nil,
            supportsDocuments: nil,
            generation: 1
        ))

        // Something to answer, so the loop actually reaches `provider.send` rather than idling.
        await agent.appendUserMessage("say ok")

        let stagedTemperature = await agent.configuration.llmConfig.temperature
        #expect(
            stagedTemperature == 0.2,
            "the retune was applied on arrival — a turn already in flight would then straddle two configurations"
        )

        await agent.start()
        let deadline = Date().addingTimeInterval(3.0)
        while await agent.running, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        await agent.stop()

        let appliedTemperature = await agent.configuration.llmConfig.temperature
        #expect(appliedTemperature == 0.9, "the staged retune was never applied at the loop boundary")
        #expect(after.callCount > 0, "the agent kept calling the provider it was built with")
        #expect(before.callCount == 0, "a call went to the pre-retune provider after the boundary")
    }

    @Test("A model switch is applied at the boundary and keeps the conversation")
    func modelSwitchIsAppliedAndKeepsTheConversation() async throws {
        let before = MockLLMProvider(responses: [LLMResponse(text: "ok")])
        let after = MockLLMProvider(responses: [LLMResponse(text: "ok")])
        let agent = Self.makeAgent(provider: before, llmConfig: Self.config(temperature: 0.2))

        await agent.scheduleModelChange(AgentActor.ModelChange(
            provider: after,
            llmConfig: Self.config(temperature: 0.2, modelID: "a-different-model"),
            providerAPIType: .anthropic,
            supportsVision: nil,
            supportsDocuments: nil,
            generation: 1
        ))
        await agent.appendUserMessage("say ok")
        #expect(await agent.configuration.llmConfig.modelID == "test-model", "a switch must wait for the boundary")

        await agent.start()
        let deadline = Date().addingTimeInterval(3.0)
        while after.callCount == 0, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        await agent.stop()

        #expect(await agent.configuration.llmConfig.modelID == "a-different-model")
        #expect(await agent.configuration.providerAPIType == .anthropic)
        #expect(before.callCount == 0, "a call went to the old model after the switch")
        let sent = try #require(after.receivedMessages.first)
        #expect(sent.contains { $0.content.textValue?.contains("say ok") == true }, "the conversation did not survive the switch")
    }

    @Test("A model switch is announced to the transcript without waking any agent")
    func modelSwitchAnnouncementWakesNoAgent() async throws {
        let channel = MessageChannel()
        let before = MockLLMProvider(responses: [LLMResponse(text: "ok")])
        let after = MockLLMProvider(responses: [LLMResponse(text: "ok")])
        let agent = Self.makeAgent(provider: before, llmConfig: Self.config(temperature: 0.2), channel: channel)
        // Subscribed the way the runtime subscribes Smith and every worker, so the agent would
        // receive its own announcement if agents ingested it.
        let subscriptionID = await channel.subscribe { [weak agent] message in
            guard let agent else { return }
            Task { await agent.receiveChannelMessage(message) }
        }
        await agent.scheduleModelChange(AgentActor.ModelChange(
            provider: after,
            llmConfig: Self.config(temperature: 0.2, modelID: "a-different-model"),
            providerAPIType: .openAICompatible,
            supportsVision: nil,
            supportsDocuments: nil,
            generation: 1
        ))
        await agent.start()
        let deadline = Date().addingTimeInterval(3.0)
        while await channel.allMessages().contains(where: { $0.kind == .modelSwitched }) == false, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(await channel.allMessages().filter { $0.kind == .modelSwitched }.count == 1, "the switch was not announced exactly once")
        // Several poll intervals: long enough for a delivered announcement to have woken the agent.
        try await Task.sleep(for: .milliseconds(600))
        await agent.stop()
        await channel.unsubscribe(subscriptionID)
        #expect(after.callCount == 0, "the announcement woke the agent for an LLM turn")
        let history = await agent.contextSnapshot()
        #expect(history.contains { $0.content.textValue?.contains("a-different-model") == true }, "the agent was not told its model changed")
    }

    /// Snapshots the channel at its first call: what had been posted before the new model ran.
    private final class ChannelSnapshotProvider: LLMProvider, @unchecked Sendable {
        private let channel: MessageChannel
        private let lock = NSLock()
        private var _messagesAtFirstCall: [ChannelMessage]?
        init(channel: MessageChannel) { self.channel = channel }
        var messagesAtFirstCall: [ChannelMessage]? { lock.withLock { _messagesAtFirstCall } }
        func send(messages: [LLMMessage], tools: [LLMToolDefinition], overrides: LLMCallOverrides) async throws -> LLMResponse {
            let posted = await channel.allMessages()
            lock.withLock { if _messagesAtFirstCall == nil { _messagesAtFirstCall = posted } }
            return LLMResponse(text: "ok")
        }
    }

    @Test("A model switch is in the transcript before the new model's first call")
    func modelSwitchAnnouncementPrecedesTheNewModel() async throws {
        let channel = MessageChannel()
        let before = MockLLMProvider(responses: [LLMResponse(text: "ok")])
        let after = ChannelSnapshotProvider(channel: channel)
        let agent = Self.makeAgent(provider: before, llmConfig: Self.config(temperature: 0.2), channel: channel)
        await agent.scheduleModelChange(AgentActor.ModelChange(
            provider: after,
            llmConfig: Self.config(temperature: 0.2, modelID: "a-different-model"),
            providerAPIType: .openAICompatible,
            supportsVision: nil,
            supportsDocuments: nil,
            generation: 1
        ))
        await agent.appendUserMessage("say ok")
        await agent.start()
        let deadline = Date().addingTimeInterval(3.0)
        while after.messagesAtFirstCall == nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        await agent.stop()
        let posted = try #require(after.messagesAtFirstCall, "the new model was never called")
        #expect(posted.filter { $0.kind == .modelSwitched }.count == 1, "the new model ran before its switch was announced")
    }

    @Test("A model change wakes an agent sleeping out a provider wait, and it retries on the new model")
    func modelChangeWakesAProviderWait() async throws {
        let board = ProviderWaitBoard()
        let exhausted = ScriptedProvider([
            .fail(.httpError(statusCode: 429, body: "{}", url: nil, retryAfter: 3600))
        ])
        let replacement = MockLLMProvider(responses: [LLMResponse(text: "ok")])
        let agent = Self.makeAgent(provider: exhausted, llmConfig: Self.config(temperature: 0.2))
        await agent.setProviderWaitBoard(board)
        await agent.appendUserMessage("say ok")
        await agent.start()

        // The agent publishes its wait for the whole hour instead of reading as idle.
        let waitDeadline = Date().addingTimeInterval(3.0)
        while board.waits.isEmpty, Date() < waitDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let wait = try #require(board.waits.first)
        #expect(wait.reason == .rateLimited)
        #expect(wait.holder.role == .brown)
        #expect(wait.holder.purpose == .agentTurn)
        #expect(wait.resumesAt.timeIntervalSinceNow > 3000)

        await agent.scheduleModelChange(AgentActor.ModelChange(
            provider: replacement,
            llmConfig: Self.config(temperature: 0.2, modelID: "a-different-model"),
            providerAPIType: .openAICompatible,
            supportsVision: nil,
            supportsDocuments: nil,
            generation: 1
        ))
        #expect(board.wakeForModelChange(of: .brown) == 1)

        let retryDeadline = Date().addingTimeInterval(3.0)
        while replacement.callCount == 0, Date() < retryDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        await agent.stop()
        #expect(replacement.callCount > 0, "the woken agent did not retry on the new model")
        #expect(board.waits.isEmpty)
    }

    // MARK: - OrchestrationRuntime dispatch

    private func makeRuntime() -> OrchestrationRuntime {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-smith-retune-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        return OrchestrationRuntime(
            providers: [
                .smith: MockLLMProvider(responses: [LLMResponse(text: "Standing by.")]),
                .securityAgent: MockLLMProvider(responses: [LLMResponse(text: "SAFE")])
            ],
            configurations: [
                .smith: Self.config(temperature: 0.2),
                .securityAgent: Self.config(temperature: 0.2)
            ],
            providerAPITypes: [:],
            // Short poll so Smith's loop reaches the boundary that applies a staged retune well
            // inside a test deadline; the default five seconds does not.
            agentTuning: [.smith: AgentTuningConfig(pollInterval: 0.5, messageDebounceInterval: 0)],
            semanticSearchEngine: Self.sharedEngine,
            usageStore: UsageStore(persistence: PersistenceManager(testingRoot: tmpRoot)),
            autoAdvanceEnabled: false,
            autoRunInterruptedTasks: false,
            memoryStore: nil
        )
    }

    /// Reads the live Smith's temperature, after giving its loop a chance to reach the boundary
    /// where a staged retune is applied.
    private func smithTemperature(_ runtime: OrchestrationRuntime) async -> Double? {
        guard let smithID = await runtime.agentIDForRole(.smith) else { return nil }
        let deadline = Date().addingTimeInterval(3.0)
        var temperature: Double?
        while Date() < deadline {
            guard let smith = await runtime.liveAgent(id: smithID) else { return nil }
            temperature = await smith.configuration.llmConfig.temperature
            if temperature == 0.9 { return temperature }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return temperature
    }

    @Test("A parameter change reaches the live Smith without restarting it")
    func parameterChangeRetunesLiveSmith() async {
        let runtime = makeRuntime()
        await runtime.start()
        defer { Task { await runtime.stopAll() } }

        await runtime.setProviders(
            providers: [.smith: MockLLMProvider(responses: [LLMResponse(text: "Standing by.")])],
            configurations: [.smith: Self.config(temperature: 0.9)],
            apiTypes: [.smith: .openAICompatible]
        )

        #expect(await smithTemperature(runtime) == 0.9, "a retune never reached the live Smith")
    }

    @Test("A model change reaches the live Smith without restarting it")
    func modelChangeReachesLiveSmith() async {
        let runtime = makeRuntime()
        await runtime.start()
        defer { Task { await runtime.stopAll() } }
        let smithIDBefore = await runtime.agentIDForRole(.smith)

        await runtime.setProviders(
            providers: [.smith: MockLLMProvider(responses: [LLMResponse(text: "Standing by.")])],
            configurations: [.smith: Self.config(temperature: 0.9, modelID: "a-different-model")],
            apiTypes: [.smith: .openAICompatible]
        )

        #expect(await smithTemperature(runtime) == 0.9, "a model switch never reached the live Smith")
        guard let smithID = await runtime.agentIDForRole(.smith),
              let smith = await runtime.liveAgent(id: smithID) else {
            Issue.record("no live Smith")
            return
        }
        #expect(smithID == smithIDBefore, "Smith was restarted rather than switched in place")
        #expect(await smith.configuration.llmConfig.modelID == "a-different-model")
    }

    @Test("A provider that arrives without its API type is refused and reported, never paired with a guessed type")
    func providerWithoutAPITypeIsRefused() async {
        let runtime = makeRuntime()
        await runtime.start()
        defer { Task { await runtime.stopAll() } }
        let advisoryErrorsBefore = await runtime.channel.allMessages()
            .filter { $0.kind == .advisory && $0.severity == .error }.count

        await runtime.setProviders(
            providers: [.smith: MockLLMProvider(responses: [LLMResponse(text: "Standing by.")])],
            configurations: [.smith: Self.config(temperature: 0.9, modelID: "a-different-model")],
            apiTypes: [:]
        )

        #expect(await runtime.llmConfigs[.smith]?.modelID == "test-model", "a refused role keeps its previous configuration")
        #expect(await runtime.providerAPITypes[.smith] == nil, "no API type may be invented for the refused role")
        let advisoryErrorsAfter = await runtime.channel.allMessages()
            .filter { $0.kind == .advisory && $0.severity == .error }.count
        #expect(advisoryErrorsAfter == advisoryErrorsBefore + 1, "the refusal must be surfaced in the transcript")
        // Give Smith's loop (0.5 s poll) time to apply a change, had one been staged.
        try? await Task.sleep(for: .seconds(1))
        if let smithID = await runtime.agentIDForRole(.smith), let smith = await runtime.liveAgent(id: smithID) {
            #expect(await smith.configuration.llmConfig.modelID == "test-model")
        }
    }

    @Test("A model change older than one the agent already has is dropped")
    func staleModelChangeIsDropped() async {
        let agent = Self.makeAgent(provider: MockLLMProvider(responses: [LLMResponse(text: "ok")]), llmConfig: Self.config(temperature: 0.2))
        await agent.scheduleModelChange(AgentActor.ModelChange(
            provider: MockLLMProvider(responses: [LLMResponse(text: "ok")]),
            llmConfig: Self.config(temperature: 0.2, modelID: "newer"),
            providerAPIType: .openAICompatible, supportsVision: nil, supportsDocuments: nil, generation: 5
        ))
        // Arrives late, built from an older merge.
        await agent.scheduleModelChange(AgentActor.ModelChange(
            provider: MockLLMProvider(responses: [LLMResponse(text: "ok")]),
            llmConfig: Self.config(temperature: 0.2, modelID: "older"),
            providerAPIType: .openAICompatible, supportsVision: nil, supportsDocuments: nil, generation: 4
        ))
        await agent.appendUserMessage("say ok")
        await agent.start()
        let deadline = Date().addingTimeInterval(3.0)
        while await agent.configuration.llmConfig.modelID == "test-model", Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        await agent.stop()
        #expect(await agent.configuration.llmConfig.modelID == "newer", "a stale change overwrote a newer one")
    }

    @Test("Overlapping setProviders calls leave the live Smith on the runtime's final model")
    func overlappingSetProvidersConverge() async {
        let runtime = makeRuntime()
        await runtime.start()
        defer { Task { await runtime.stopAll() } }

        for round in 0..<10 {
            async let first: Void = runtime.setProviders(
                providers: [.smith: MockLLMProvider(responses: [LLMResponse(text: "Standing by.")])],
                configurations: [.smith: Self.config(temperature: 0.2, modelID: "model-a-\(round)")],
                apiTypes: [.smith: .openAICompatible]
            )
            async let second: Void = runtime.setProviders(
                providers: [.smith: MockLLMProvider(responses: [LLMResponse(text: "Standing by.")])],
                configurations: [.smith: Self.config(temperature: 0.2, modelID: "model-b-\(round)")],
                apiTypes: [.smith: .openAICompatible]
            )
            _ = await (first, second)
        }
        let finalModelID = await runtime.llmConfigs[.smith]?.modelID
        guard let smithID = await runtime.agentIDForRole(.smith),
              let smith = await runtime.liveAgent(id: smithID) else {
            Issue.record("no live Smith")
            return
        }
        let deadline = Date().addingTimeInterval(3.0)
        while await smith.configuration.llmConfig.modelID != finalModelID, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(await smith.configuration.llmConfig.modelID == finalModelID, "the live Smith ended on a model the runtime no longer holds")
    }
}
