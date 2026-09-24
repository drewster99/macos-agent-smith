import Foundation
import Testing
import SemanticSearch
@testable import AgentSmithKit

/// A RETUNE is a new provider build for the model an agent is already running — a temperature,
/// effort, thinking or token-cap edit in Settings. Before this, such an edit reached Brown only at
/// its next spawn and reached the long-lived Smith never: `restartForNewTask` cycles the worker and
/// leaves Smith alone, so Smith kept its spawn-time parameters for the life of the session.
///
/// Two halves are pinned here, and they are load-bearing in opposite directions:
///
/// 1. A retune of the SAME model reaches a live agent, applied at a turn boundary so no single turn
///    spans two configurations.
/// 2. A change of MODEL or PROVIDER reaches a live agent only with an explicit history reset.
///
/// Not pinned, deliberately: that an UNCHANGED configuration skips the retune. Its failure mode is
/// a performance regression rather than a wrong answer (a needless swap discards a provider's
/// per-instance prefix-cache key), and it has no observable signal from outside the actor.
@Suite("Model retune")
struct ModelRetuneTests {

    private static let sharedEngine = SemanticSearchEngine()

    private static func config(
        temperature: Double,
        modelID: String = "test-model",
        providerID: String = "test"
    ) -> ModelConfiguration {
        ModelConfiguration(
            name: "test",
            providerID: providerID,
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

        configuration.applyRetunedModel(
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
        configuration.applyRetunedModel(
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

        let accepted = await agent.scheduleModelRetune(AgentActor.ModelRetune(
            provider: after,
            llmConfig: Self.config(temperature: 0.9),
            providerAPIType: .openAICompatible,
            supportsVision: nil,
            supportsDocuments: nil
        ))
        #expect(accepted)

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

    @Test("A retune that changes the model is refused, and changes nothing")
    func retuneRefusesAModelChange() async {
        let original = MockLLMProvider(responses: [LLMResponse(text: "ok")])
        let agent = Self.makeAgent(provider: original, llmConfig: Self.config(temperature: 0.2))

        let accepted = await agent.scheduleModelRetune(AgentActor.ModelRetune(
            provider: MockLLMProvider(responses: [LLMResponse(text: "ok")]),
            llmConfig: Self.config(temperature: 0.9, modelID: "a-different-model"),
            providerAPIType: .openAICompatible,
            supportsVision: nil,
            supportsDocuments: nil
        ))

        #expect(!accepted, "a model change must be refused — the stored history is provider-shaped")
        let temperature = await agent.configuration.llmConfig.temperature
        #expect(temperature == 0.2)
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

    private func makeRuntimeWithSummarizer() -> OrchestrationRuntime {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-smith-retune-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        return OrchestrationRuntime(
            providers: [
                .smith: MockLLMProvider(responses: [LLMResponse(text: "Standing by.")]),
                .securityAgent: MockLLMProvider(responses: [LLMResponse(text: "SAFE")]),
                .summarizer: MockLLMProvider(responses: [LLMResponse(text: "Summary.")])
            ],
            configurations: [
                .smith: Self.config(temperature: 0.2, modelID: "smith-old"),
                .securityAgent: Self.config(temperature: 0.2, modelID: "security-old"),
                .summarizer: Self.config(temperature: 0.2, modelID: "summarizer-old")
            ],
            providerAPITypes: [:],
            agentTuning: [.smith: AgentTuningConfig(pollInterval: 0.5, messageDebounceInterval: 0)],
            semanticSearchEngine: Self.sharedEngine,
            usageStore: UsageStore(persistence: PersistenceManager(testingRoot: tmpRoot)),
            autoAdvanceEnabled: false,
            autoRunInterruptedTasks: false,
            memoryStore: nil
        )
    }

    private func makeRuntimeWithBrown() -> OrchestrationRuntime {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-smith-retune-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        return OrchestrationRuntime(
            providers: [
                .smith: MockLLMProvider(responses: [LLMResponse(text: "Standing by.")]),
                .brown: MockLLMProvider(responses: [LLMResponse(text: "Working.")]),
                .securityAgent: MockLLMProvider(responses: [LLMResponse(text: "SAFE")])
            ],
            configurations: [
                .smith: Self.config(temperature: 0.2, modelID: "smith-old"),
                .brown: Self.config(temperature: 0.2, modelID: "brown-old"),
                .securityAgent: Self.config(temperature: 0.2, modelID: "security-old")
            ],
            providerAPITypes: [:],
            agentTuning: [
                .smith: AgentTuningConfig(pollInterval: 0.5, messageDebounceInterval: 0),
                .brown: AgentTuningConfig(pollInterval: 0.5, messageDebounceInterval: 0)
            ],
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

    @Test("A provider/model identity swap rebuilds Smith from clear-orientation context")
    func identitySwapRebuildsSmithWithOrientation() async {
        let runtime = makeRuntime()
        await runtime.start()
        defer { Task { await runtime.stopAll() } }
        guard let smithID = await runtime.agentIDForRole(.smith),
              let smith = await runtime.liveAgent(id: smithID) else {
            Issue.record("missing live Smith")
            return
        }
        await smith.appendUserMessage("pre-swap marker")

        await runtime.setProviders(
            providers: [.smith: MockLLMProvider(responses: [LLMResponse(text: "Standing by.")])],
            configurations: [.smith: Self.config(temperature: 0.9, modelID: "a-different-model", providerID: "alt-provider")],
            apiTypes: [:]
        )

        let deadline = Date().addingTimeInterval(3.0)
        var modelID: String?
        while Date() < deadline {
            let liveConfig = await smith.currentModelConfiguration()
            modelID = liveConfig.modelID
            if modelID == "a-different-model" { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(modelID == "a-different-model", "live Smith never adopted the swapped model")
        let swappedConfig = await smith.currentModelConfiguration()
        #expect(swappedConfig.temperature == 0.9)
        #expect(swappedConfig.providerID == "alt-provider")
        let context = await smith.contextSnapshot()
        let fullText = context.compactMap { $0.content.textValue }.joined(separator: "\n")
        #expect(!fullText.contains("pre-swap marker"), "model/provider swap must reset history before replaying")
        #expect(fullText.contains("[The user cleared your conversation context."), "smith swap should rebuild from clear-orientation context")
    }

    @Test("Long-lived summarizer and security evaluator refresh on setProviders")
    func longLivedHoldersRefreshOnProviderUpdate() async {
        let runtime = makeRuntimeWithSummarizer()
        await runtime.start()
        defer { Task { await runtime.stopAll() } }

        #expect(await runtime.liveModelConfiguration(for: .securityAgent)?.modelID == "security-old")
        #expect(await runtime.liveModelConfiguration(for: .summarizer)?.modelID == "summarizer-old")
        let initialEvaluators = await runtime.longLivedSecurityEvaluatorConfigurations()
        #expect(initialEvaluators.smith?.modelID == "security-old")
        #expect(initialEvaluators.validation?.modelID == "security-old")
        #expect(await runtime.summarizerHolderConfiguration()?.modelID == "summarizer-old")

        await runtime.setProviders(
            providers: [
                .securityAgent: MockLLMProvider(responses: [LLMResponse(text: "SAFE")]),
                .summarizer: MockLLMProvider(responses: [LLMResponse(text: "Summary.")])
            ],
            configurations: [
                .securityAgent: Self.config(temperature: 0.4, modelID: "security-new"),
                .summarizer: Self.config(temperature: 0.6, modelID: "summarizer-new")
            ],
            apiTypes: [:]
        )

        #expect(await runtime.liveModelConfiguration(for: .securityAgent)?.modelID == "security-new")
        #expect(await runtime.liveModelConfiguration(for: .securityAgent)?.temperature == 0.4)
        #expect(await runtime.liveModelConfiguration(for: .summarizer)?.modelID == "summarizer-new")
        #expect(await runtime.liveModelConfiguration(for: .summarizer)?.temperature == 0.6)
        let refreshedEvaluators = await runtime.longLivedSecurityEvaluatorConfigurations()
        #expect(refreshedEvaluators.smith?.modelID == "security-new")
        #expect(refreshedEvaluators.smith?.temperature == 0.4)
        #expect(refreshedEvaluators.validation?.modelID == "security-new")
        #expect(refreshedEvaluators.validation?.temperature == 0.4)
        #expect(await runtime.summarizerHolderConfiguration()?.modelID == "summarizer-new")
    }

    @Test("Config-only update without provider keeps long-lived holders on prior live config")
    func configOnlyUpdateWithoutProviderKeepsLongLivedHoldersStable() async {
        let runtime = makeRuntimeWithSummarizer()
        await runtime.start()
        defer { Task { await runtime.stopAll() } }

        #expect(await runtime.liveModelConfiguration(for: .securityAgent)?.modelID == "security-old")
        #expect(await runtime.liveModelConfiguration(for: .summarizer)?.modelID == "summarizer-old")

        await runtime.setProviders(
            providers: [:],
            configurations: [
                .securityAgent: Self.config(temperature: 0.8, modelID: "security-missing-provider"),
                .summarizer: Self.config(temperature: 0.9, modelID: "summarizer-missing-provider")
            ],
            apiTypes: [:]
        )

        #expect(await runtime.liveModelConfiguration(for: .securityAgent)?.modelID == "security-old")
        #expect(await runtime.liveModelConfiguration(for: .securityAgent)?.temperature == 0.2)
        #expect(await runtime.longLivedSecurityEvaluatorConfigurations().validation?.modelID == "security-old")
        #expect(await runtime.longLivedSecurityEvaluatorConfigurations().validation?.temperature == 0.2)
        #expect(await runtime.liveModelConfiguration(for: .summarizer)?.modelID == "summarizer-old")
        #expect(await runtime.liveModelConfiguration(for: .summarizer)?.temperature == 0.2)
        #expect(await runtime.summarizerHolderConfiguration()?.modelID == "summarizer-old")
    }

    @Test("A Brown model change swaps live worker and rebuilds task briefing")
    func brownModelSwapResetsToFreshBriefing() async {
        let runtime = makeRuntimeWithBrown()
        await runtime.setOrchestrationSettings(OrchestrationSettings.builtIn.applying(OrchestrationSettingsOverride(scopeToolSetOnTaskStart: false)))
        await runtime.start()
        defer { Task { await runtime.stopAll() } }

        let task = AgentTask(title: "Brown swap task", description: "Perform work.")
        await runtime.taskStore.addTask(task)
        guard let brownID = await runtime.spawnBrown(for: task),
              let brown = await runtime.liveAgent(id: brownID) else {
            Issue.record("missing live Brown")
            return
        }

        await brown.appendUserMessage("brown pre-swap marker")
        await runtime.setProviders(
            providers: [.brown: MockLLMProvider(responses: [LLMResponse(text: "Working.")])],
            configurations: [.brown: Self.config(temperature: 0.7, modelID: "brown-new")],
            apiTypes: [:]
        )

        let deadline = Date().addingTimeInterval(3.0)
        var modelID: String?
        while Date() < deadline {
            let liveConfig = await brown.currentModelConfiguration()
            modelID = liveConfig.modelID
            if modelID == "brown-new" { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(modelID == "brown-new")
        #expect((await brown.currentModelConfiguration()).temperature == 0.7)

        let context = await brown.contextSnapshot()
        let fullText = context.compactMap { $0.content.textValue }.joined(separator: "\n")
        #expect(!fullText.contains("brown pre-swap marker"))
        #expect(fullText.contains("## Your working directories"))
    }
}
