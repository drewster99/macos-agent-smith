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
            // No server Retry-After here → our own backoff, shown relatively + as a clock time.
            #expect(banner.content.contains("retrying in"))
            #expect(banner.content.contains("(at "))
            #expect(!banner.content.contains("Retry-After"))
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
            #expect(banner.content.contains("retrying in 2 minutes"))
            #expect(banner.content.contains("per server Retry-After"))
        }
    }

    @Test("A ridiculously long server Retry-After is honored but flagged")
    func http429FlagsRidiculousRetryAfter() async throws {
        let channel = MessageChannel()
        let taskStore = TaskStore()
        let provider = SingleShot400Provider(
            statusCode: 429,
            body: #"{"error":{"message":"weekly limit"}}"#,
            retryAfter: 2 * 3600  // 2 hours — over the "unusually long" threshold
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
            #expect(banner.content.contains("retrying in 2 hours"))
            #expect(banner.content.contains("unusually long"))
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
        #expect(AgentActor.formatRetryDelay(86400) == "1 day")
        #expect(AgentActor.formatRetryDelay(172800) == "2 days")
        #expect(AgentActor.formatRetryDelay(129600) == "1.5 days")
    }

    @Test("retryAfterFromErrorBody parses Gemini RetryInfo and 'retry in Ns'")
    func retryFromBody() {
        // Real Gemini 429 shape: RetryInfo.retryDelay plus a "Please retry in Ns" message.
        let gemini = #"{"error":{"code":429,"message":"You exceeded your current quota. Please retry in 34.376085309s.","status":"RESOURCE_EXHAUSTED","details":[{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"34s"}]}}"#
        #expect(AgentActor.retryAfterFromErrorBody(gemini) == 34)     // retryDelay pattern wins
        #expect(AgentActor.retryAfterFromErrorBody("Please retry in 12s") == 12)
        #expect(AgentActor.retryAfterFromErrorBody("please retry in 5.5 s") == 5.5)
        #expect(AgentActor.retryAfterFromErrorBody("some unrelated error text") == nil)
    }

    @Test("formatRetryClock shows a bare time today and adds the date on another day")
    func retryClockFormatting() {
        let now = Date(timeIntervalSince1970: 800_000_000)
        // Same instant → same calendar day in any timezone: a bare time, no date.
        #expect(!AgentActor.formatRetryClock(now, now: now).contains(" on "))
        // +26h always crosses a calendar-day boundary in any timezone: date appended.
        #expect(AgentActor.formatRetryClock(now.addingTimeInterval(26 * 3600), now: now).contains(" on "))
    }

    /// A 402 is out of credits, not a transient fault. The surfaced line must read as a plain
    /// billing problem — naming the cause and the remedy — rather than the generic
    /// "error (1/50): HTTP 402: {raw json}" frame. Retry behavior is intentionally unchanged.
    @Test("HTTP 402 surfaces as a clear out-of-credits message, not a raw error dump")
    func http402SurfacesAsOutOfCredits() async throws {
        let channel = MessageChannel()
        let taskStore = TaskStore()
        let provider = SingleShot400Provider(
            statusCode: 402,
            body: #"{"error":{"type":"insufficient_quota","message":"You have insufficient credits."}}"#
        )
        let agent = Self.makeBrown(provider: provider, channel: channel, taskStore: taskStore)

        await agent.start(initialInstruction: "do something")
        await Self.waitUntil(deadline: 1.0) {
            let msgs = await channel.allMessages()
            return msgs.contains { $0.content.contains("out of credits") }
        }
        await agent.stop()

        let banner = await channel.allMessages().first { $0.content.contains("out of credits") }
        #expect(banner != nil, "a 402 should surface a clear out-of-credits message on the first failure")
        if let banner {
            #expect(banner.content.contains("HTTP 402 (Payment Required)"))
            #expect(banner.content.contains("Add funds"))
            // The clear message replaces the generic error frame and never dumps the raw JSON body…
            #expect(!banner.content.contains("error (1/"))
            #expect(!banner.content.contains("insufficient_quota"))
            // …but the behavior is unchanged — it still backs off and retries.
            #expect(banner.content.contains("retrying in"))
        }
    }

    @Test("outOfCreditsMessage names the role and model, no terminal punctuation")
    func outOfCreditsMessageShape() {
        let msg = AgentActor.outOfCreditsMessage(role: .brown, model: "magistral-medium-2509")
        #expect(msg.contains("Brown"))
        #expect(msg.contains("magistral-medium-2509"))
        #expect(msg.contains("402"))
        #expect(msg.contains("Add funds"))
        // The caller appends "— retrying in …", so the base line must not end with a period.
        #expect(!msg.hasSuffix("."))
    }
}
