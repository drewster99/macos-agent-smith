# Contributing to Agent Smith

Thanks for your interest. Bug reports, feedback, docs fixes, and code are all welcome, and small
contributions count.

## Ways to help

- **Report a bug or rough edge.** [Open an issue](https://github.com/drewster99/macos-agent-smith/issues/new/choose).
  "An agent did something strange" is a valid report. Attach the task, the model you used for
  each role, and what you expected.
- **Try a model or provider we haven't tested.** Tell us how Smith, Brown, and the Validator did
  with it.
- **Pick up an issue.** Issues labeled
  [`good first issue`](https://github.com/drewster99/macos-agent-smith/labels/good%20first%20issue)
  are scoped for newcomers. [`help wanted`](https://github.com/drewster99/macos-agent-smith/labels/help%20wanted)
  ones are bigger. Comment on an issue before you start so two people don't do the same work.
- **Improve the docs.** If something in the README or this guide confused you, it probably
  confused others too.

For anything that touches security (the Security Agent, tool gating, or credential handling),
read [SECURITY.md](SECURITY.md) first. Don't file exploitable issues publicly.

## Getting set up

Requirements: an Apple Silicon Mac on macOS 26.2+, Xcode 26.2+, and an API key for at least one
provider (or a local model through Ollama or LM Studio).

```
git clone https://github.com/drewster99/macos-agent-smith.git
open macos-agent-smith/AgentSmith/AgentSmith.xcodeproj
```

Build and run the `AgentSmith` scheme. Swift Package Manager fetches the dependencies.

### Running tests

Most tests live in the local package and run from the terminal:

```
cd AgentSmithPackage
swift test --skip MemoryStoreIntegrationTests
```

`MemoryStoreIntegrationTests` needs Xcode's build pipeline to compile MLX Metal shaders, so it's
skipped here. Use `--filter SomeSuiteName` to run a subset. A few timing-sensitive tests can be
flaky on a full run. If one fails, run it alone before assuming you broke it.

## Finding your way around

| Path | What's there |
| --- | --- |
| `AgentSmithPackage/Sources/AgentSmithKit/` | The engine: agents, orchestration, tools, validation, memory, persistence |
| `AgentSmith/AgentSmith/` | The SwiftUI app: views and view models |
| `AgentSmithPackage/Tests/AgentSmithTests/` | Swift Testing suites (`@Suite` / `@Test`) |
| `SafetySystemTesting/` | Standalone harness for exercising the security gate |

[`CLAUDE.md`](CLAUDE.md) is the architecture guide. It's written for AI coding assistants, but
it's the most complete and current explanation of how the system works and why, so it's useful
for people too. [`ROADMAP.md`](ROADMAP.md) has design history and planned work.

## Code conventions

The codebase has a few firm rules. Several are enforced by guard tests, which fail the build if
the pattern comes back.

- **No force unwraps or `try?`.** Handle the error or surface it.
- **No silent fallbacks.** If a value is missing because of a bug, we want to see the error. A
  quiet default hides it.
- **Never drive behavior from free text.** Control flow must never depend on the wording of a
  tool's output or a message. Use typed signals like `ToolEffect`, `ToolExecutionResult.succeeded`,
  and `ChannelMessageKind`.
- **Message kinds are typed.** Post with `.kind(.someKind)` and read with `message.kind`, never a
  string literal. Don't delete a retired kind's case, because old logs still contain it.
- **One source of truth.** Don't add a second copy of state, or a special-case side path that
  bypasses an existing abstraction. Extend the existing concept.
- **Every tool call goes through the Security Agent.** Don't add a path that runs a tool
  unreviewed.
- **SwiftUI:** extract subviews into `View` structs, not functions or computed properties that
  return `some View`. Keep `body` short. Define colors and fonts centrally.
- **Naming:** optimize for clarity at the point of use and don't abbreviate. See the
  [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/).
- **Comments explain *why*, not *what*.** Document public API.

## Pull requests

1. Fork and branch from `main`.
2. Keep each PR focused on one fix or feature. Separate refactors from behavior changes.
3. Make sure it builds without new warnings and the package tests pass.
4. Add tests for new behavior and edge cases. Bug fixes should include a test that fails without
   the fix.
5. Describe what changed and why, and link the issue. For UI changes, include a screenshot.

Commit messages are short imperative summaries, for example
`Surface capability probe failures`. Add detail in the body when the reason isn't obvious.

## License

By contributing, you agree that your contributions are licensed under the
[Apache License 2.0](LICENSE), the same as the project.

## Conduct

This project follows the [Code of Conduct](CODE_OF_CONDUCT.md). Be kind.
