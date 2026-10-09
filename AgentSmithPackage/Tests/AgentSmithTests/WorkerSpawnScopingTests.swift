import Foundation
import Testing
import SemanticSearch
@testable import AgentSmithKit

/// Every worker belongs to a task and is scoped to it (#14). `provide_help`'s respawn used to
/// spawn with no task, which skipped scoping and handed the worker Brown's FULL tool set.
@Suite("Worker spawn scoping")
struct WorkerSpawnScopingTests {

    /// A runtime whose Security Agent approves only `file_read` when asked to scope a worker.
    private func makeRuntime() -> OrchestrationRuntime {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-smith-spawn-scoping-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let scopingResponse = "{\"toolResponses\":[{\"toolID\":\"file_read\",\"isAllowed\":true}]}"
        let configuration = ModelConfiguration(name: "test", providerID: "test", modelID: "test-model")
        return OrchestrationRuntime(
            providers: [
                .smith: MockLLMProvider(responses: [LLMResponse(text: "Standing by.")]),
                .securityAgent: MockLLMProvider(responses: [LLMResponse(text: scopingResponse)]),
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

    @Test("A provide_help respawn gets the task's scoped tool set, never Brown's full set")
    func provideHelpRespawnIsScoped() async throws {
        let runtime = makeRuntime()
        await runtime.setOrchestrationSettings(OrchestrationSettings.builtIn.applying(
            OrchestrationSettingsOverride(autoRunNextTask: false, scopeToolSetOnTaskStart: true)))
        await runtime.start()
        let smithID = try #require(await runtime.agentIDForRole(.smith))
        let store = await runtime.taskStore

        // A running task whose worker asked for help and is gone: provide_help must respawn one.
        let task = await store.addTask(title: "Read the log", description: "d")
        await store.driveStatus(id: task.id, to: .running)
        #expect(await store.requestHelp(id: task.id, request: "Which log?"))
        #expect(await runtime.liveWorkerID(taskID: task.id) == nil)

        let context = await runtime.makeToolContext(agentID: smithID, role: .smith)
        let result = try await ProvideHelpTool().execute(
            arguments: ["task_id": .string(task.id.uuidString), "response": .string("/var/log/system.log")],
            context: context
        )
        #expect(result.succeeded, "\(result.output)")

        let workerID = try #require(await runtime.liveWorkerID(taskID: task.id), "provide_help must respawn a worker for the task")
        let worker = try #require(await runtime.liveAgent(id: workerID))
        let toolNames = Set(await worker.toolNames)
        #expect(toolNames.contains("file_read"), "the scoped grant reaches the worker")
        #expect(!toolNames.contains("bash"), "an unscoped spawn would have offered bash: \(toolNames.sorted())")
        #expect(await store.task(id: task.id)?.approvedTools == ["file_read"])

        await runtime.stopAll()
    }
}
