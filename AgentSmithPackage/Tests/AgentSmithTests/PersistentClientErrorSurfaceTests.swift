import Testing
import Foundation
@testable import AgentSmithKit
import SwiftLLMKit

/// Regression coverage for surfacing persistent HTTP 4xx errors on the *first*
/// occurrence instead of waiting for 5 consecutive failures.
///
/// Bug: an agent paired with a provider that fails every request with HTTP 400
/// (e.g. DeepSeek demanding `reasoning_content` be replayed, an unsupported
/// parameter, an invalid API key) silently retried with exponential backoff for
/// ~45 seconds before posting anything to the channel. The user only saw it in
/// console logs, and the agent kept burning API quota the whole time.
///
/// Fix: HTTP 4xx errors except 408/429 are surfaced on `consecutiveErrors == 1`.
/// Genuinely transient classes (429, 408, 5xx, network) still wait for 5.
@Suite("Persistent client-error surfacing", .serialized)
struct PersistentClientErrorSurfaceTests {

    private static let sharedEngine = SemanticSearchEngine()

    /// Provider that throws a non-retryable HTTP 400 on the first call and then
    /// hangs, giving the test a clean window to assert on the channel before the
    /// run loop terminates or loops further.
    private final class SingleShot400Provider: LLMProvider, @unchecked Sendable {
        let lock = NSLock()
        private var _hasFired = false
        let body: String
        let statusCode: Int
        let retryAfter: TimeInterval?

        init(statusCode: Int = 400, body: String = #"{"error":{"message":"Bad request: malformed parameter"}}"#, retryAfter: TimeInterval? = nil) {
            self.statusCode = statusCode
            self.body = body
            self.retryAfter = retryAfter
        }

        func send(
            messages: [LLMMessage],
            tools: [LLMToolDefinition],
            overrides: LLMCallOverrides
        ) async throws -> LLMResponse {
            let isFirst = lock.withLock { () -> Bool in
                if !_hasFired {
                    _hasFired = true
                    return true
                }
                return false
            }
            if isFirst {
                throw LLMProviderError.httpError(statusCode: statusCode, body: body, url: nil, retryAfter: retryAfter)
            }
            // Hang so the test deterministically observes state right after the
            // first error, before backoff sleeps or subsequent attempts.
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        }
    }

    private static func makeBrown(provider: any LLMProvider, channel: MessageChannel, taskStore: TaskStore) -> AgentActor {
        let memoryStore = MemoryStore(engine: Self.sharedEngine)
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
            taskStore: taskStore,
            spawnBrown: { nil },
            terminateAgent: { _, _ in false },
            abort: { _, _ in },
            agentRoleForID: { _ in .brown },
            memoryStore: memoryStore,
            setToolExecutionStatus: { _, _ in },
            hasToolSucceeded: { _ in false },
            hasToolFailed: { _ in false }
        )
        return AgentActor(
            id: agentID,
            configuration: config,
            provider: provider,
            tools: [],
            toolContext: context
        )
    }

    /// Waits up to `deadline` for the predicate to become true. Polls so the test
    /// finishes as soon as the channel has the message instead of always sleeping
    /// the full grace period.
    private static func waitUntil(
        deadline: TimeInterval,
        poll: TimeInterval = 0.02,
        _ predicate: () async -> Bool
    ) async {
        let until = Date().addingTimeInterval(deadline)
        while Date() < until {
            if await predicate() { return }
            try? await Task.sleep(for: .seconds(poll))
        }
    }

    @Test("HTTP 400 surfaces immediately on the first error")
    func http400SurfacesImmediately() async throws {
        let channel = MessageChannel()
        let taskStore = TaskStore()
        let provider = SingleShot400Provider()
        let agent = Self.makeBrown(provider: provider, channel: channel, taskStore: taskStore)

        await agent.start(initialInstruction: "do something")

        await Self.waitUntil(deadline: 1.0) {
            let msgs = await channel.allMessages()
            return msgs.contains {
                $0.content.contains("Agent Brown error (1/")
                    && $0.content.contains("malformed parameter")
            }
        }

        await agent.stop()

        let allMessages = await channel.allMessages()
        let firstErrorBanner = allMessages.first {
            $0.content.contains("Agent Brown error (1/")
        }
        #expect(
            firstErrorBanner != nil,
            "persistent HTTP 400 should surface on the first failure, not after 5"
        )
        if let banner = firstErrorBanner {
            #expect(banner.content.contains("malformed parameter"))
        }
    }

    @Test("HTTP 429 surfaces on the first failure with a retry ETA")
    func http429SurfacesWithRetryETA() async throws {
        let channel = MessageChannel()
        let taskStore = TaskStore()
        let provider = SingleShot400Provider(
            statusCode: 429,
            body: #"{"error":{"message":"Rate limited; try again later"}}"#
        )
        let agent = Self.makeBrown(provider: provider, channel: channel, taskStore: taskStore)

        await agent.start(initialInstruction: "do something")

        await Self.waitUntil(deadline: 1.0) {
            let msgs = await channel.allMessages()
            return msgs.contains { $0.content.contains("Agent Brown error (1/") }
        }
        await agent.stop()

        let banner = await channel.allMessages().first { $0.content.contains("Agent Brown error (1/") }
        #expect(banner != nil, "a rate limit should surface on the first failure so the wait is visible")
        if let banner {
            #expect(banner.content.contains("Rate limited"))
            // No server Retry-After here → our own backoff, shown in human units.
            #expect(banner.content.contains("retrying after"))
            #expect(!banner.content.contains("server Retry-After"))
        }
    }

    @Test("A server Retry-After is honored and named in the transcript")
    func http429HonorsServerRetryAfter() async throws {
        let channel = MessageChannel()
        let taskStore = TaskStore()
        let provider = SingleShot400Provider(
            statusCode: 429,
            body: #"{"error":{"message":"slow down"}}"#,
            retryAfter: 120
        )
        let agent = Self.makeBrown(provider: provider, channel: channel, taskStore: taskStore)

        await agent.start(initialInstruction: "do something")

        await Self.waitUntil(deadline: 1.0) {
            let msgs = await channel.allMessages()
            return msgs.contains { $0.content.contains("Agent Brown error (1/") }
        }
        await agent.stop()

        let banner = await channel.allMessages().first { $0.content.contains("Agent Brown error (1/") }
        #expect(banner != nil)
        if let banner {
            #expect(banner.content.contains("retrying after 2 minutes"))
            #expect(banner.content.contains("server Retry-After"))
        }
    }

    @Test("formatRetryDelay renders whole units")
    func retryDelayFormatting() {
        #expect(AgentActor.formatRetryDelay(3) == "3 seconds")
        #expect(AgentActor.formatRetryDelay(1) == "1 second")
        #expect(AgentActor.formatRetryDelay(180) == "3 minutes")
        #expect(AgentActor.formatRetryDelay(600) == "10 minutes")
        #expect(AgentActor.formatRetryDelay(3600) == "1 hour")
        #expect(AgentActor.formatRetryDelay(18000) == "5 hours")
        #expect(AgentActor.formatRetryDelay(5400) == "1.5 hours")
    }
}
