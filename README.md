<div align="center">

<img src="docs/assets/app-icon.png" width="128" alt="Agent Smith app icon" />

# Agent Smith

**A multi-agent workforce for your Mac.** You hand it a task; a team of LLM agents plans it, does the work in a real shell, and reviews itself — with a dedicated security agent watching every move.

A native macOS app. Swift 6, SwiftUI, on-device. Your API keys, your machine.

<img src="docs/assets/screenshot.png" width="820" alt="Agent Smith orchestrating tasks" />

</div>

## Why it's different

Most AI coding tools are a single agent in a chat loop that you watch. Agent Smith is a small, self-supervising team: an **orchestrator** turns your request into tracked tasks and delegates them, **workers** carry them out in a real shell — several at once — a **security agent** rates every action *before* it runs, and each task's **acceptance criteria** get independently judged before anything is called done. It runs locally, works with any model you point it at, and keeps working through a task list — not just a single prompt.

## The cast

Four agents, each with one job — plus a judge that deliberately isn't one of them:

| Agent | Role |
| --- | --- |
| **Smith** | Orchestrator. Talks to you, turns requests into tasks with acceptance criteria, spawns and supervises workers. Never does the work — and never grades it either. |
| **Brown** | Worker. Spawned per task with the bash, file, and process tools to actually get things done. Several run at once, one per task. |
| **Security Agent** | Security gatekeeper. Silently rates *every* agent's tool calls — `SAFE` / `WARN` / `UNSAFE` / `ABORT` — and can stop the line. |
| **Summarizer** | Distills finished tasks into memory the team can draw on later. |
| **Validator** | Not a standing agent: each acceptance criterion is judged on its own, by a model you assign. The agent that ordered the work never signs off on it. |

## Highlights

- **Real tools, real shell** — Brown runs `bash`, reads and edits files, manages processes, fetches the web. Not a sandbox toy.
- **Security built in, not bolted on** — every tool call from every agent routes through the Security Agent before it runs. There is no unreviewed path, and no setting to create one.
- **Work is checked, not rubber-stamped** — each acceptance criterion is judged independently, by a different model than the one that did the work.
- **Multi-session** — run independent jobs side by side in their own tabs and windows.
- **Persistent memory** — semantic-search-backed memory so the team remembers what it learned across runs.
- **Agent inspector** — open any agent's full conversation, tool calls, and security verdicts, live or after the fact.
- **Bring your own model** — Anthropic, OpenAI, Gemini, Mistral, xAI, Z.AI, Meta, Hugging Face, Alibaba Cloud, OpenRouter, local models via Ollama or LM Studio, and any OpenAI-compatible endpoint, via [SwiftLLMKit](https://github.com/drewster99/swift-llm-kit). Mix them freely — each role gets its own model. Keys live in the Keychain, never in config.
- **Usage & cost tracking** — every call is metered and grouped by run.
- **MCP support** — extend the team with Model Context Protocol servers.

## Requirements

- **To run:** macOS 26.2 or later, and an API key for at least one supported provider (or a local model via Ollama / LM Studio).
- **To build from source:** the above, plus Xcode 26.2 or later — the app targets macOS 26.2, so earlier Xcode versions won't have the SDK for it.

## Install

No prebuilt binaries are published yet, so build from source. When builds are posted they'll appear under [Releases](https://github.com/drewster99/macos-agent-smith/releases); unsigned alpha builds need a right-click → **Open** the first time, to get past Gatekeeper.

Clone and open in Xcode — Swift Package Manager resolves the dependencies automatically, no side-by-side checkouts needed:

```
git clone https://github.com/drewster99/macos-agent-smith.git
open macos-agent-smith/AgentSmith/AgentSmith.xcodeproj
```

Run the `AgentSmith` scheme. The engine lives in the local Swift package `AgentSmithKit` (`AgentSmithPackage/`), which pulls [swift-llm-kit](https://github.com/drewster99/swift-llm-kit) and [swift-semantic-search](https://github.com/drewster99/swift-semantic-search) as versioned dependencies. Run the package tests from the terminal:

```
cd AgentSmithPackage && swift test --skip MemoryStoreIntegrationTests
```

On first run, add a provider API key in Settings, then assign a model to each role in the **Agents** inspector. The roles are independent on purpose — nothing falls back to another role's model, so a role left unset simply doesn't run. In particular, tasks queue up unjudged until the Validator has one.

## A note on safety

Agent Smith runs LLM-generated commands — including a real shell — on your machine. The Security Agent vets actions before they run, but it's a mitigation, not a sandbox, and LLMs make mistakes. This is early software: keep backups, point it at work you can afford to have go sideways, and use it at your own risk.

## License

Licensed under the [Apache License 2.0](LICENSE). Copyright © 2026 Nuclear Cyborg Corp.
