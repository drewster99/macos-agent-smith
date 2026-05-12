import Foundation

/// Brown tool: runs the GitHub CLI (`gh`) with arbitrary args. Internally invokes
/// `/bin/bash -l -c "exec gh <args>"`, so `~` and `$VAR` expansion work — but shell pipes
/// and file redirection are refused before bash sees them, which keeps `gh` as the genuinely
/// constrained path (anything that needs a real pipeline should use the `bash` tool, where
/// the safety monitor sees the whole command). The tool's description includes the captured
/// `gh auth status` output from Brown's spawn so the model has direct evidence that
/// authentication is in place — without this, gpt-style models routinely refuse GitHub work
/// claiming "I don't have access."
struct GhTool: AgentTool {
    let name = "gh"
    private let authStatusSnapshot: String

    /// Substrings rejected before the args reach bash. Naive (not quote-aware) — false
    /// positives just make the model retry with different phrasing, while a false negative
    /// would let the forbidden sequence through to the shell. We optimize for the latter.
    ///
    /// `$(` covers POSIX command substitution (functionally equivalent to backticks).
    /// `>(` and `<(` cover bash process substitution (`gh foo >(curl …)` is an exfil channel).
    /// `${` covers parameter expansion — even though `$(` is already blocked, `${VAR:?$(…)}`
    /// would catch the `$(`, but `${VAR:-evil}` reads any env var the agent shell exports;
    /// if the model needs $VAR expansion it should use the bare `$VAR` form, which is allowed.
    /// `<<<` is a here-string (a read redirection). `\n` / `\r` are command separators in
    /// `bash -c "..."` — JSON tool args trivially decode into strings containing literal
    /// newlines, so they MUST be on the list. `\0` (NUL) corrupts `bash -c` parsing on some
    /// shells; reject it outright.
    ///
    /// Note: bare shell `|`, `>`, `>>`, `<` are *also* rejected — but via the quote-aware
    /// `firstUnquotedRedirectionOrPipe(in:)` scan rather than this naive list, because those
    /// characters appear legitimately inside quoted `--jq` programs (`'.[] | .name'`) and
    /// quoted `--body` text. Only their *unquoted* (operator) uses are refused.
    static let forbiddenSequences: [String] = [
        "&&", "||", "<<<", "$(", ">(", "<(", "${", "`", ";", "\n", "\r", "\0"
    ]

    /// Returns the first forbidden sequence found in `args`, or nil if the args are clean.
    ///
    /// Order matches `forbiddenSequences`; multi-char sequences are listed first so that, e.g.,
    /// `&&` is reported as `&&` rather than as the single `&` that isn't actually forbidden.
    /// In addition to the substring list, a bare `&` used to background or chain commands
    /// (`& cmd`, trailing `&`) is rejected — but `&` between `=`/word characters (URL query
    /// strings like `?a=1&b=2`) stays allowed so the common `gh api '...'` use case still works.
    /// Finally, an *unquoted* `|` / `>` / `>>` / `<` (a real pipe or file redirect, as opposed
    /// to those characters appearing inside a quoted `--jq` program or `--body`) is rejected.
    static func firstForbiddenSequence(in args: String) -> String? {
        for needle in forbiddenSequences where args.contains(needle) {
            return needle
        }
        if containsCommandChainingAmpersand(args) {
            return "&"
        }
        if let op = firstUnquotedRedirectionOrPipe(in: args) {
            return op
        }
        return nil
    }

    /// Scans `args` for a `|`, `<`, or `>` that occurs *outside* shell quoting — i.e. a real
    /// pipe / file-redirection operator, not a `|` inside a quoted `--jq` program or a `<`/`>`
    /// inside a quoted `--body`. Returns the operator (`|`, `<`, `>`, or `>>`) if found, else
    /// nil. Tracks `'…'` and `"…"` spans and honours backslash escapes outside single quotes;
    /// an unterminated quote just means `bash -c` would choke anyway, so we keep scanning.
    static func firstUnquotedRedirectionOrPipe(in args: String) -> String? {
        enum QuoteState { case none, single, double }
        var state: QuoteState = .none
        var iterator = args.makeIterator()
        while let c = iterator.next() {
            switch state {
            case .none:
                switch c {
                case "'": state = .single
                case "\"": state = .double
                case "\\": _ = iterator.next()           // escaped char — consume, not an operator
                case "|", "<": return String(c)
                case ">":
                    // Peek for `>>` so the refusal message names the append form accurately.
                    // (We can't push a char back onto the iterator, but for messaging it's
                    // enough to report `>` either way; `>>` is a nicety.)
                    return ">"
                default: break
                }
            case .single:
                if c == "'" { state = .none }
            case .double:
                switch c {
                case "\"": state = .none
                case "\\": _ = iterator.next()
                default: break
                }
            }
        }
        return nil
    }

