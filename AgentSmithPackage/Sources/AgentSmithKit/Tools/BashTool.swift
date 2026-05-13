import Foundation

/// Executes bash commands. Security evaluation is handled by Jones (SecurityEvaluator).
struct BashTool: AgentTool {
    let name = "bash"
    let toolDescription = "Execute a command in the \"bash\" shell and return its output. Every `bash` tool call is run in a separate shell. Do not submit dangerous or excessively complex commands. Default timeout is 300 seconds — pass a higher `timeout` for long-running commands. Make parallel tool calls whenever possible: Before calling, consider if you have multiple bash commands you may wish to run that at not dependent upon each other's results. If so, send up to 20 `bash` tool calls in a single response. NEVER use `bash` to force push. NEVER use `bash` to invoke the GitHub CLI (`gh`) — call the dedicated `gh` tool instead, which carries the verified auth-status snapshot and a GitHub-specific argument filter."

    public func description(for role: AgentRole) -> String {
        switch role {
        case .brown:
            return toolDescription + " " +
                   BrownBehavior.approvalGateNote(outcome: "the command output") +
                   BrownBehavior.terminationWarning
        default:
            return toolDescription
        }
    }

    let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "command": .dictionary([
                "type": .string("string"),
                "description": .string("The bash command to execute.")
            ]),
            "workingDirectory": .dictionary([
                "type": .string("string"),
                "description": .string("Optional working directory for the command.")
            ]),
            "timeout": .dictionary([
                "type": .string("integer"),
                "description": .string("Timeout in seconds. Defaults to 300.")
            ])
        ]),
        "required": .array([.string("command")])
    ]

    public init() {}

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .brown
    }

    /// Subprocess timeout is enforced inside `ProcessRunner` based on the user-supplied
    /// `timeout` argument (default 300 s, no upper cap in the tool schema). The agent-level
    /// `executionTimeout` here is a safety net for the case where `ProcessRunner` itself
    /// somehow fails to honor its own deadline; it must therefore comfortably exceed any
    /// realistic user-supplied `timeout`. 1 hour + slack covers full builds and long
    /// integration runs without cutting them off prematurely.
    var executionTimeout: Duration { .seconds(3700) }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard case .string(let command) = arguments["command"] else {
            throw ToolCallError.missingRequiredArgument("command")
        }

        let timeoutSeconds: Int
        if case .int(let t) = arguments["timeout"] {
            timeoutSeconds = t
        } else {
            timeoutSeconds = 300
        }

        let workingDir: String?
        if case .string(let dir) = arguments["workingDirectory"] {
            workingDir = dir
        } else {
            workingDir = nil
        }

        let result = try await ProcessRunner.run(
            executable: "/bin/bash",
            arguments: ["-l", "-c", command],
            workingDirectory: workingDir,
            timeout: TimeInterval(timeoutSeconds)
        )

        if result.timedOut {
            return .failure("Command timed out after \(timeoutSeconds) seconds\n\(result.output)")
        } else if result.exitCode == 0 {
            return .success(result.output.isEmpty ? "(no output)" : result.output)
        } else {
            return .failure("Exit code \(result.exitCode)\n\(result.output)")
        }
    }
}
