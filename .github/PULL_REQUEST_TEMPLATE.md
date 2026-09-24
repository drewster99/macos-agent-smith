## What and why

<!-- What does this change, and what problem does it solve? Link the issue: "Fixes #123". -->

## How I tested it

<!-- Tests added or run, and manual checks. For UI changes, add a screenshot. -->

## Checklist

- [ ] Builds without new warnings
- [ ] `swift test --skip MemoryStoreIntegrationTests` passes in `AgentSmithPackage/`
- [ ] Tests cover the new behavior, or explain why they can't
- [ ] Follows the [code conventions](https://github.com/drewster99/macos-agent-smith/blob/main/CONTRIBUTING.md#code-conventions): no force unwraps or `try?`, no silent fallbacks, no control flow based on message text