    /// Detects an unquoted-style chaining `&`: either `& ` followed by something, a trailing
    /// `&`, or an isolated `&` with whitespace on at least one side. Allows URL-query
    /// `name=value&name=value` and any `&` immediately surrounded by word characters.
    static func containsCommandChainingAmpersand(_ args: String) -> Bool {
        let chars = Array(args)
        for (i, c) in chars.enumerated() where c == "&" {
            // Skip `&&` — already handled by the substring list (and consume both halves).
            if i + 1 < chars.count, chars[i + 1] == "&" { continue }
            if i > 0, chars[i - 1] == "&" { continue }

            let prev: Character? = i > 0 ? chars[i - 1] : nil
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil

            // Trailing `&` (backgrounding) or `&` followed by whitespace = chaining.
            guard let next else { return true }
            if next == " " || next == "\t" { return true }

            // Leading `&` or `&` preceded by whitespace + non-word next = also chaining.
            if let prev, prev == " " || prev == "\t" {
                return true
            }
        }
        return false
    }

    public init(authStatusSnapshot: String = "(auth status was not captured for this spawn)") {
        self.authStatusSnapshot = authStatusSnapshot
    }

    /// Same rationale as `BashTool.executionTimeout`: subprocess timeout is enforced inside
    /// `ProcessRunner` from the user-supplied `timeout` arg (default 300 s, no upper cap).
    /// This agent-level cap exists as a safety net for `gh` commands that legitimately run
    /// long (large `gh repo clone`, `gh pr list --limit 1000`); 1 hour + slack covers them.
    var executionTimeout: Duration { .seconds(3700) }

    var toolDescription: String {
        """
        Run a GitHub CLI command. THIS is the tool to use for `gh` — do NOT shell out to `gh` \
        via the `bash` tool, even though that would also work. Routing `gh` through this tool \
        keeps the GitHub-specific argument filter, exit-code semantics, and the pre-captured \
        auth-status snapshot below in the loop. \
        Args are passed through `/bin/bash -l -c "exec gh <args>"` so gh's exit status is the \
        literal return value (no intermediate shell layer). \
        ALLOWED shell features: `~` expansion and `$VAR` expansion (bare `$VAR` form only). \
        NOT available — these are refused before bash sees them: shell pipes (`|`), file \
        redirection (`>`, `>>`, `<`, `2>`, `<<<`), command chaining (`;`, `&&`, `||`, bare `&`), \
        command/process substitution (backticks, `$(...)`, `>(...)`, `<(...)`), `${...}` \
        parameter expansion, newlines/carriage returns, and NUL bytes. \
        To filter or reshape gh's output, use gh's built-in `--jq` flag (full jq syntax, e.g. \
        `--jq '.[] | .number'` or `--json title,number --jq '.[] | select(.title|test("fix"))'`) \
        — the `|` inside a quoted `--jq` program is fine; it's only the *shell* `|` that's \
        refused. gh writes errors to stderr, which is already captured in the returned output, \
        so `2>&1` is unnecessary. If you genuinely need a shell pipeline or redirection, use the \
        `bash` tool instead (the safety monitor sees the whole command there). To run two gh \
        commands, issue them as separate gh calls. \
        Non-zero exit from `gh` is reported as a tool-call FAILURE — retrying after a failure is \
        a legitimate response, not a duplicate operation. \
        You ARE authenticated to GitHub via `gh` — the `gh auth status` snapshot below was \
        captured at the start of this task and is verified. Do NOT try to "configure auth", \
        "log in", or run `gh auth login`. Just use `gh` directly.

        gh auth status (captured at task start):
        \(authStatusSnapshot)

        Examples (pass to the `args` parameter, no leading `gh`):
        - "repo view drewster99/agent-smith"
        - "issue list --json number,title --jq '.[].number'"
        - "pr create --title 'Fix X' --body 'Closes #123'"
        - "release upload v1.0 ~/Downloads/asset.zip"
        """
    }

    public func description(for role: AgentRole) -> String {
        switch role {
        case .brown:
            return toolDescription + " " +
                BrownBehavior.approvalGateNote(outcome: "the gh command output") +
                BrownBehavior.terminationWarning
        default:
            return toolDescription
        }
    }

