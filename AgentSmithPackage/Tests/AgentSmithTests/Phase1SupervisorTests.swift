import Foundation
import Testing
import SemanticSearch
@testable import AgentSmithKit

/// Tests for the supervised-lifecycle refactor: the `AgentSupervisor` ledger, the
/// awaitable lifecycle queue, and the runtime's serialized start/stop entry points.

// MARK: - Helpers

private func makeTestAgent(role: AgentRole = .smith) -> AgentActor {
    let config = AgentConfiguration(
        role: role,
        llmConfig: ModelConfiguration(name: "test", providerID: "test", modelID: "test-model"),
        systemPrompt: "test prompt"
    )
    return AgentActor(
        configuration: config,
        provider: MockLLMProvider(responses: []),
        tools: [],
        toolContext: TestToolContext.make(agentRole: role)
    )
}

// MARK: - AgentSupervisor

@Suite("AgentSupervisor ledger")
struct AgentSupervisorTests {

    @Test("Registration requires an active generation")
    func registrationRequiresGeneration() {
        var supervisor = AgentSupervisor()
        let agent = makeTestAgent()
        let rejected = supervisor.register(id: UUID(), role: .smith, agent: agent)
        #expect(rejected == nil, "a stopped runtime must not be able to mint trackable agents")

        _ = supervisor.beginGeneration()
        let accepted = supervisor.register(id: UUID(), role: .smith, agent: agent)
        #expect(accepted != nil)
    }

    @Test("A handle carries the generation's epoch")
    func handleCarriesEpoch() {
        var supervisor = AgentSupervisor()
        let first = supervisor.beginGeneration()
        _ = supervisor.endGeneration()
        let second = supervisor.beginGeneration()
        #expect(second.epoch > first.epoch)

        let handle = supervisor.register(id: UUID(), role: .brown, agent: makeTestAgent(role: .brown))
        #expect(handle?.epoch == second.epoch)
    }

    @Test("endGeneration removes and returns every handle in one step")
    func endGenerationReturnsEverything() {
        var supervisor = AgentSupervisor()
        _ = supervisor.beginGeneration()
        let smithID = UUID()
        let brownID = UUID()
        supervisor.register(id: smithID, role: .smith, agent: makeTestAgent())
        supervisor.register(id: brownID, role: .brown, agent: makeTestAgent(role: .brown))
        supervisor.addSubscription(UUID(), to: smithID)

        let handles = supervisor.endGeneration()
        #expect(handles.count == 2)
        #expect(supervisor.count == 0)
        #expect(supervisor.currentGeneration == nil)
        #expect(!supervisor.isCurrent(smithID))
        #expect(!supervisor.isCurrent(brownID))
        let smithHandle = handles.first { $0.role == .smith }
        #expect(smithHandle?.subscriptionIDs.count == 1)
    }

    @Test("remove returns the full handle and ends currency")
    func removeReturnsHandle() {
        var supervisor = AgentSupervisor()
        _ = supervisor.beginGeneration()
        let id = UUID()
        supervisor.register(id: id, role: .brown, agent: makeTestAgent(role: .brown))
        supervisor.addSubscription(UUID(), to: id)
        supervisor.addSubscription(UUID(), to: id)

        #expect(supervisor.isCurrent(id))
        let handle = supervisor.remove(id: id)
        #expect(handle?.subscriptionIDs.count == 2)
        #expect(!supervisor.isCurrent(id))
        #expect(supervisor.remove(id: id) == nil, "second removal is a nil no-op (idempotent teardown)")
    }

    @Test("Role lookup resolves the registered agent")
    func roleLookup() {
        var supervisor = AgentSupervisor()
        _ = supervisor.beginGeneration()
        let brownID = UUID()
        supervisor.register(id: brownID, role: .brown, agent: makeTestAgent(role: .brown))
        #expect(supervisor.firstHandle(role: .brown)?.id == brownID)
        #expect(supervisor.firstHandle(role: .smith) == nil)
        #expect(supervisor.role(of: brownID) == .brown)
    }
}

// MARK: - SerialChainedTaskQueue.run

@Suite("SerialChainedTaskQueue awaitable run")
struct SerialChainedTaskQueueRunTests {

    @Test("run() returns the operation's result")
    func runReturnsResult() async {
        let queue = SerialChainedTaskQueue()
        let value = await queue.run { 42 }
        #expect(value == 42)
    }

