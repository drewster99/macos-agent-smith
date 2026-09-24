import Foundation
@testable import AgentSmithKit

/// Replays scripted replies in order and records every request it was sent.
final class ScriptedProvider: LLMProvider, @unchecked Sendable {
    /// One scripted provider reply: a response, or a thrown error.
    enum Step: Sendable {
        case respond(LLMResponse)
        case fail(LLMProviderError)
    }

    private let lock = NSLock()
    private var steps: [Step]
    private var requests: [[LLMMessage]] = []

    init(_ steps: [Step]) { self.steps = steps }

    var receivedRequests: [[LLMMessage]] { lock.withLock { requests } }

    func send(messages: [LLMMessage], tools: [LLMToolDefinition], overrides: LLMCallOverrides) async throws -> LLMResponse {
        let step: Step = lock.withLock {
            requests.append(messages)
            precondition(!steps.isEmpty, "ScriptedProvider ran out of steps")
            return steps.removeFirst()
        }
        switch step {
        case .respond(let response): return response
        case .fail(let error): throw error
        }
    }
}

/// Collects `LLMCallEvent`s from a synchronous observer callback.
final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [LLMCallEvent] = []

    func record(_ event: LLMCallEvent) { lock.withLock { collected.append(event) } }
    var events: [LLMCallEvent] { lock.withLock { collected } }

    var turns: [LLMTurnRecord] {
        events.compactMap { if case .completed(let turn) = $0 { return turn } else { return nil } }
    }
    var failures: [LLMCallFailureRecord] {
        events.compactMap { if case .failed(let failure) = $0 { return failure } else { return nil } }
    }
}