    let parameters: [String: AnyCodable] = [
        "type": .string("object"),
        "properties": .dictionary([
            "args": .dictionary([
                "type": .string("string"),
                "description": .string("Arguments to pass to the gh CLI. Do NOT include the leading `gh` — pass everything that would come after it (e.g. \"repo view drewster99/foo\").")
            ]),
            "workingDirectory": .dictionary([
                "type": .string("string"),
                "description": .string("Optional working directory for the command (e.g. when running gh inside a clone).")
            ]),
            "timeout": .dictionary([
                "type": .string("integer"),
                "description": .string("Timeout in seconds. Defaults to 300.")
            ])
        ]),
        "required": .array([.string("args")])
    ]

    public func isAvailable(in context: ToolAvailabilityContext) -> Bool {
        context.agentRole == .brown
    }

    public func execute(arguments: [String: AnyCodable], context: ToolContext) async throws -> ToolExecutionResult {
        guard case .string(let args) = arguments["args"] else {
            throw ToolCallError.missingRequiredArgument("args")
        }

        if let forbidden = Self.firstForbiddenSequence(in: args) {
            let displayed: String
            switch forbidden {
            case "\n": displayed = "\\n (newline)"
            case "\r": displayed = "\\r (carriage return)"
            default: displayed = forbidden
            }
            return .failure("""
                Refused: gh args contain forbidden shell sequence '\(displayed)'. \
                The gh tool allows only `~` and bare `$VAR` expansion — no shell pipes (`|`), \
                no file redirection (`>` `>>` `<` `2>` `<<<`), no chaining (`;` `&&` `||` `&`), \
                no command/process substitution (backticks `$(...)` `>(...)` `<(...)`), no \
                `${...}`, and no newlines. To filter gh output use gh's `--jq` flag (jq syntax, \
                e.g. `--jq '.[] | .number'`) — the `|` inside a quoted `--jq` program is fine; \
                gh's stderr is already in the output, so `2>&1` is unneeded. For a genuine \
                pipeline or redirection use the `bash` tool instead; to run two gh commands, \
                issue them as separate gh calls.
                """)
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

        // `exec gh ...` makes bash hand off the process to gh, so the returned exit code is
        // gh's own (no shell wrapper to swallow or transform it).
        let result = try await ProcessRunner.run(
            executable: "/bin/bash",
            arguments: ["-l", "-c", "exec gh \(args)"],
            workingDirectory: workingDir,
            timeout: TimeInterval(timeoutSeconds)
        )

        if result.timedOut {
            return .failure("Command timed out after \(timeoutSeconds) seconds\n\(result.output)")
        } else if result.exitCode == 0 {
            return .success(result.output.isEmpty ? "(no output)" : result.output)
        } else {
            // Non-zero exit. If the output looks like an auth-failure (`gh` exits 4 on
            // unauthenticated calls, but the wording matters too because the same exit
            // code is reused for other classes of error), invalidate the cached
            // `gh auth status` snapshot so the *next* Brown spawn re-reads reality and
            // surfaces the correct state in the tool description. We don't try to
            // hot-update Brown's current description — that prompt is baked at spawn —
            // but we do tell Brown explicitly that the snapshot may now be stale.
            let staleHint: String
            if Self.outputLooksLikeAuthFailure(result.output, exitCode: result.exitCode) {
                await GhAuthChecker.invalidate()
                staleHint = """

                    NOTE: The `gh auth status` snapshot in this tool's description was \
                    captured at task start and may now be out of date — the failure above \
                    looks like an auth issue. Ask the user to verify `gh auth status` and \
                    (if needed) re-spawn this task. The snapshot will refresh on the next \
                    Brown spawn; do NOT attempt `gh auth login` from here.
                    """
            } else {
                staleHint = ""
            }
            return .failure("Exit code \(result.exitCode)\n\(result.output)\(staleHint)")
        }
    }

    /// Heuristic: does this `gh` failure look like an authentication problem (rather than
    /// a 404, rate limit, malformed args, etc.)? Substring-matches against the standard
    /// `gh` auth-failure phrasings — false positives just trigger a single extra
    /// `gh auth status` re-check on the next Brown spawn, which is cheap.
    static func outputLooksLikeAuthFailure(_ output: String, exitCode: Int32) -> Bool {
        let lowered = output.lowercased()
        let phrases = [
            "you are not logged in",
            "not logged in to",
            "authentication required",
            "401 unauthorized",
            "bad credentials",
            "must authenticate",
            "gh auth login",
            "no oauth token",
            "token has expired"
        ]
        return phrases.contains(where: { lowered.contains($0) })
    }
}
