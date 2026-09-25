import Testing
import Foundation
import SemanticSearch
import SwiftLLMKit
@testable import AgentSmithKit

/// Issue #9 gap 2: the long-lived holders that are not agents — every Security Agent evaluator and
/// the task summarizer — take a model or tuning change live.
@Suite("Non-agent model refresh", .serialized)
struct NonAgentModelRefreshTests {

    @Test("An evaluator uses a swapped-in model from its next evaluation")
    func evaluatorSwap() async {
        let original = MockLLMProvider(responses: [LLMResponse(text: "SAFE")])
        let replacement = MockLLMProvider(responses: [LLMResponse(text: "SAFE")])
        let evaluator = SecurityEvaluator(
            provider: original,
            systemPrompt: "p",
            channel: MessageChannel(),
            abort: { _, _ in },
            configuration: ModelConfiguration(name: "old", providerID: "p", modelID: "old-model"),
            hasToolSucceeded: { _ in false },
            hasToolFailed: { _ in false }
        )
        let newConfig = ModelConfiguration(name: "new", providerID: "p", modelID: "new-model")
        await evaluator.applyModel(SecurityEvaluatorModel(
            provider: replacement, configuration: newConfig, providerType: "", supportsVision: false, supportsDocuments: false
        ))
        _ = await evaluator.evaluate(
            toolName: "bash", toolParams: "{\"command\":\"ls\"}", toolDescription: "shell", toolParameterDefs: "",
            taskTitle: "t", taskID: UUID().uuidString, taskDescription: "d", siblingCalls: nil,
            agentRoleName: "Brown", callerRole: .brown, toolGroupDescription: nil, toolCallID: "c1",
            evaluatingForAgentID: UUID()
        )
        #expect(replacement.callCount == 1)
        #expect(original.callCount == 0)
        #expect(await evaluator.currentModel.configuration?.modelID == "new-model")
    }

    private func makeRuntime() -> OrchestrationRuntime {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-smith-nonagent-refresh", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let configuration = ModelConfiguration(name: "test", providerID: "test", modelID: "test-model")
        return OrchestrationRuntime(
            providers: [
                .smith: MockLLMProvider(responses: [LLMResponse(text: "Standing by.")]),
                .securityAgent: MockLLMProvider(responses: [LLMResponse(text: "SAFE")]),
                .brown: MockLLMProvider(responses: [LLMResponse(text: "Working.")]),
                .summarizer: MockLLMProvider(responses: [LLMResponse(text: "summary")])
            ],
            configurations: [.smith: configuration, .securityAgent: configuration, .brown: configuration, .summarizer: configuration],
            providerAPITypes: [:],
            agentTuning: [
                .brown: AgentTuningConfig(pollInterval: 3600),
                .smith: AgentTuningConfig(pollInterval: 3600),
                .securityAgent: AgentTuningConfig(pollInterval: 3600)
            ],
            semanticSearchEngine: SemanticSearchEngine(),
            usageStore: UsageStore(persistence: PersistenceManager(testingRoot: tmpRoot)),
            autoAdvanceEnabled: false,
            autoRunInterruptedTasks: false,
            memoryStore: nil
        )
    }

    @Test("A Security Agent model change reaches Smith's and the validators' live evaluators")
    func securityModelChangeReachesLiveEvaluators() async {
        let runtime = makeRuntime()
        await runtime.start()
        let before = await runtime.nonAgentModelConfigurations().security
        #expect(before.count >= 2, "Smith's evaluator and the validators' shared one")
        #expect(before.allSatisfy { $0?.modelID == "test-model" })

        let changed = ModelConfiguration(name: "sec2", providerID: "other", modelID: "security-2")
        await runtime.setProviders(
            providers: [.securityAgent: MockLLMProvider(responses: [LLMResponse(text: "SAFE")])],
            configurations: [.securityAgent: changed],
            apiTypes: [:]
        )
        let after = await runtime.nonAgentModelConfigurations().security
        #expect(after.count == before.count)
        #expect(after.allSatisfy { $0?.modelID == "security-2" })
        await runtime.stopAll()
    }

    @Test("A summarizer change rebuilds the task summarizer; an untouched role is left alone")
    func summarizerRebuilt() async {
        let runtime = makeRuntime()
        await runtime.start()
        #expect(await runtime.nonAgentModelConfigurations().summarizer?.modelID == "test-model")
        var retuned = ModelConfiguration(name: "sum2", providerID: "test", modelID: "summary-2")
        retuned.temperature = 0.1
        await runtime.setProviders(
            providers: [.summarizer: MockLLMProvider(responses: [LLMResponse(text: "s")])],
            configurations: [.summarizer: retuned],
            apiTypes: [:]
        )
        #expect(await runtime.nonAgentModelConfigurations().summarizer?.modelID == "summary-2")
        #expect(await runtime.nonAgentModelConfigurations().security.allSatisfy { $0?.modelID == "test-model" },
                "the Security Agent's configuration did not change, so its evaluators were not touched")
        await runtime.stopAll()
    }
}
