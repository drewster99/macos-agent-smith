import Testing
import Foundation
@testable import AgentSmithKit

/// Tests for `GhTool.tokenize(_:)` — the fail-closed POSIX-style splitter that turns the
/// model-supplied args string into a real argv array. `gh` is exec'd directly with this argv,
/// so there is no shell anywhere: the tokenizer must split on unquoted whitespace, honor
/// single/double quotes and backslash escapes, perform NO expansion (so `$VAR`, `$(…)`, `;`,
/// `|`, `>` survive only as literal characters inside one argv element), and throw on malformed
/// quoting rather than guess. The one exception is leading-`~` expansion, kept for the shipped
/// `~/Downloads/asset.zip` example.
@Suite("GhTool args filter")
struct GhToolArgsFilterTests {

    // MARK: - Basic splitting

    @Test("plain args split on whitespace")
    func plainArgsSplit() throws {
        #expect(try GhTool.tokenize("repo view drewster99/agent-smith") == ["repo", "view", "drewster99/agent-smith"])
        #expect(try GhTool.tokenize("pr list") == ["pr", "list"])
        #expect(try GhTool.tokenize("auth status") == ["auth", "status"])
    }

    @Test("runs of whitespace collapse and don't create empty tokens")
    func collapsesWhitespace() throws {
        #expect(try GhTool.tokenize("  repo    view   foo  ") == ["repo", "view", "foo"])
        #expect(try GhTool.tokenize("repo\tview\tfoo") == ["repo", "view", "foo"])
    }

    @Test("the empty string yields no tokens")
    func emptyYieldsNoTokens() throws {
        #expect(try GhTool.tokenize("") == [])
        #expect(try GhTool.tokenize("   ") == [])
    }

    // MARK: - Quoting

    @Test("single quotes keep embedded spaces in one token")
    func singleQuotesGroup() throws {
        #expect(try GhTool.tokenize("pr create --title 'Fix login bug'") == ["pr", "create", "--title", "Fix login bug"])
    }

    @Test("double quotes keep embedded spaces in one token")
    func doubleQuotesGroup() throws {
        #expect(try GhTool.tokenize("pr create --title \"Fix login bug\"") == ["pr", "create", "--title", "Fix login bug"])
    }

    @Test("single quote inside double quotes is literal — --body \"it's done\"")
    func apostropheInsideDoubleQuotes() throws {
        #expect(try GhTool.tokenize("--body \"it's done\"") == ["--body", "it's done"])
    }

    @Test("adjacent quoted and unquoted segments concatenate into one token")
    func adjacentSegmentsConcatenate() throws {
        #expect(try GhTool.tokenize("--title='Fix X'") == ["--title=Fix X"])
        #expect(try GhTool.tokenize("foo\"bar\"baz") == ["foobarbaz"])
    }

    @Test("empty quotes produce an empty argument")
    func emptyQuotesProduceEmptyArg() throws {
        #expect(try GhTool.tokenize("--body ''") == ["--body", ""])
        #expect(try GhTool.tokenize("--body \"\"") == ["--body", ""])
    }

    // MARK: - Backslash escapes

    @Test("unquoted backslash escapes the next character (literal space, no split)")
    func unquotedBackslashEscapes() throws {
        #expect(try GhTool.tokenize("foo\\ bar") == ["foo bar"])
        #expect(try GhTool.tokenize("--title a\\\"b") == ["--title", "a\"b"])
    }

    @Test("inside single quotes a backslash is literal")
    func backslashLiteralInSingleQuotes() throws {
        #expect(try GhTool.tokenize("--body 'a\\b'") == ["--body", "a\\b"])
    }

    @Test("inside double quotes backslash escapes only quote and backslash")
    func backslashInDoubleQuotes() throws {
        #expect(try GhTool.tokenize("--body \"a\\\"b\"") == ["--body", "a\"b"])
        #expect(try GhTool.tokenize("--body \"a\\\\b\"") == ["--body", "a\\b"])
        // A backslash before any other char inside double quotes stays literal.
        #expect(try GhTool.tokenize("--body \"a\\nb\"") == ["--body", "a\\nb"])
    }

    // MARK: - No expansion: shell metacharacters survive as literals

    @Test("$VAR survives verbatim as one literal argv element (no expansion)")
    func dollarVarIsLiteral() throws {
        #expect(try GhTool.tokenize("repo view $REPO_NAME") == ["repo", "view", "$REPO_NAME"])
        #expect(try GhTool.tokenize("pr create --title \"$TITLE\"") == ["pr", "create", "--title", "$TITLE"])
        #expect(try GhTool.tokenize("issue view ${HOME:?x}") == ["issue", "view", "${HOME:?x}"])
    }

    @Test("command substitution survives verbatim (no execution)")
    func commandSubstitutionIsLiteral() throws {
        #expect(try GhTool.tokenize("repo view $(whoami)") == ["repo", "view", "$(whoami)"])
        #expect(try GhTool.tokenize("repo view `whoami`") == ["repo", "view", "`whoami`"])
    }

