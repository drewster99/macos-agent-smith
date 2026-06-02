import Foundation
import os

/// Raised by `GhTool.tokenize(_:)` when the args string cannot be split into a valid argv
/// array because shell quoting is malformed.
public enum GhArgTokenizeError: Error {
    /// A single or double quote was opened but never closed, or the string ended on a
    /// dangling unquoted backslash (which would escape a non-existent following character).
    case unterminatedQuote
}

/// Brown tool: runs the GitHub CLI (`gh`) with arbitrary args. The tool execs `gh` *directly*
/// via a real argv array — there is no shell anywhere in the path. The model-supplied args
/// string is split into argv by a fail-closed POSIX-style tokenizer (`tokenize(_:)`) that
/// honors quoting but performs NO expansion: `$VAR`, `$(…)`, backticks, globs, redirects, and
/// command chaining survive only as literal characters inside a single argv element, so they
/// cannot have any effect. This eliminates the entire class of shell-injection / env-var
/// exfiltration bugs that a `bash -l -c "exec gh …"` invocation exposed.
///
/// The tool's description includes the captured `gh auth status` output from Brown's spawn so
/// the model has direct evidence that authentication is in place — without this, gpt-style
/// models routinely refuse GitHub work claiming "I don't have access." `gh` auth is keyring /
/// `~/.config/gh`-based and does not depend on login-shell environment, and `ProcessRunner`
/// passes the process environment through, so dropping the login shell does not affect auth.
struct GhTool: AgentTool {
    let name = "gh"
    private let authStatusSnapshot: String

    public init(authStatusSnapshot: String = "(auth status was not captured for this spawn)") {
        self.authStatusSnapshot = authStatusSnapshot
    }

    // MARK: - Tokenizer

    /// Splits an args string into an argv array using POSIX-shell quoting rules, but with NO
    /// expansion of any kind — `$VAR`, `$(…)`, backticks, and globs are all preserved as
    /// literal characters. The only transformation applied is leading-`~` expansion (see below),
    /// because a shipped tool-description example (`~/Downloads/asset.zip`) relies on it.
    ///
    /// Quoting rules:
    /// - Single quotes: everything between them is literal, including backslashes.
    /// - Double quotes: backslash escapes only `"` and `\`; any other backslash is literal.
    /// - Unquoted backslash: escapes the next character (taken literally).
    /// - Whitespace outside quotes separates tokens.
    ///
    /// Fail-closed: throws `GhArgTokenizeError.unterminatedQuote` if a quote is left open or the
    /// string ends on a dangling unquoted backslash, rather than silently dropping characters or
    /// guessing — an ambiguous command must be refused, never executed.
    ///
    /// - Parameter args: the raw args string from the model (everything after a leading `gh`).
    /// - Returns: the argv elements, in order.
    /// - Throws: `GhArgTokenizeError.unterminatedQuote` on malformed quoting.
    static func tokenize(_ args: String) throws -> [String] {
        enum QuoteState { case none, single, double }

        var tokens: [String] = []
        var current = ""
        var haveToken = false
        var state: QuoteState = .none
        var iterator = args.makeIterator()

        func appendChar(_ c: Character) {
            current.append(c)
            haveToken = true
        }

        while let c = iterator.next() {
            switch state {
            case .none:
                switch c {
                case " ", "\t", "\n", "\r":
                    if haveToken {
                        tokens.append(current)
                        current = ""
                        haveToken = false
                    }
                case "'":
                    state = .single
                    haveToken = true
                case "\"":
                    state = .double
                    haveToken = true
                case "\\":
                    // Unquoted backslash escapes exactly the next character. A trailing
                    // backslash has nothing to escape, so the command is malformed.
                    guard let next = iterator.next() else {
                        throw GhArgTokenizeError.unterminatedQuote
                    }
                    appendChar(next)
                default:
                    appendChar(c)
                }
            case .single:
                // Inside single quotes everything is literal until the closing quote.
                if c == "'" {
                    state = .none
                } else {
                    appendChar(c)
                }
            case .double:
                switch c {
                case "\"":
                    state = .none
                case "\\":
                    // In double quotes a backslash only escapes `"` or `\`; otherwise it is
                    // a literal backslash followed by the next character handled normally.
                    guard let next = iterator.next() else {
                        throw GhArgTokenizeError.unterminatedQuote
                    }
                    if next == "\"" || next == "\\" {
                        appendChar(next)
                    } else {
                        appendChar("\\")
                        appendChar(next)
                    }
                default:
                    appendChar(c)
                }
            }
        }

        if state != .none {
            throw GhArgTokenizeError.unterminatedQuote
        }
        if haveToken {
            tokens.append(current)
        }

        return tokens.map(Self.expandLeadingTilde)
    }

    /// Expands a leading `~/` (or a token that is exactly `~`) to the current user's home
    /// directory. This is the ONLY expansion the tokenizer performs; it exists so the shipped
    /// `~/Downloads/asset.zip` example keeps working now that no shell is involved. A `~` that
    /// is not at the start of the token, or a `~user` form, is left untouched.
    private static func expandLeadingTilde(_ token: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if token == "~" {
            return home
        }
        if token.hasPrefix("~/") {
            return home + token.dropFirst(1)
        }
        return token
    }

