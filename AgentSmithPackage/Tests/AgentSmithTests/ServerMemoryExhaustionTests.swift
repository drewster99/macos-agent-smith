import Testing
import Foundation
@testable import AgentSmithKit
import SwiftLLMKit

/// A model server that refuses a request with its own typed error (oMLX's prefill memory guard
/// answers HTTP 200 with `{"error": {"code": "prefill_memory_exceeded", …}}`, surfaced by
/// SwiftLLMKit 0.0.209 as `responseFailed`) must reach the user:
///
/// - the first server-declared failure is posted at once, with the server's reason, instead of
///   waiting behind the >=5-consecutive gate that transient errors use;
/// - three memory refusals IN A ROW shrink the agent's context once and post a user-addressed
///   advisory saying what happened and what the user can change. Any other outcome breaks the streak.
///
/// Observed 2026-09-23: Brown's request was refused by oMLX, reported as a parse failure, retried
/// silently, and nothing reached the channel.
@Suite("Server memory exhaustion surfacing", .serialized)
struct ServerMemoryExhaustionTests {

    private static let sharedEngine = SemanticSearchEngine()

    private static let memoryRefusal = LLMProviderError.responseFailed(
        code: LLMProviderError.ServerMemoryExhaustionCode.omlxPrefillMemoryExceeded.rawValue,
        message: "oMLX prefill memory guard rejected this prompt: Prefill would require ~53.28 GB peak"
    )

    /// Throws each scripted error in order, one per call, then hangs so the test observes the
    /// state after the script without further attempts.
    private final class ScriptedErrorProvider: LLMProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: [Error]
        private var _callCount = 0

        init(_ errors: [Error]) {
            self.remaining = errors
        }

        var callCount: Int { lock.withLock { _callCount } }

        func send(
            messages: [LLMMessage],
            tools: [LLMToolDefinition],
            overrides: LLMCallOverrides
        ) async throws -> LLMResponse {
            let next = lock.withLock { () -> Error? in
                _callCount += 1
                return remaining.isEmpty ? nil : remaining.removeFirst()
            }
            if let next { throw next }
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        }
    }

    private static func makeBrown(provider: any LLMProvider, channel: MessageChannel) -> AgentActor {
        let agentID = UUID()
        let config = AgentConfiguration(
            role: .brown,
            llmConfig: ModelConfiguration(
                name: "test", providerID: "test", modelID: "test-model",
                maxOutputTokens: 4096, maxContextTokens: 128_000
            ),
            systemPrompt: "test"
        )
        let context = ToolContext(
            agentID: agentID,
            agentRole: .brown,
            channel: channel,
            taskStore: TaskStore(),
            spawnBrown: { nil },
            terminateAgent: { _, _ in false },
            abort: { _, _ in },
            agentRoleForID: { _ in .brown },
            memoryStore: MemoryStore(engine: Self.sharedEngine),
            setToolExecutionStatus: { _, _ in },
            hasToolSucceeded: { _ in false },
            hasToolFailed: { _ in false }
        )
        return AgentActor(id: agentID, configuration: config, provider: provider, tools: [], toolContext: context)
    }

    private static func waitUntil(deadline: TimeInterval, _ predicate: () async -> Bool) async {
        let until = Date().addingTimeInterval(deadline)
        while Date() < until {
            if await predicate() { return }
            try? await Task.sleep(for: .seconds(0.02))
        }
    }

    private static func memoryAdvisories(in channel: MessageChannel) async -> [ChannelMessage] {
        await channel.allMessages().filter {
            $0.kind == .advisory && $0.content.contains("prefill_memory_exceeded")
        }
    }

    @Test("A server-declared failure surfaces on the first occurrence with the server's reason")
    func serverDeclaredFailureSurfacesImmediately() async {
        let channel = MessageChannel()
        let provider = ScriptedErrorProvider([
            LLMProviderError.responseFailed(code: "server_error", message: "backend exploded")
        ])
        let agent = Self.makeBrown(provider: provider, channel: channel)

        await agent.start(initialInstruction: "do something")
        await Self.waitUntil(deadline: 1.0) {
            await channel.allMessages().contains { $0.content.contains("Agent Brown error (1/") }
        }
        await agent.stop()

        let banner = await channel.allMessages().first { $0.content.contains("Agent Brown error (1/") }
        #expect(banner != nil, "a server-declared failure must not wait for five in a row")
        if let banner {
            #expect(banner.content.contains("backend exploded"))
            #expect(banner.content.contains("retrying in"), "it is still transient, so a retry is announced")
            #expect(banner.severity == .error)
        }
    }

    @Test("Three memory refusals in a row post one user-addressed advisory with guidance")
    func threeMemoryRefusalsPostOneAdvisory() async {
        let channel = MessageChannel()
        // Four in a row: the advisory fires at the third and must NOT repeat at the fourth.
        let provider = ScriptedErrorProvider(Array(repeating: Self.memoryRefusal, count: 4))
        let agent = Self.makeBrown(provider: provider, channel: channel)

        await agent.start(initialInstruction: "do something")
        // Backoff 1s + 2s + 4s puts the fourth call ~7s in. The settle lets its catch block run.
        await Self.waitUntil(deadline: 12.0) { provider.callCount >= 4 }
        try? await Task.sleep(for: .seconds(0.5))
        await agent.stop()

        #expect(provider.callCount >= 4, "the refusals are transient and keep being retried")
        let advisories = await Self.memoryAdvisories(in: channel)
        #expect(advisories.count == 1, "exactly one advisory per streak, not one per refusal")
        if let advisory = advisories.first {
            #expect(advisory.recipient == .user)
            #expect(advisory.severity == .warning)
            #expect(advisory.content.contains("refused 3 requests in a row"))
            #expect(advisory.content.contains("Memory Guard"))
            #expect(advisory.content.contains("Max context tokens"))
            #expect(advisory.content.contains("oMLX prefill memory guard rejected this prompt"))
        }
    }

    @Test("Any other error between memory refusals breaks the streak")
    func interveningErrorBreaksTheStreak() async {
        let channel = MessageChannel()
        let provider = ScriptedErrorProvider([
            Self.memoryRefusal,
            Self.memoryRefusal,
            LLMProviderError.httpError(statusCode: 503, body: "busy"),
            Self.memoryRefusal
        ])
        let agent = Self.makeBrown(provider: provider, channel: channel)

        await agent.start(initialInstruction: "do something")
        await Self.waitUntil(deadline: 12.0) { provider.callCount >= 4 }
        try? await Task.sleep(for: .seconds(0.5))
        await agent.stop()

        #expect(provider.callCount >= 4)
        let advisories = await Self.memoryAdvisories(in: channel)
        #expect(advisories.isEmpty, "two refusals, a 503, then one more is not three in a row")
    }

    @Test("A memory refusal carried by an HTTP 4xx body is retryable, not permanent")
    func memoryRefusalOnClientStatusIsTransient() {
        let code = LLMProviderError.ServerMemoryExhaustionCode.omlxPrefillMemoryExceeded.rawValue
        let body = #"{"error":{"code":"\#(code)","message":"not enough memory"}}"#
        let refusal = LLMProviderError.httpError(statusCode: 400, body: body)
        #expect(refusal.serverMemoryExhaustion != nil)
        guard case .transient = LLMRetryPolicy.classify(refusal) else {
            Issue.record("a 4xx memory refusal must not stop the agent before the context reduction can run")
            return
        }
        // An ordinary 400 is still permanent.
        #expect(LLMRetryPolicy.classify(LLMProviderError.httpError(statusCode: 400, body: "bad request")) == .permanent)
    }
}