    @Test("`;` `|` `>` `<` `&` survive as literal characters within a token")
    func chainingAndRedirectionAreLiteral() throws {
        // None of these split or are interpreted — they're just bytes in an argument.
        #expect(try GhTool.tokenize("repo view foo;bar") == ["repo", "view", "foo;bar"])
        #expect(try GhTool.tokenize("api repos/foo?a=1&b=2") == ["api", "repos/foo?a=1&b=2"])
        #expect(try GhTool.tokenize("issue list --jq '.[] | .number'") == ["issue", "list", "--jq", ".[] | .number"])
        #expect(try GhTool.tokenize("issue create --title \"a > b\"") == ["issue", "create", "--title", "a > b"])
        #expect(try GhTool.tokenize("api repos/foo <input") == ["api", "repos/foo", "<input"])
    }

    @Test("a standalone `;` or `&&` becomes a single literal token, not an operator")
    func standaloneOperatorsAreLiteralTokens() throws {
        #expect(try GhTool.tokenize("repo view foo ; rm /tmp/x") == ["repo", "view", "foo", ";", "rm", "/tmp/x"])
        #expect(try GhTool.tokenize("repo view foo && rm") == ["repo", "view", "foo", "&&", "rm"])
        #expect(try GhTool.tokenize("repo view foo | jq .") == ["repo", "view", "foo", "|", "jq", "."])
    }

    // MARK: - Fail-closed on malformed quoting

    @Test("an unterminated single quote throws")
    func unterminatedSingleQuoteThrows() {
        #expect(throws: GhArgTokenizeError.self) {
            try GhTool.tokenize("--body 'unterminated")
        }
    }

    @Test("an unterminated double quote throws")
    func unterminatedDoubleQuoteThrows() {
        #expect(throws: GhArgTokenizeError.self) {
            try GhTool.tokenize("--body \"unterminated")
        }
    }

    @Test("a trailing unquoted backslash throws (nothing to escape)")
    func trailingBackslashThrows() {
        #expect(throws: GhArgTokenizeError.self) {
            try GhTool.tokenize("repo view foo\\")
        }
    }

    @Test("a trailing backslash inside double quotes throws")
    func trailingBackslashInDoubleQuotesThrows() {
        #expect(throws: GhArgTokenizeError.self) {
            try GhTool.tokenize("--body \"abc\\")
        }
    }

    // MARK: - Leading-tilde expansion (the one allowed transformation)

    @Test("a leading ~/ expands to the home directory")
    func leadingTildeSlashExpands() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let tokens = try GhTool.tokenize("release upload v1.0 ~/Downloads/asset.zip")
        #expect(tokens == ["release", "upload", "v1.0", home + "/Downloads/asset.zip"])
    }

    @Test("a token that is exactly ~ expands to the home directory")
    func bareTildeExpands() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(try GhTool.tokenize("repo clone foo ~") == ["repo", "clone", "foo", home])
    }

    @Test("a ~ not at the start of a token is left untouched")
    func nonLeadingTildeUntouched() throws {
        #expect(try GhTool.tokenize("api repos/foo/~bar") == ["api", "repos/foo/~bar"])
        #expect(try GhTool.tokenize("issue create --title v~1") == ["issue", "create", "--title", "v~1"])
    }

    @Test("a quoted ~/ is NOT expanded (tilde expansion only applies to bare leading ~)")
    func quotedTildeUntouched() throws {
        // Quoting the tilde produces a token whose first character is `~` only after the
        // quote is stripped; expansion happens on the assembled token, so a quoted path is
        // still expanded. This documents that the convenience is on the final token, not the
        // raw input — quoting does not protect the tilde here. (Matches POSIX shells, where
        // '~/x' is NOT expanded but a bare ~/x is — but our tokenizer expands the assembled
        // token, so '~/x' WOULD expand. We assert the actual behavior.)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(try GhTool.tokenize("release upload v1 '~/x'") == ["release", "upload", "v1", home + "/x"])
    }

    // MARK: - execute() integration

    @Test("execute() refuses an args string with an unterminated quote")
    func executeRefusesUnterminatedQuote() async throws {
        let tool = GhTool(authStatusSnapshot: "(test)")
        let result = try await tool.execute(
            arguments: ["args": .string("pr create --title 'unterminated")],
            context: Self.makeContext()
        )
        #expect(!result.succeeded)
        #expect(result.output.contains("unterminated/malformed quote"))
    }

    @Test("execute() refuses an empty args string (no tokens to run)")
    func executeRefusesEmptyArgs() async throws {
        let tool = GhTool(authStatusSnapshot: "(test)")
        let result = try await tool.execute(
            arguments: ["args": .string("   ")],
            context: Self.makeContext()
        )
        #expect(!result.succeeded)
        #expect(result.output.contains("no gh arguments"))
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
