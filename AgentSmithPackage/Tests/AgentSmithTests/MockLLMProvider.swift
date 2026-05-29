import Foundation
@testable import AgentSmithKit

/// Test double that returns canned LLM responses.
final class MockLLMProvider: LLMProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _responses: [LLMResponse]
    private var _callCount = 0
    private var _receivedMessages: [[LLMMessage]] = []
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

    var receivedMaxTokenOverrides: [Int?] {
        lock.withLock { _receivedMaxTokenOverrides }
    }

    func send(
        messages: [LLMMessage],
        tools: [LLMToolDefinition],
        toolChoice: LLMToolChoice?,
        thinkingEffortOverride: String?,
        maxOutputTokensOverride: Int?,
        temperatureOverride: Double?,
        topPOverride: Double?
    ) async throws -> LLMResponse {
        lock.withLock {
            _receivedMessages.append(messages)
            _receivedMaxTokenOverrides.append(maxOutputTokensOverride)
            precondition(!_responses.isEmpty, "MockLLMProvider has no canned responses")
            let index = min(_callCount, _responses.count - 1)
            _callCount += 1
            return _responses[index]
        }
    }
}
