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

    /// A provider whose FIRST call swaps the evaluator to another model mid-evaluation, then asks for
    /// an evidence read, forcing a second round; the second round must stay on this provider.
    private final class SwappingProvider: LLMProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        var onFirstCall: (@Sendable () async -> Void)?
        var callCount: Int { lock.withLock { calls } }
        func send(messages: [LLMMessage], tools: [LLMToolDefinition], overrides: LLMCallOverrides) async throws -> LLMResponse {
            let index = lock.withLock { calls += 1; return calls }
            if index == 1 {
                await onFirstCall?()
                return LLMResponse(toolCalls: [LLMToolCall(id: "read-1", name: "file_read", arguments: #"{"path":"/nonexistent/agent-smith-test"}"#)])
            }
            return LLMResponse(text: "SAFE")
        }
    }

    @Test("A swap during an evaluation leaves that evaluation — and its transcript rows — on its own model")
    func swapMidEvaluationDoesNotLeakIn() async {
        let original = SwappingProvider()
        let replacement = MockLLMProvider(responses: [LLMResponse(text: "SAFE")])
        let channel = MessageChannel()
        let evaluator = SecurityEvaluator(
            provider: original,
            systemPrompt: "p",
            channel: channel,
            abort: { _, _ in },
            configuration: ModelConfiguration(name: "old", providerID: "p", modelID: "old-model"),
            hasToolSucceeded: { _ in false },
            hasToolFailed: { _ in false }
        )
        let replacementModel = SecurityEvaluatorModel(
            provider: replacement, configuration: ModelConfiguration(name: "new", providerID: "p", modelID: "new-model"),
            providerType: "", supportsVision: false, supportsDocuments: false
        )
        original.onFirstCall = { await evaluator.applyModel(replacementModel) }
        _ = await evaluator.evaluate(
            toolName: "bash", toolParams: "{\"command\":\"ls\"}", toolDescription: "shell", toolParameterDefs: "",
            taskTitle: "t", taskID: UUID().uuidString, taskDescription: "d", siblingCalls: nil,
            agentRoleName: "Brown", callerRole: .brown, toolGroupDescription: nil, toolCallID: "c1",
            evaluatingForAgentID: UUID()
        )
        #expect(original.callCount == 2, "the evidence round stayed on the model the evaluation started with")
        #expect(replacement.callCount == 0)
        let evidenceRow = await channel.allMessages().first { $0.kind == .toolRequest && $0.content.hasPrefix("file_read") }
        #expect(evidenceRow?.modelID == "old-model", "stamped with the model that produced it")
        #expect(await evaluator.currentModel.configuration?.modelID == "new-model", "the next evaluation uses the swap")
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

    @Test("A summarizer model change rebuilds the task summarizer; the Security Agent's evaluators keep theirs")
    func summarizerRebuilt() async {
        let runtime = makeRuntime()
        await runtime.start()
        #expect(await runtime.nonAgentModelConfigurations().summarizer?.modelID == "test-model")
        let changed = ModelConfiguration(name: "sum2", providerID: "test", modelID: "summary-2")
        await runtime.setProviders(
            providers: [.summarizer: MockLLMProvider(responses: [LLMResponse(text: "s")])],
            configurations: [.summarizer: changed],
            apiTypes: [:]
        )
        #expect(await runtime.nonAgentModelConfigurations().summarizer?.modelID == "summary-2")
        #expect(await runtime.nonAgentModelConfigurations().security.allSatisfy { $0?.modelID == "test-model" },
                "the Security Agent's configuration did not change, so its evaluators were not touched")
        await runtime.stopAll()
    }

    @Test("A new configuration whose provider failed to build is not paired with the old provider")
    func configWithoutProviderIsNotApplied() async {
        let runtime = makeRuntime()
        await runtime.start()
        await runtime.setProviders(
            providers: [:],
            configurations: [.securityAgent: ModelConfiguration(name: "sec2", providerID: "other", modelID: "security-2")],
            apiTypes: [:]
        )
        #expect(await runtime.nonAgentModelConfigurations().security.allSatisfy { $0?.modelID == "test-model" })
        await runtime.stopAll()
    }

    @Test("After a failed provider build, the next successful build of the same configuration still reaches live holders")
    func retryAfterFailedBuildIsAChange() async {
        let runtime = makeRuntime()
        await runtime.start()
        let changed = ModelConfiguration(name: "sec2", providerID: "other", modelID: "security-2")
        await runtime.setProviders(providers: [:], configurations: [.securityAgent: changed], apiTypes: [:])
        await runtime.setProviders(
            providers: [.securityAgent: MockLLMProvider(responses: [LLMResponse(text: "SAFE")])],
            configurations: [.securityAgent: changed],
            apiTypes: [:]
        )
        #expect(await runtime.nonAgentModelConfigurations().security.allSatisfy { $0?.modelID == "security-2" })
        await runtime.stopAll()
    }
}
