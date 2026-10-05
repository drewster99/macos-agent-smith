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
        llmConfig: ModelConfiguration
    ) -> AgentActor {
        let agentID = UUID()
        let context = ToolContext(
            agentID: agentID,
            agentRole: .brown,
            channel: MessageChannel(),
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
            supportsDocuments: nil
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
            supportsDocuments: nil
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
            supportsDocuments: nil
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
            apiTypes: [:]
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
            apiTypes: [:]
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
}
