import Foundation
@testable import AgentSmithKit

/// Test double that returns canned LLM responses.
final class MockLLMProvider: LLMProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _responses: [LLMResponse]
    private var _callCount = 0
    private var _receivedMessages: [[LLMMessage]] = []
    private var _receivedToolNames: [[String]] = []
    private var _receivedMaxTokenOverrides: [Int?] = []

    /// Initializes with a queue of responses that will be returned in order.
    init(responses: [LLMResponse]) {
        _responses = responses
    }

    var callCount: Int {
        lock.withLock { _callCount }
    }

    var receivedMessages: [[LLMMessage]] {
        lock.withLock { _receivedMessages }
    }

    var receivedToolNames: [[String]] {
        lock.withLock { _receivedToolNames }
    }

    var receivedMaxTokenOverrides: [Int?] {
        lock.withLock { _receivedMaxTokenOverrides }
    }

    func send(
        messages: [LLMMessage],
        tools: [LLMToolDefinition],
        overrides: LLMCallOverrides
    ) async throws -> LLMResponse {
        lock.withLock {
            _receivedMessages.append(messages)
            _receivedToolNames.append(tools.map(\.name))
            _receivedMaxTokenOverrides.append(overrides.maxOutputTokens)
            precondition(!_responses.isEmpty, "MockLLMProvider has no canned responses")
            let index = min(_callCount, _responses.count - 1)
            _callCount += 1
            return _responses[index]
        }
    }
}

/// A worker's model that is still thinking: every call stays in flight until it is cancelled (the
/// agent stopped). Use it wherever a test needs a worker that STAYS ALIVE.
///
/// A `MockLLMProvider` text reply does not do that. A worker that answers without calling a tool is
/// nudged to continue at once — a long poll interval does not delay it — and after six text-only
/// replies the degenerate-loop guard ends it and fails its task, about a second or two in. Tests
/// asserting on live workers then passed or failed depending on whether they sampled first.
final class StillThinkingLLMProvider: LLMProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0

    var callCount: Int {
        lock.withLock { _callCount }
    }

    func send(
        messages: [LLMMessage],
        tools: [LLMToolDefinition],
        overrides: LLMCallOverrides
    ) async throws -> LLMResponse {
        lock.withLock { _callCount += 1 }
        try await Task.sleep(for: .seconds(24 * 3600))
        throw CancellationError()
    }
}