    @Test("Operations run strictly FIFO with no overlap")
    func fifoNoOverlap() async {
        let queue = SerialChainedTaskQueue()
        // An actor-backed trace: each op records entry and exit; overlap would interleave
        // an entry between another op's entry and exit.
        actor Trace {
            var events: [String] = []
            func record(_ event: String) { events.append(event) }
        }
        let trace = Trace()

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask {
                    _ = await queue.run {
                        await trace.record("in\(index)")
                        try? await Task.sleep(nanoseconds: 5_000_000)
                        await trace.record("out\(index)")
                        return index
                    }
                }
            }
        }

        let events = await trace.events
        #expect(events.count == 16)
        // No overlap: every "in" is immediately followed by its own "out".
        for pairIndex in stride(from: 0, to: events.count, by: 2) {
            let entry = events[pairIndex]
            let exit = events[pairIndex + 1]
            #expect(entry.hasPrefix("in") && exit.hasPrefix("out"))
            #expect(entry.dropFirst(2) == exit.dropFirst(3), "operation \(entry) overlapped with \(exit)")
        }
    }

    @Test("schedule() and run() share one FIFO order")
    func scheduleAndRunInterleave() async {
        let queue = SerialChainedTaskQueue()
        actor Order { var values: [Int] = []; func add(_ v: Int) { values.append(v) } }
        let order = Order()

        queue.schedule { await order.add(1) }
        queue.schedule { await order.add(2) }
        let third = await queue.run { await order.add(3); return 3 }
        #expect(third == 3)
        let values = await order.values
        #expect(values == [1, 2, 3])
    }
}

// MARK: - Runtime lifecycle serialization

@Suite("OrchestrationRuntime lifecycle serialization")
struct RuntimeLifecycleSerializationTests {

    private func makeRuntime(
        providers: [AgentRole: any LLMProvider] = [:],
        configurations: [AgentRole: ModelConfiguration] = [:]
    ) -> OrchestrationRuntime {
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agent-smith-phase1-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        return OrchestrationRuntime(
            providers: providers,
            configurations: configurations,
            providerAPITypes: [:],
            agentTuning: [:],
            semanticSearchEngine: SemanticSearchEngine(),
            usageStore: UsageStore(persistence: PersistenceManager(testingRoot: tmpRoot)),
            autoAdvanceEnabled: true,
            autoRunInterruptedTasks: false,
            memoryStore: nil
        )
    }

    @Test("A concurrent start/stop storm neither deadlocks nor leaks tracked agents")
    func startStopStormEndsConsistent() async {
        let runtime = makeRuntime()
        // No providers configured: start() begins a generation, then bails at the
        // no-Smith-provider guard. The point is exercising the queue under contention —
        // every one of these used to be able to interleave mid-transition.
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<10 {
                group.addTask {
                    if index.isMultiple(of: 2) {
                        await runtime.start()
                    } else {
                        await runtime.stopAll()
                    }
                }
            }
        }
        await runtime.stopAll()
        let ids = await runtime.activeAgentIDs()
        #expect(ids.isEmpty)
        let sessionID = await runtime.currentSessionID
        #expect(sessionID == nil, "no generation may survive the final stopAll")
    }

    @Test("spawnBrown on a stopped runtime fails cleanly")
    func spawnOnStoppedRuntimeFails() async {
        let runtime = makeRuntime()
        await runtime.stopAll()
        let brownID = await runtime.spawnBrown()
        #expect(brownID == nil)
    }

    @Test("A start that fails the provider guard leaves no generation behind")
    func failedStartLeavesNoGeneration() async {
        // No Smith provider: performStart bails at the provider guard AFTER beginning a
        // generation. Codex review finding: the generation used to survive, so
        // currentSessionID read as 'running' and a later spawnBrown could register a
        // worker into a session that never started Smith.
        let runtime = makeRuntime()
        await runtime.start()
        let sessionID = await runtime.currentSessionID
        #expect(sessionID == nil, "failed start must end its generation")
        let brownID = await runtime.spawnBrown()
        #expect(brownID == nil, "no generation → no worker registration")
    }

    @Test("Successful start registers Smith; stopAll clears everything")
    func successfulStartAndStop() async {
        // A real Smith on a canned-response mock provider (the mock repeats its last
        // response when exhausted, so the run loop can tick safely until stopped).
        let runtime = makeRuntime(
            providers: [.smith: MockLLMProvider(responses: [LLMResponse(text: "Standing by.")])],
            configurations: [.smith: ModelConfiguration(name: "test", providerID: "test", modelID: "test-model")]
        )
        await runtime.start()
        let liveIDs = await runtime.activeAgentIDs()
        #expect(liveIDs.count == 1, "exactly Smith should be registered")
        let smithID = await runtime.agentIDForRole(.smith)
        #expect(smithID != nil)
        let sessionID = await runtime.currentSessionID
        #expect(sessionID != nil)

        await runtime.stopAll()
        let afterIDs = await runtime.activeAgentIDs()
        #expect(afterIDs.isEmpty)
        let afterSession = await runtime.currentSessionID
        #expect(afterSession == nil)
        if let smithID {
            let registered = await runtime.isAgentRegistered(smithID)
            #expect(!registered, "the liveness lease must read false after stopAll")
        }
    }
}
