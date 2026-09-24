# Security Policy

Agent Smith runs LLM-generated commands, including a real shell, on your Mac. We take reports
about its safety mechanisms seriously.

## Reporting a vulnerability

**Please don't open a public issue for security problems.** Report privately through GitHub's
[private vulnerability reporting](https://github.com/drewster99/macos-agent-smith/security/advisories/new).

Please include:

- What you found and how it could be triggered
- Steps to reproduce, or a proof of concept
- The app version, macOS version, and the models assigned to each role, if they matter

We'll acknowledge the report, keep you updated while we investigate, and credit you in the fix
unless you'd rather stay anonymous.

## What counts

In scope:

- A way for an agent tool call to run **without** going through the Security Agent, or to be
  hidden from the transcript
- A way to bypass tool gating or task-scoped tool restrictions
- Leaks of API keys or credentials from the Keychain, logs, or exported files
- Prompt-injection paths that let untrusted content (web pages, files, MCP server output) steer
  an agent into gated actions without review
- Any issue in the release build's signing or update path

Out of scope:

- The Security Agent's model making a wrong judgment call on its own. It's an LLM, and the README
  says it's a mitigation, not a sandbox. A *systematic* way to fool it is in scope.
- Problems that need someone who already controls your user account

## Supported versions

Only the [latest release](https://github.com/drewster99/macos-agent-smith/releases/latest) gets
security fixes.