    // MARK: - gh path resolution

    /// Caches the resolved absolute path to the `gh` executable. Mirrors `GhAuthChecker`'s
    /// "resolve via login shell once, then cache" pattern so we don't pay the shell-spawn cost
    /// on every gh call. Lock-guarded because tool execution can happen concurrently across
    /// Brown spawns.
    private static let cachedGhPath = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// Resolves the absolute path to `gh`, caching the result. Resolution order:
    /// 1. `command -v gh` via a login shell (picks up the user's PATH, e.g. a custom install).
    /// 2. `/opt/homebrew/bin/gh` (Apple Silicon Homebrew default).
    /// 3. `/usr/local/bin/gh` (Intel Homebrew default).
    ///
    /// Resolution is only valid if the candidate is an absolute path to an existing executable.
    /// Returns `nil` if `gh` cannot be located, so `execute(...)` can surface a clear failure.
    static func resolveGhPath() async -> String? {
        if let cached = cachedGhPath.withLock({ $0 }) {
            return cached
        }

        var resolved: String?

        do {
            let result = try await ProcessRunner.run(
                executable: "/bin/bash",
                arguments: ["-l", "-c", "command -v gh"],
                workingDirectory: nil,
                timeout: 30
            )
            if !result.timedOut, result.exitCode == 0 {
                let candidate = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                if isUsableExecutable(candidate) {
                    resolved = candidate
                }
            }
        } catch {
            let logger = Logger(subsystem: "AgentSmith", category: "GhTool")
            logger.debug("`command -v gh` failed: \(error.localizedDescription); falling back to known install paths")
        }

        if resolved == nil {
            for fallback in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"] where isUsableExecutable(fallback) {
                resolved = fallback
                break
            }
        }

        if let resolved {
            cachedGhPath.withLock { $0 = resolved }
        }
        return resolved
    }

    /// True when `path` is an absolute path to an existing, executable, non-directory file.
    private static func isUsableExecutable(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        guard exists, !isDirectory.boolValue else { return false }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    // MARK: - AgentTool

    /// Same rationale as `BashTool.executionTimeout`: subprocess timeout is enforced inside
    /// `ProcessRunner` from the user-supplied `timeout` arg (default 300 s, no upper cap).
    /// This agent-level cap exists as a safety net for `gh` commands that legitimately run
    /// long (large `gh repo clone`, `gh pr list --limit 1000`); 1 hour + slack covers them.
    var executionTimeout: Duration { .seconds(3700) }

    var toolDescription: String {
        """
        Run a GitHub CLI command. THIS is the tool to use for `gh` — do NOT shell out to `gh` \
        via the `bash` tool, even though that would also work. Routing `gh` through this tool \
        keeps the GitHub-specific exit-code semantics and the pre-captured auth-status snapshot \
        below in the loop. \
        gh is exec'd DIRECTLY with no shell: the args string is split into individual arguments \
        using shell-style quoting (single quotes, double quotes, and backslash escapes), but \
        nothing is expanded or interpreted by a shell. There is no pipe (`|`), no file \
        redirection (`>`, `>>`, `<`, `2>`, `<<<`), no command chaining (`;`, `&&`, `||`, `&`), \
        no `$VAR` / `${...}` expansion, no command/process substitution (backticks, `$(...)`, \
        `>(...)`, `<(...)`), and no globbing — any of those characters are passed to gh \
        verbatim as part of an argument. The one convenience: a `~` at the start of a path \
        argument (e.g. `~/Downloads/asset.zip`) is expanded to your home directory. \
        To filter or reshape gh's output, use gh's built-in `--jq` flag (full jq syntax, e.g. \
        `--jq '.[] | .number'` or `--json title,number --jq '.[] | select(.title|test("fix"))'`) \
        — the `|` inside a quoted `--jq` program is part of the jq program, not a shell pipe. gh \
        writes errors to stderr, which is already captured in the returned output, so `2>&1` is \
        unnecessary. If you genuinely need a shell pipeline or redirection, use the `bash` tool \
        instead (the safety monitor sees the whole command there). To run two gh commands, issue \
        them as separate gh calls. \
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

        let argv: [String]
        do {
            argv = try Self.tokenize(args)
        } catch {
            return .failure("""
                Refused: gh args have an unterminated/malformed quote. Use balanced quotes. \
                The gh tool execs the GitHub CLI directly with NO shell — pipes |, redirection \
                > <, chaining ; && ||, $VAR expansion, and command substitution are unavailable; \
                use gh's --jq to filter, or the bash tool for a pipeline.
                """)
        }

        guard !argv.isEmpty else {
            return .failure("Refused: no gh arguments were provided.")
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

        guard let ghPath = await Self.resolveGhPath() else {
            return .failure("""
                Refused: could not locate the `gh` executable. Ensure the GitHub CLI is \
                installed (e.g. via Homebrew) and on PATH, or at /opt/homebrew/bin/gh or \
                /usr/local/bin/gh.
                """)
        }

        let result = try await ProcessRunner.run(
            executable: ghPath,
            arguments: argv,
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
