import Testing
@testable import AgentSmithKit

/// Asserts that a tool call throws `missingRequiredArgument` for exactly `name`.
func expectMissingArgument(_ name: String, _ call: () async throws -> ToolExecutionResult) async {
    do {
        _ = try await call()
        Issue.record("expected missingRequiredArgument(\(name))")
    } catch ToolCallError.missingRequiredArgument(let missing) {
        #expect(missing == name)
    } catch {
        Issue.record("unexpected error \(error)")
    }
}
