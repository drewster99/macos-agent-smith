import Testing
import Foundation
import SwiftLLMKit
@testable import AgentSmithKit

/// Exercises `AgentActor.runToolWithTimeout` — the helper added so a single hung tool
/// can no longer pin the agent loop. Two cases matter for the regression we just fixed:
///   1. A tool that returns normally inside its budget completes normally and reports
///      its real `succeeded` flag.
///   2. A tool that never returns is cancelled at `tool.executionTimeout` and the helper
///      yields a synthesized "Tool execution exceeded …" failure result, so `handleResponse`
///      can append a matching `tool_result` and the agent loop continues.
@Suite("AgentActor tool timeout")
struct AgentActorToolTimeoutTests {

    // MARK: - Stub tools

    private struct InfiniteSleepTool: AgentTool {
        let name = "infinite_sleep"
        let toolDescription = "Test stub: sleeps forever inside execute()."
        let parameters: [String: AnyCodable] = [
            "type": .string("object"),
            "properties": .dictionary([:]),
            "required": .array([])
        ]
        let timeoutOverride: Duration

        var executionTimeout: Duration { timeoutOverride }

        init(timeout: Duration = .seconds(1)) {
            self.timeoutOverride = timeout
        }

        func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
            // Sleep WAY past the timeout. `try await Task.sleep` is cooperatively
            // cancellable — the helper's `cancelAll()` will propagate, and this throws
            // CancellationError. The helper's task-group plumbing handles that path:
            // the racing `nil`-returning task wins the `next()` race in either order.
            try await Task.sleep(for: .seconds(99_999))
            return .success("never")
        }
    }

    private struct InstantTool: AgentTool {
        let name = "instant"
        let toolDescription = "Test stub: returns immediately."
        let parameters: [String: AnyCodable] = [
            "type": .string("object"),
            "properties": .dictionary([:]),
            "required": .array([])
        ]
        let outputText: String
        let succeed: Bool

        init(output: String = "ok", succeed: Bool = true) {
            self.outputText = output
            self.succeed = succeed
        }

        func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
            ToolExecutionResult(output: outputText, succeeded: succeed)
        }
    }

    // MARK: - Tests

    @Test("hung tool is cancelled at executionTimeout and yields a failure outcome")
    func hungToolTimesOut() async throws {
        let tool = InfiniteSleepTool(timeout: .milliseconds(300))
        let call = LLMToolCall(id: "call-1", name: tool.name, arguments: "{}")

        let start = Date()
        let outcome = await AgentActor.runToolWithTimeout(
            call,
            tool: tool,
            context: TestToolContext.make()
        )
        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)

        // The helper must NOT block past the budget by more than a small scheduling slop.
        // 1500 ms is generous (CI scheduling can be lumpy) but still proves we're
        // cancelling, not waiting for the inner sleep to finish.
        #expect(elapsedMs < 1500, "helper blocked for \(elapsedMs)ms, well past the 300ms budget")
        #expect(!outcome.succeeded)
        #expect(outcome.result.contains("Tool execution exceeded"))
        #expect(outcome.result.contains("cancelled"))
    }

    @Test("tool returning inside its budget reports the real result and success flag")
    func instantToolPassesThrough() async throws {
        let tool = InstantTool(output: "hello world", succeed: true)
        let call = LLMToolCall(id: "call-2", name: tool.name, arguments: "{}")

        let outcome = await AgentActor.runToolWithTimeout(
            call,
            tool: tool,
            context: TestToolContext.make()
        )

        #expect(outcome.succeeded)
        #expect(outcome.result == "hello world")
        // Sanity: no spurious truncation message for a normal completion.
        #expect(!outcome.result.contains("Tool execution exceeded"))
    }

    @Test("tool reporting domain failure is propagated as failure (not as timeout)")
    func instantToolFailurePassesThrough() async throws {
        let tool = InstantTool(output: "bad input", succeed: false)
        let call = LLMToolCall(id: "call-3", name: tool.name, arguments: "{}")

        let outcome = await AgentActor.runToolWithTimeout(
            call,
            tool: tool,
            context: TestToolContext.make()
        )

        #expect(!outcome.succeeded)
        #expect(outcome.result == "bad input")
        #expect(!outcome.result.contains("Tool execution exceeded"))
    }

    @Test("onTimeout callback fires exactly once when the budget expires")
    func onTimeoutCallbackFires() async throws {
        let tool = InfiniteSleepTool(timeout: .milliseconds(200))
        let call = LLMToolCall(id: "call-4", name: tool.name, arguments: "{}")

        let counter = TimeoutCounter()

        let outcome = await AgentActor.runToolWithTimeout(
            call,
            tool: tool,
            context: TestToolContext.make()
        ) { name, seconds in
            counter.record(name: name, seconds: seconds)
        }

        #expect(!outcome.succeeded)
        let calls = counter.calls
        #expect(calls.count == 1)
        #expect(calls.first?.name == "infinite_sleep")
        // `Duration.components.seconds` truncates sub-second budgets to 0; that's fine —
        // the user-facing message reports the integer second cap and surfaces the same 0.
        #expect(calls.first?.seconds == 0)
    }

    @Test("onTimeout callback does not fire when the tool returns in time")
    func onTimeoutCallbackSilentOnSuccess() async throws {
        let tool = InstantTool()
        let call = LLMToolCall(id: "call-5", name: tool.name, arguments: "{}")

        let counter = TimeoutCounter()

        _ = await AgentActor.runToolWithTimeout(
            call,
            tool: tool,
            context: TestToolContext.make()
        ) { name, seconds in
            counter.record(name: name, seconds: seconds)
        }

        #expect(counter.calls.isEmpty)
    }

    /// Thread-safe accumulator for timeout-callback invocations. The callback type is
    /// `@Sendable`, so a plain `var` capture won't compile.
    private final class TimeoutCounter: @unchecked Sendable {
        struct Invocation {
            let name: String
            let seconds: Int
        }
        private let lock = NSLock()
        private var stored: [Invocation] = []
        func record(name: String, seconds: Int) {
            lock.lock(); defer { lock.unlock() }
            stored.append(Invocation(name: name, seconds: seconds))
        }
        var calls: [Invocation] {
            lock.lock(); defer { lock.unlock() }
            return stored
        }
    }
}
